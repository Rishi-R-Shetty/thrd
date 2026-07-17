//
//  SupabaseDiscoverRepository.swift
//  ThrdSpaces — Features/Discover
//
//  The live discovery read path: the ONLY Supabase toucher in Features/Discover
//  (views/view models never import Supabase — they go through this seam, keeping
//  the RLS/transport boundary auditable, the same way AuthRepository owns auth).
//
//  It calls the two geo RPCs from migration 0003 (T12) — `nearby_spaces` and
//  `nearby_events` — which are SECURITY INVOKER, so results ride the caller's own
//  RLS (spaces readable; only published events visible). Input is a `Geohash5`,
//  so a raw/finer coordinate cannot reach the wire (D8). Errors collapse to
//  `APIError` with no server message text (mirrors AuthRepository.mapError).
//

import Foundation
import Supabase

struct SupabaseDiscoverRepository: DiscoverRepository {

    /// RPC params for `nearby_spaces`. Snake_case to match the SQL arg names;
    /// PostgREST maps these JSON keys to the function's named parameters.
    private struct NearbySpacesParams: Encodable {
        let cell: String
        let radius_m: Int
    }

    /// RPC params for `nearby_events`. `horizon` is the interval arg: PostgREST
    /// passes the JSON string through to Postgres, which casts it to `interval`.
    private struct NearbyEventsParams: Encodable {
        let cell: String
        let radius_m: Int
        let horizon: String
    }

    func nearbySpaces(near cell: Geohash5, radiusMeters: Int) async throws -> [NearbySpace] {
        do {
            return try await SupabaseClientProvider.shared
                .rpc("nearby_spaces", params: NearbySpacesParams(cell: cell.cell, radius_m: radiusMeters))
                .execute()
                .value
        } catch {
            throw Self.mapError(error)
        }
    }

    func nearbyEvents(near cell: Geohash5, radiusMeters: Int, horizonDays: Int) async throws -> [NearbyEvent] {
        // ponytail: the interval is passed as a "<n> days" string and cast to
        // `interval` server-side — the simplest form PostgREST accepts for an
        // interval RPC arg (verified against the local stack). Upgrade to a
        // typed/normalized interval only if a non-day granularity is ever needed.
        let params = NearbyEventsParams(cell: cell.cell, radius_m: radiusMeters, horizon: "\(horizonDays) days")
        do {
            return try await SupabaseClientProvider.shared
                .rpc("nearby_events", params: params)
                .execute()
                .value
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Detail reads (T15)

    /// Explicit column list — every `events` column the `Event` model decodes
    /// (never a wildcard select; threat-model rule 5). RLS `events_select_published`
    /// gates the rows; we still constrain to published + upcoming, soonest first.
    private static let eventColumns =
        "id, community_id, host_id, space_id, title, description, cover_url, " +
        "starts_at, ends_at, recurrence_rule, capacity, price, status, rsvp_count, created_at"

    /// Explicit column list for the `communities` model.
    private static let communityColumns =
        "id, creator_id, name, description, cover_url, interest_tags, " +
        "visibility, member_count, home_space_id, created_at"

    func events(atSpace spaceID: UUID) async throws -> [Event] {
        do {
            return try await SupabaseClientProvider.shared
                .from("events")
                .select(Self.eventColumns)
                .eq("space_id", value: spaceID.uuidString)
                .eq("status", value: EventStatus.published.rawValue)
                .gte("starts_at", value: ISO8601DateFormatter().string(from: Date()))
                .order("starts_at", ascending: true)
                .execute()
                .value
        } catch {
            throw Self.mapError(error)
        }
    }

    func attendeePreviews(eventID: UUID) async throws -> [AttendeePreview] {
        do {
            // The view is already column-safe (first name + avatar only); the
            // select stays explicit per the no-`*` rule regardless.
            return try await SupabaseClientProvider.shared
                .from("attendee_previews")
                .select("event_id, first_name, avatar_url")
                .eq("event_id", value: eventID.uuidString)
                .execute()
                .value
        } catch {
            throw Self.mapError(error)
        }
    }

    func publicProfile(id: UUID) async throws -> PublicProfile? {
        do {
            // Decode an array and take the first row rather than `.single()`, so a
            // private/deleted/missing id resolves to nil instead of throwing.
            let rows: [PublicProfile] = try await SupabaseClientProvider.shared
                .from("public_profiles")
                .select("id, handle, display_name, avatar_url, interests")
                .eq("id", value: id.uuidString)
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch {
            throw Self.mapError(error)
        }
    }

    func communitiesMeetingAt(spaceID: UUID) async throws -> [Community] {
        do {
            // RLS (`communities_select_public`) already restricts to public
            // visibility; the explicit `.eq` documents the intent and narrows
            // the scan. Ordered by size so the liveliest communities lead.
            return try await SupabaseClientProvider.shared
                .from("communities")
                .select(Self.communityColumns)
                .eq("home_space_id", value: spaceID.uuidString)
                .eq("visibility", value: CommunityVisibility.public.rawValue)
                .order("member_count", ascending: false)
                .execute()
                .value
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Own tickets (T17)

    /// Explicit column list for the `tickets` model (never a wildcard).
    private static let ticketColumns =
        "id, event_id, user_id, type, status, qr_code_token, purchased_at, checked_in_at"

    func ownActiveTickets() async throws -> [Ticket] {
        do {
            // The `tickets_select_own_or_host` policy also returns tickets for
            // events the caller HOSTS (every attendee). "Your spot" must be the
            // caller's OWN tickets only, so filter by the verified user id
            // explicitly — never rely on RLS alone here.
            let userID = try await AuthRepository().refreshedUserID()
            return try await SupabaseClientProvider.shared
                .from("tickets")
                .select(Self.ticketColumns)
                .eq("user_id", value: userID.uuidString)
                .in("status", values: [TicketStatus.going.rawValue, TicketStatus.waitlist.rawValue])
                .execute()
                .value
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Error mapping

    /// Collapses SDK/transport errors into `APIError`, carrying no server message
    /// text so a backend response can't leak schema into the UI. Mirrors
    /// `AuthRepository.mapError`; adds the PostgREST error shapes this path can
    /// see (`PostgrestError` for a decoded PG error, `HTTPError` otherwise).
    nonisolated static func mapError(_ error: Error) -> APIError {
        switch error {
        case let apiError as APIError:
            return apiError
        case let httpError as HTTPError:
            return .server(status: httpError.response.statusCode)
        case let pgError as PostgrestError:
            #if DEBUG
            // A 22023 here means the server's defensive re-snap rejected the
            // cell (migration 0003's assert_geohash5). `Geohash5` makes a
            // malformed cell unrepresentable client-side, so reaching this is a
            // programmer error (a raw cell slipped to the transport), not a user
            // condition — trip loudly in DEBUG. It stays unreachable in release.
            // Suppressed under XCTest so the D8 boundary test can deliberately
            // exercise the server-side guard (bypassing Geohash5) without the
            // tripwire aborting the run.
            if pgError.code == "22023",
               ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                assertionFailure(
                    "nearby RPC rejected the cell server-side (SQLSTATE 22023) — Geohash5 should prevent this."
                )
            }
            #endif
            // PostgrestError carries the SQLSTATE, not the HTTP status; PostgREST
            // returns 400 for the class-22 (invalid_parameter_value) errors these
            // RPCs raise. No new APIError case is added — surface it as a server
            // error like any other non-success status.
            return .server(status: 400)
        case let urlError as URLError:
            return .network(underlying: urlError)
        default:
            return .network(underlying: error)
        }
    }
}
