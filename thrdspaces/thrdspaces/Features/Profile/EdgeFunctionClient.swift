//
//  EdgeFunctionClient.swift
//  ThrdSpaces — Features/Profile
//
//  The ONLY place that invokes the three Phase-1 Edge Functions
//  (`delete_account`, `submit_report`, `manage_block`). Views and view models
//  call these methods; they never reach `SupabaseClientProvider.shared.functions`
//  directly (keeps the privileged-call boundary in one auditable file — the same
//  pattern AuthRepository uses for the auth boundary).
//
//  Request bodies carry ONLY subject/target ids. Identity (`reporter_id`,
//  `blocker_id`, the deleting user) is derived server-side from the verified JWT
//  — never sent from the client (threat-model Layer 5; T7a hard constraint). The
//  SDK keeps the functions client's Authorization header in sync with the current
//  session token via the auth state listener, so each call carries the signed-in
//  user's JWT (role=authenticated), which the functions require.
//
//  Errors collapse to `APIError` and carry no server message text, so a backend
//  response can't leak schema into the UI (mirrors AuthRepository.mapError).
//

import Foundation
import Supabase

// MARK: - Report enum feature extensions (canonical enums live in Models/)

// Models/ owns the canonical enum for every SQL type; features extend, never
// redeclare (D10). `ReportReason`/`ReportSubject` are declared in
// Models/Report.swift (byte-exact to migration 0001). This file previously
// held duplicate `ReportReason`/`ReportSubjectType` wire enums; they were
// removed in T11 and their UI-only concerns re-homed as extensions below.

extension ReportReason: Identifiable {
    public var id: String { rawValue }

    /// User-facing label for the reason picker.
    var label: String {
        switch self {
        case .safety:     return "Safety concern"
        case .harassment: return "Harassment or bullying"
        case .spam:       return "Spam"
        case .other:      return "Something else"
        }
    }
}

// MARK: - rsvp_event wire types (Phase 2, Artifact B §4)

/// The action to take on an event's RSVP. Mirrors the wire `action` values
/// (`rsvp` | `cancel`); the body never carries anything else about identity.
enum RSVPAction: String, Sendable { case rsvp, cancel }

/// The server-authoritative RSVP outcome. `status` is the caller's resulting
/// ticket state; `rsvpCount` is the event's reconciled going-count. The client
/// computes NEITHER — capacity and waitlist placement are decided inside the
/// function's transaction (Artifact B §4), so this response is the source of
/// truth the UI reconciles any optimistic state to. `status` reuses the
/// canonical `TicketStatus` (Models/); the wire only ever sends the
/// going/waitlist/cancelled subset here.
struct RSVPResult: Equatable, Sendable {
    let status: TicketStatus
    let rsvpCount: Int
}

/// A stable, non-leaking classification of an `rsvp_event` failure. Each case
/// carries user-facing copy that never surfaces a raw status code, error slug,
/// or schema detail (threat-model Layer 5). The two 400 codes are split by the
/// stable `{"error"}` slug: `event_not_open` is a real user-facing state, while
/// `invalid_action` can only be a client bug (we send validated actions) and so
/// collapses to `.unexpected`.
enum RSVPError: Error, Equatable {
    case eventNotOpen          // 400 event_not_open
    case verificationRequired  // 403 verification_required
    case rateLimited           // 429 rate_limited
    case notFound              // 404 not_found
    case auth                  // 401 unauthorized
    case unavailable           // 503 unavailable (kill switch / down)
    case network               // transport failure
    case unexpected            // 500 / decoding / invalid_action / anything else

    /// Friendly, non-leaking copy for an alert. No status codes, no slugs.
    var userMessage: String {
        switch self {
        case .eventNotOpen:
            return "This event isn't open for RSVP."
        case .verificationRequired:
            // Copy only — the phone-verification flow itself is a later phase.
            return "You'll need a verified phone number to RSVP to this event. Phone verification is coming soon."
        case .rateLimited:
            return "You're doing that too often. Please try again in a little while."
        case .notFound:
            return "This event is no longer available."
        case .auth:
            return "Your session has expired. Please sign in again."
        case .unavailable:
            return "RSVP is temporarily unavailable. Please try again later."
        case .network:
            return "No connection. Check your internet and try again."
        case .unexpected:
            return "Something went wrong. Please try again."
        }
    }
}

