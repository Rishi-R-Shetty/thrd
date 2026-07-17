//
//  AuthRepository.swift
//  ThrdSpaces — Features/Onboarding
//
//  The ONLY place that touches Supabase Auth. Views and view models call these
//  methods; they never reach `SupabaseClientProvider.shared` directly (keeps
//  the RLS/auth boundary in one auditable file — threat-model Layer 2).
//
//  A concrete struct, not a protocol: there is a single implementation and the
//  integration test exercises the live backend, so a mock would add nothing.
//
//  Sessions land in the Keychain automatically — the client was built in T4
//  with `KeychainTokenStore` as its `AuthLocalStorage`, so every token the SDK
//  writes here inherits `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. This
//  file adds no other token persistence.
//

import Foundation
import Supabase

struct AuthRepository: Sendable {

    /// Reaches the shared client's auth namespace. `SupabaseClient` is
    /// `Sendable`, so this is safe from any isolation domain.
    private var auth: AuthClient { SupabaseClientProvider.shared.auth }

    // MARK: - Sign in with Apple

    /// Verifies an Apple identity token through Supabase Auth. The `nonce` is
    /// the RAW (unhashed) value; Supabase re-hashes it server-side and checks
    /// it — along with `iss`/`aud` and Apple's signature — against the token's
    /// claims. We never assert the identity ourselves (threat-model Layer 2).
    nonisolated func signInWithApple(idToken: String, nonce: String) async throws -> Session {
        do {
            let session = try await auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
            )
            try await ensureUserRow(userID: session.user.id)
            return session
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Phone OTP

    /// Requests an SMS one-time passcode. Rate limits (3/phone/hr, 10/IP/hr)
    /// are enforced by Supabase Auth — we never implement a client-side bypass;
    /// a tripped limit comes back as `APIError.server(status: 429)`.
    nonisolated func requestOTP(phone: String) async throws {
        let normalized = try Self.normalizeToE164(phone)
        do {
            try await auth.signInWithOTP(phone: normalized, shouldCreateUser: true)
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Verifies the SMS code and, on success, ensures the caller's profile row.
    nonisolated func verifyOTP(phone: String, code: String) async throws -> Session {
        let normalized = try Self.normalizeToE164(phone)
        do {
            let response = try await auth.verifyOTP(phone: normalized, token: code, type: .sms)
            guard let session = response.session else { throw APIError.auth }
            try await ensureUserRow(userID: session.user.id)
            return session
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Session lifecycle

    /// Refreshes the persisted session on launch and returns the signed-in
    /// user's id. Reading `auth.session` loads the Keychain session AND rotates
    /// an expired access token via the 30-day refresh token before returning —
    /// so the caller never proceeds on a stale token. Throws
    /// `AuthError.sessionMissing` (mapped to `APIError.auth`) when there is no
    /// session to restore.
    ///
    /// This replaces T5's synchronous `restoreSession()` existence check: the
    /// OnboardingCoordinator now owns launch navigation and refreshes here, so
    /// the first authenticated call after launch already carries a fresh token.
    nonisolated func refreshedUserID() async throws -> UUID {
        do {
            return try await auth.session.user.id
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Signs out and clears the session from the Keychain (the SDK routes the
    /// delete through our `KeychainTokenStore`).
    nonisolated func signOut() async throws {
        do {
            try await auth.signOut()
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Profile row bootstrap

    /// Columns the client is permitted to write on first insert (migration
    /// grants insert on `id, handle, display_name, bio, interests`). We write
    /// only the three we can fill without user input.
    private struct NewUserRow: Encodable {
        let id: String
        let handle: String
        let display_name: String
    }

    /// Creates the caller's `public.users` row if it does not already exist.
    /// `ignoreDuplicates: true` makes this `INSERT … ON CONFLICT (id) DO
    /// NOTHING`, so a re-auth never clobbers the real handle the user picks in
    /// T6/T7. The placeholder handle is deterministic and passes the DB's
    /// `^[a-z0-9_]{3,30}$` check.
    ///
    /// ponytail: the row is only ensured inside the sign-in path — if the
    /// upsert fails transiently the session still persists and a later launch
    /// skips this call. T6's coordinator must re-ensure the row on entry before
    /// any profile-dependent write. Upgrade to a server-side trigger on
    /// `auth.users` insert if this proves flaky.
    nonisolated func ensureUserRow(userID: UUID) async throws {
        let handle = Self.placeholderHandle(for: userID)
        let row = NewUserRow(id: userID.uuidString, handle: handle, display_name: handle)
        do {
            try await SupabaseClientProvider.shared
                .from("users")
                .upsert(row, onConflict: "id", returning: .minimal, ignoreDuplicates: true)
                .execute()
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Deterministic placeholder handle: `user_` + the first 8 chars of the id,
    /// lowercased. A UUID's first block is 8 hex digits, so the result always
    /// satisfies `^[a-z0-9_]{3,30}$`.
    nonisolated static func placeholderHandle(for id: UUID) -> String {
        "user_" + id.uuidString.prefix(8).lowercased()
    }

    // MARK: - Onboarding: interests

    /// One-row decode target for `fetchOwnInterests`.
    private struct InterestsRow: Decodable { let interests: [String] }

    /// Overwrites the caller's `users.interests` with `slugs`. Every slug is
    /// validated against the fixed `InterestTag.all` list FIRST — a value
    /// outside the 12 contract slugs is rejected before any network call, so a
    /// tampered client can never store an arbitrary tag (the DB's `text[]`
    /// column has no per-element CHECK; this is the trust boundary for it).
    /// The `.eq("id", …)` filter plus the `users_update_own` RLS policy both
    /// scope the write to the caller's own row; the migration grants UPDATE on
    /// the `interests` column only, so no other column can be touched here.
    nonisolated func updateInterests(_ slugs: [String]) async throws {
        let allowed = Set(InterestTag.all.map(\.id))
        guard slugs.allSatisfy(allowed.contains) else {
            throw ValidationError.invalidInterestSlug
        }
        let userID = try await auth.session.user.id
        do {
            try await SupabaseClientProvider.shared
                .from("users")
                .update(["interests": slugs], returning: .minimal)
                .eq("id", value: userID.uuidString)
                .execute()
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Reads the caller's own `users.interests`. RLS (`users_select_own`) plus
    /// the explicit `.eq` limit this to the caller's row. Used on launch to
    /// derive "already onboarded" (see OnboardingCoordinator).
    nonisolated func fetchOwnInterests() async throws -> [String] {
        let userID = try await auth.session.user.id
        do {
            let row: InterestsRow = try await SupabaseClientProvider.shared
                .from("users")
                .select("interests")
                .eq("id", value: userID.uuidString)
                .single()
                .execute()
                .value
            return row.interests
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Onboarding: consent audit trail

    /// The only two audit actions a client may insert (migration policy
    /// `audit_insert_consent`). Modeled as an enum so a disallowed action is
    /// unrepresentable at the call site — the RLS policy is the real gate, this
    /// just makes the boundary self-documenting.
    enum ConsentAction: String { case ageAttestation = "age_attestation", eulaAccept = "eula_accept" }

    /// Encodable audit row. `user_id` is the verified session user; the RLS
    /// policy re-checks `user_id = auth.uid()` server-side, so a spoofed id is
    /// rejected, not trusted. `id`/`created_at` use column defaults.
    private struct AuditRow: Encodable {
        let user_id: String
        let action: String
        let metadata: [String: AnyJSON]
    }

    /// Inserts one consent event into `audit_log`. The client has INSERT on
    /// exactly `(user_id, action, metadata)` and only for these two actions;
    /// `audit_log` is UPDATE/DELETE-revoked for every role, so this trail is
    /// append-only. Errors map through `APIError` (no schema leak).
    nonisolated func logConsent(action: ConsentAction, metadata: [String: AnyJSON]) async throws {
        let userID = try await auth.session.user.id
        let row = AuditRow(user_id: userID.uuidString, action: action.rawValue, metadata: metadata)
        do {
            try await SupabaseClientProvider.shared
                .from("audit_log")
                .insert(row, returning: .minimal)
                .execute()
        } catch {
            throw Self.mapError(error)
        }
    }

    /// EULA-accept metadata. Records the device and the terms version accepted
    /// so the consent trail is versioned. No age or personal data here.
    nonisolated static func eulaConsentMetadata(deviceID: String, termsVersion: String) -> [String: AnyJSON] {
        [
            "device_id": .string(deviceID),
            "terms_version": .string(termsVersion),
        ]
    }

    // MARK: - Input validation

    enum ValidationError: Error { case invalidPhoneNumber, invalidInterestSlug }

    /// Normalizes user-entered phone input to E.164. Strips spaces, dashes,
    /// parentheses, and dots, then requires a leading `+` country code and
    /// 8–15 total digits. User-generated input at a trust boundary — validated,
    /// never logged.
    ///
    /// ponytail: naive normalizer — no per-country length rules or national-
    /// format inference (a number without `+` is rejected, not guessed).
    /// Upgrade to a libphonenumber-style parser if invalid-number support load
    /// climbs; no new SPM dep is authorized for T5.
    nonisolated static func normalizeToE164(_ raw: String) throws -> String {
        let stripped = raw.filter { !" -()./".contains($0) }
        let pattern = #"^\+[1-9][0-9]{7,14}$"#
        guard stripped.range(of: pattern, options: .regularExpression) != nil else {
            throw ValidationError.invalidPhoneNumber
        }
        return stripped
    }

    // MARK: - Error mapping

    /// Collapses SDK/transport errors into the app's `APIError`. Carries no
    /// server-supplied message text, so a backend response can't leak schema
    /// into the UI. Rate limits (HTTP 429) are preserved as a status so the UI
    /// can show a "try again later" state.
    nonisolated static func mapError(_ error: Error) -> APIError {
        switch error {
        case let apiError as APIError:
            return apiError
        case let authError as AuthError:
            if case let .api(_, _, _, response) = authError {
                return .server(status: response.statusCode)
            }
            return .auth
        case let urlError as URLError:
            return .network(underlying: urlError)
        default:
            return .network(underlying: error)
        }
    }
}

// MARK: - Age-gate audit metadata (amendment A1)

/// The EXACT `metadata` jsonb shape for an `age_attestation` audit event, per
/// phase-1 amendment A1: `{ device_id, method: "api" | "attestation",
/// api_result: String? }`. This is the gate *result* trail, not persisted age
/// data — `apiResult` is a coarse over/under-threshold category (never a
/// precise age) and is nil whenever the gate was cleared by self-attestation.
///
/// A plain struct so it is unit-testable without linking Supabase; the
/// `AnyJSON` conversion lives on `json` and is the only Supabase-typed member.
struct AgeAttestationMetadata: Equatable {
    enum Method: String { case api, attestation }

    let deviceID: String
    let method: Method
    let apiResult: String?

    /// The A1 jsonb payload passed to `AuthRepository.logConsent`.
    var json: [String: AnyJSON] {
        [
            "device_id": .string(deviceID),
            "method": .string(method.rawValue),
            "api_result": apiResult.map(AnyJSON.string) ?? .null,
        ]
    }
}
