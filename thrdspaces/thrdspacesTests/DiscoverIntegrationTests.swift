//
//  DiscoverIntegrationTests.swift
//  thrdspacesTests
//
//  T13 live integration against the LOCAL Supabase stack. Exercises the real
//  geo RPCs (migration 0003) end-to-end through a Supabase client and the
//  NearbySpace/NearbyEvent DTOs, proving:
//   • nearby_spaces returns the seeded Bengaluru fixture for its own cell with
//     a plausible distance, and EXCLUDES the Mumbai fixture (10km cap, D6/D8);
//   • nearby_events accepts the interval param and runs (no fixtures → empty);
//   • a 6-char cell — which Geohash5 refuses to construct, so this bypasses it
//     on purpose — is rejected by the SERVER's re-snap guard and surfaces
//     through SupabaseDiscoverRepository.mapError as APIError.server (D8).
//
//  T15 extends this with the detail read paths against live seeded data:
//   • events(atSpace:) — a published event at the Bengaluru fixture round-trips
//     through the `Event` DTO under `events_select_published` RLS;
//   • attendee_previews — a going ticket surfaces the attendee's FIRST NAME only
//     (no handle, no last name), proving the privacy guard on the wire;
//   • public_profiles — the host profile round-trips through the `PublicProfile`
//     DTO for its exact columns.
//
//  Skips cleanly (never fails) when the local stack is down or unseeded. To run
//  it green: start the stack, then seed the fixtures + throwaway auth users.
//  The anon key/URL below are the well-known LOCAL values (not secrets); the
//  service-role key is never here. The T15 seed (idempotent) — run once against
//  a running local DB (psql via the supabase_db docker container):
//
//    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at) values
//      ('f15a0000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','t15-host@thrdspaces.local','x',now(),now()),
//      ('f15a0000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','t15-attendee@thrdspaces.local','x',now(),now())
//      on conflict (id) do nothing;
//    insert into public.users (id, handle, display_name, profile_visibility) values
//      ('f15a0000-0000-4000-8000-000000000001','t15_host','Priya Kumar','public'),
//      ('f15a0000-0000-4000-8000-000000000002','t15_attendee','Arjun Mehta','public')
//      on conflict (id) do nothing;
//    insert into public.events (id, host_id, space_id, title, description, starts_at, ends_at, status, rsvp_count) values
//      ('e15e0000-0000-4000-8000-000000000001','f15a0000-0000-4000-8000-000000000001',
//       'c581a771-9da6-40fe-afa3-e9ba14f12062','T15 Detail Test Event','A published event for T15 detail round-trip.',
//       now() + interval '1 day', now() + interval '1 day 2 hours','published',1) on conflict (id) do nothing;
//    insert into public.tickets (id, event_id, user_id, status) values
//      ('a15c0000-0000-4000-8000-000000000001','e15e0000-0000-4000-8000-000000000001','f15a0000-0000-4000-8000-000000000002','going')
//      on conflict (id) do nothing;
//
//  (The Bengaluru space id above is the T13 seed's "T13 Bengaluru Cafe" row.)
//

import XCTest
@testable import thrdspaces

#if DEBUG
import Supabase

final class DiscoverIntegrationTests: XCTestCase {

    // Local-only config. The anon key + URL are the fixed local-stack values
    // printed by `supabase status`; the throwaway user is created by the T13
    // seed step. None of these are secrets, and no service-role key is here.
    private enum LocalStack {
        static let url = URL(string: "http://127.0.0.1:54321")!
        static let anonKey =
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
        static let email = "t13-integration@thrdspaces.local"
        static let password = "t13-integration-pw"
        static let bengaluruCell = "tdr1v"
        static let bengaluruFixtureName = "T13 Bengaluru Cafe"
        static let mumbaiFixtureName = "T13 Mumbai Cafe"

        // T15 detail fixtures (seeded by the recipe in the file header).
        static let bengaluruSpaceID = "c581a771-9da6-40fe-afa3-e9ba14f12062"
        static let t15EventID = "e15e0000-0000-4000-8000-000000000001"
        static let t15HostID = "f15a0000-0000-4000-8000-000000000001"
        static let t15HostHandle = "t15_host"
        static let t15HostName = "Priya Kumar"
        static let t15AttendeeFirstName = "Arjun"
    }

    private struct SpacesParams: Encodable { let cell: String; let radius_m: Int }
    private struct EventsParams: Encodable { let cell: String; let radius_m: Int; let horizon: String }

    // MARK: - Live RPC path

    func testNearbySpacesReturnsBengaluruAndExcludesMumbai() async throws {
        let client = try await signedInLocalClient()

        let spaces: [NearbySpace] = try await client
            .rpc("nearby_spaces", params: SpacesParams(cell: LocalStack.bengaluruCell, radius_m: 10000))
            .execute()
            .value

        let bengaluru = try XCTUnwrap(
            spaces.first { $0.name == LocalStack.bengaluruFixtureName },
            "the Bengaluru fixture must appear for its own cell — is the T13 seed step run?"
        )
        XCTAssertGreaterThanOrEqual(bengaluru.distanceMeters, 0)
        XCTAssertLessThan(bengaluru.distanceMeters, 10_000,
                          "a fixture in its own cell must be well within the radius cap")

        XCTAssertFalse(spaces.contains { $0.name == LocalStack.mumbaiFixtureName },
                       "Mumbai must be excluded from a Bengaluru cell at the 10km cap")
    }