struct EdgeFunctionClient: Sendable {

    /// Max length of a report detail — mirrors the DB CHECK and the function's
    /// defensive clamp so the client never sends more than the server accepts.
    static let detailLimit = 500

    private var functions: FunctionsClient { SupabaseClientProvider.shared.functions }

    // MARK: - submit_report

    /// The outcome of a report submission. `alreadyReported` is a 200 success
    /// (the function dedupes an existing open report) surfaced as a notice, not
    /// an error.
    enum ReportOutcome: Equatable { case submitted, alreadyReported }

    /// Submits a report. `reporter_id` is NEVER in the body — the function
    /// derives it from the JWT. `detail` is trimmed and clamped to the limit.
    func submitReport(
        subjectType: ReportSubject = .user,
        subjectID: UUID,
        reason: ReportReason,
        detail: String?
    ) async throws -> ReportOutcome {
        struct Body: Encodable {
            let subject_type: String
            let subject_id: String
            let reason: String
            let detail: String?
        }
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Body(
            subject_type: subjectType.rawValue,
            subject_id: subjectID.uuidString,
            reason: reason.rawValue,
            detail: (trimmed?.isEmpty == false) ? String(trimmed!.prefix(Self.detailLimit)) : nil
        )
        return try await invoke("submit_report", body: body) { Self.reportOutcome(from: $0) }
    }

    // MARK: - manage_block

    /// Blocks the target user. `blocker_id` is derived from the JWT — the body
    /// carries only the target. Idempotent server-side.
    func block(userID: UUID) async throws { try await setBlock(action: "block", userID: userID) }

    /// Unblocks the target user. Idempotent — succeeds even if no block existed.
    func unblock(userID: UUID) async throws { try await setBlock(action: "unblock", userID: userID) }

    private func setBlock(action: String, userID: UUID) async throws {
        struct Body: Encodable { let action: String; let user_id: String }
        _ = try await invoke("manage_block", body: Body(action: action, user_id: userID.uuidString)) { _ in () }
    }

    // MARK: - delete_account

    /// The 200 result of a deletion request — the grace window's purge date.
    struct DeletionResult: Equatable { let purgeAfter: Date? }

    /// Requests account deletion (App Store 5.1.1(v)). Body is `{ confirm: true }`
    /// plus the device id for the audit trail; identity is JWT-derived. A 200
    /// means the grace mark was set server-side — the caller signs out locally
    /// only on this confirmed success.
    func deleteAccount(deviceID: String) async throws -> DeletionResult {
        struct Body: Encodable { let confirm: Bool; let device_id: String }
        return try await invoke("delete_account", body: Body(confirm: true, device_id: deviceID)) {
            Self.deletionResult(from: $0)
        }
    }

    // MARK: - rsvp_event

    /// RSVPs to, or cancels an RSVP for, an event. The body carries ONLY the
    /// event id and the action — the caller identity is the verified JWT sub
    /// server-side, never sent (threat-model Layer 5; the client never supplies a
    /// user id). Capacity/waitlist are decided in the function's transaction, so
    /// the returned `RSVPResult` is authoritative. Every failure path throws a
    /// stable `RSVPError` carrying non-leaking copy — this method has its own
    /// error mapping (not the generic `mapFunctionError`) because RSVP needs to
    /// split `event_not_open`/`verification_required` from a plain server error.
    func rsvp(eventID: UUID, action: RSVPAction) async throws -> RSVPResult {
        struct Body: Encodable { let event_id: String; let action: String }
        let body = Body(event_id: eventID.uuidString, action: action.rawValue)
        do {
            return try await functions.invoke("rsvp_event", options: FunctionInvokeOptions(body: body)) { data, _ in
                try Self.rsvpResult(from: data)
            }
        } catch let FunctionsError.httpError(code, data) {
            throw Self.mapRSVPError(status: code, data: data)
        } catch is DecodingError {
            throw RSVPError.unexpected
        } catch let rsvpError as RSVPError {
            throw rsvpError
        } catch let urlError as URLError {
            _ = urlError
            throw RSVPError.network
        } catch {
            // relayError and any other transport failure land here.
            throw RSVPError.network
        }
    }

    // MARK: - Invocation + error mapping