    func testNearbyEventsAcceptsIntervalParamAndRuns() async throws {
        let client = try await signedInLocalClient()

        // No events are seeded; the assertion is that the interval param encodes
        // and the RPC executes without throwing (returns an array).
        let events: [NearbyEvent] = try await client
            .rpc("nearby_events",
                 params: EventsParams(cell: LocalStack.bengaluruCell, radius_m: 10000, horizon: "7 days"))
            .execute()
            .value

        XCTAssertTrue(events.allSatisfy { $0.distanceMeters >= 0 })
    }

    func testSixCharCellIsRejectedByServerAndSurfacesAsAPIError() async throws {
        let client = try await signedInLocalClient()

        // Geohash5 refuses a 6-char cell, so the production path can never send
        // one — this calls the RPC directly to prove the SERVER re-snap guard
        // (assert_geohash5, SQLSTATE 22023) also rejects it, and that the
        // repository's mapper surfaces the failure as APIError.server (no leak).
        do {
            _ = try await client
                .rpc("nearby_spaces", params: SpacesParams(cell: "tdr1vf", radius_m: 5000))
                .execute()
            XCTFail("server must reject a 6-char cell (SQLSTATE 22023, D8 re-snap)")
        } catch {
            let mapped = SupabaseDiscoverRepository.mapError(error)
            guard case .server = mapped else {
                return XCTFail("a rejected cell must surface as APIError.server, got \(mapped)")
            }
        }
    }

    // MARK: - Detail read paths (T15)

    /// Column lists mirror SupabaseDiscoverRepository (explicit columns only).
    private static let eventColumns =
        "id, community_id, host_id, space_id, title, description, cover_url, " +
        "starts_at, ends_at, recurrence_rule, capacity, price, status, rsvp_count, created_at"

    func testEventsAtSpaceReturnsSeededPublishedEvent() async throws {
        let client = try await signedInLocalClient()

        let events: [Event] = try await client
            .from("events")
            .select(Self.eventColumns)
            .eq("space_id", value: LocalStack.bengaluruSpaceID)
            .eq("status", value: "published")
            .execute()
            .value

        let seeded = try XCTUnwrap(
            events.first { $0.id.uuidString.lowercased() == LocalStack.t15EventID },
            "the seeded T15 event must appear for its venue — is the T15 seed run?"
        )
        XCTAssertEqual(seeded.status, .published)
        XCTAssertEqual(seeded.hostId.uuidString.lowercased(), LocalStack.t15HostID)
    }

    func testAttendeePreviewsReturnsFirstNameOnly() async throws {
        let client = try await signedInLocalClient()

        let previews: [AttendeePreview] = try await client
            .from("attendee_previews")
            .select("event_id, first_name, avatar_url")
            .eq("event_id", value: LocalStack.t15EventID)
            .execute()
            .value

        let preview = try XCTUnwrap(previews.first, "the going ticket must surface an attendee preview")
        XCTAssertEqual(preview.firstName, LocalStack.t15AttendeeFirstName)
        // The privacy guard on the wire: FIRST NAME only — never the last name
        // ("Mehta") and never a multi-word display name.
        XCTAssertFalse(preview.firstName.contains(" "), "preview must be a single first name")
        XCTAssertFalse(preview.firstName.contains("Mehta"), "the last name must never reach the client")
    }

    func testPublicProfileRoundTripsHostRow() async throws {
        let client = try await signedInLocalClient()

        let profiles: [PublicProfile] = try await client
            .from("public_profiles")
            .select("id, handle, display_name, avatar_url, interests")
            .eq("id", value: LocalStack.t15HostID)
            .limit(1)
            .execute()
            .value

        let host = try XCTUnwrap(profiles.first, "the host public profile must round-trip")
        XCTAssertEqual(host.handle, LocalStack.t15HostHandle)
        XCTAssertEqual(host.displayName, LocalStack.t15HostName)
    }

    // MARK: - Local client (skips cleanly when the stack is unavailable)

    /// Builds a Supabase client pointed at the local stack and signs in the
    /// throwaway user. Throws `XCTSkip` — never a failure — when the stack is
    /// unreachable or unseeded, so an offline CI run stays green.
    private func signedInLocalClient() async throws -> SupabaseClient {
        let client = SupabaseClient(
            supabaseURL: LocalStack.url,
            supabaseKey: LocalStack.anonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(storage: InMemoryAuthStorage())
            )
        )
        do {
            _ = try await client.auth.signIn(email: LocalStack.email, password: LocalStack.password)
        } catch let urlError as URLError {
            throw XCTSkip("local Supabase stack unreachable: \(urlError)")
        } catch {
            throw XCTSkip(
                "local Supabase sign-in failed — start the stack and run the T13 seed step: \(error)"
            )
        }
        return client
    }
}

/// In-memory auth storage so the test client's session never touches the
/// Keychain or collides with the app's own session store.
private final class InMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = nil
    }
}
#endif