    /// Invokes a function and decodes its 2xx body. Non-2xx responses are thrown
    /// by the SDK as `FunctionsError.httpError` BEFORE `decode` runs, so `decode`
    /// only ever sees a success body.
    private func invoke<T>(
        _ name: String,
        body: some Encodable,
        decode: @escaping @Sendable (Data) throws -> T
    ) async throws -> T {
        do {
            return try await functions.invoke(name, options: FunctionInvokeOptions(body: body)) { data, _ in
                try decode(data)
            }
        } catch let FunctionsError.httpError(code, data) {
            throw Self.mapFunctionError(status: code, data: data)
        } catch is DecodingError {
            throw APIError.decoding
        } catch let apiError as APIError {
            throw apiError
        } catch let urlError as URLError {
            throw APIError.network(underlying: urlError)
        } catch {
            // relayError and any other transport failure land here.
            throw APIError.network(underlying: error)
        }
    }

    /// Maps a non-2xx function response to `APIError`, keyed off the HTTP status
    /// (the `{"error":"<code>"}` body is intentionally not surfaced — no schema
    /// leak). `401` is the only status that isn't a plain server error.
    ///
    /// ponytail: a 404 is ambiguous — the function's own `not_found` OR the
    /// function not being deployed to the hosted project yet both surface as
    /// `.server(status: 404)`. Phase-1 copy treats both as "couldn't reach the
    /// server"; once the functions are deployed, decode the `{"error"}` code here
    /// to split "not deployed" from a genuine `not_found` if a screen needs to.
    nonisolated static func mapFunctionError(status: Int, data: Data) -> APIError {
        switch status {
        case 401: return .auth
        default:  return .server(status: status)
        }
    }

    /// Decodes the `submit_report` 200 body. `already_reported` is the dedupe
    /// notice; anything else (`submitted`) is a fresh report.
    nonisolated static func reportOutcome(from data: Data) -> ReportOutcome {
        struct Body: Decodable { let status: String? }
        let status = (try? JSONDecoder().decode(Body.self, from: data))?.status
        return status == "already_reported" ? .alreadyReported : .submitted
    }

    /// Decodes the `delete_account` 200 body. A missing/unparseable `purge_after`
    /// is non-fatal — the 200 itself is the deletion confirmation.
    nonisolated static func deletionResult(from data: Data) -> DeletionResult {
        struct Body: Decodable { let status: String?; let purge_after: String? }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        return DeletionResult(purgeAfter: body?.purge_after.flatMap(Self.parseISO8601))
    }

    /// Parses an ISO-8601 timestamp with or without fractional seconds — the
    /// function emits `Date.toISOString()` (fractional), but tolerate both.
    private nonisolated static func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// Decodes the `rsvp_event` 200 body `{ "status": …, "rsvp_count": int }`.
    /// `status` decodes straight into the canonical `TicketStatus` (going /
    /// waitlist / cancelled are all valid raw values). Throws `DecodingError` on
    /// a malformed body, which `rsvp` maps to `.unexpected`.
    nonisolated static func rsvpResult(from data: Data) throws -> RSVPResult {
        struct Body: Decodable { let status: TicketStatus; let rsvp_count: Int }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return RSVPResult(status: body.status, rsvpCount: body.rsvp_count)
    }

    /// Maps a non-2xx `rsvp_event` response to a stable `RSVPError`, keyed off the
    /// HTTP status and — for the two 400 codes — the stable `{"error"}` slug.
    /// `403` is only ever `verification_required` per the spec; `invalid_action`
    /// (a client bug) collapses to `.unexpected` so no raw code reaches the UI.
    nonisolated static func mapRSVPError(status: Int, data: Data) -> RSVPError {
        switch status {
        case 401: return .auth
        case 403: return .verificationRequired
        case 404: return .notFound
        case 429: return .rateLimited
        case 503: return .unavailable
        case 400: return errorCode(from: data) == "event_not_open" ? .eventNotOpen : .unexpected
        default:  return .unexpected
        }
    }

    /// Extracts the stable `{"error":"<code>"}` slug from an error body, or nil.
    /// Only used to split the two 400 RSVP codes — never surfaced to the user.
    nonisolated static func errorCode(from data: Data) -> String? {
        struct Body: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error
    }
}
