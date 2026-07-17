//
//  ProfileViewModel.swift
//  ThrdSpaces — Features/Profile
//
//  Own-profile state + the Profile feature's table boundary. Views never touch
//  the Supabase client: `ProfileRepository` owns every `users`/`blocks`/
//  `public_profiles` read and write (mirrors AuthRepository — a concrete struct,
//  single implementation, no protocol), and Edge Function calls go through
//  `EdgeFunctionClient`. Interests reuse AuthRepository's already-validated
//  writer rather than a second interests path.
//

import Foundation
import Combine
import Supabase

// MARK: - Value type

/// A profile the UI renders. Own-profile loads fill `bio`; a `public_profiles`
/// row (e.g. a blocked user) leaves `bio` nil — that view has no bio column.
struct ProfileSummary: Identifiable, Equatable {
    let id: UUID
    let handle: String
    let displayName: String
    let bio: String?
    let interests: [String]

    /// The InterestTag labels for this profile's slugs, in the fixed contract
    /// order. Unknown slugs are dropped (defensive — the picker only ever writes
    /// contract slugs).
    var interestLabels: [String] {
        InterestTag.all.filter { interests.contains($0.id) }.map(\.label)
    }
}

// MARK: - Validation (pure, unit-tested trust boundary)

/// Client-side validation for the editable profile fields. The DB CHECKs are the
/// real boundary; this is the pre-flight that keeps a doomed write off the wire
/// and gives the user an inline reason.
enum ProfileValidation {
    static let handlePattern = "^[a-z0-9_]{3,30}$"
    static let displayNameLimit = 50
    static let bioLimit = 280

    /// `handle` must already be the normalized (lowercased) form.
    static func isValidHandle(_ handle: String) -> Bool {
        handle.range(of: handlePattern, options: .regularExpression) != nil
    }

    /// Normalizes user input to the stored form: lowercased, trimmed.
    static func normalizeHandle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValidDisplayName(_ raw: String) -> Bool {
        (1...displayNameLimit).contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    static func isValidBio(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).count <= bioLimit
    }
}

// MARK: - Error copy (non-leaking; mirrors AuthViewModel.message)

/// Maps `APIError` to friendly, non-leaking copy. 429 gets a "try again later"
/// message; a not-deployed/unreachable function (404/503) reads as a server
/// reachability problem; everything else stays generic so no backend detail
/// reaches the UI.
enum ProfileErrorCopy {
    static func message(for error: Error) -> String {
        guard let apiError = error as? APIError else {
            return "Something went wrong. Please try again."
        }
        switch apiError {
        case let .server(status) where status == 429:
            return "You're doing that too often. Please try again in a little while."
        case let .server(status) where status == 404 || status == 503:
            return "We couldn't reach the server. Please try again later."
        case .network:
            return "No connection. Check your internet and try again."
        case .auth:
            return "Your session has expired. Please sign in again."
        default:
            return "Something went wrong. Please try again."
        }
    }
}

// MARK: - Repository (the users/blocks/public_profiles boundary)

/// The Profile feature's only table-access surface. Every query is RLS-scoped to
/// the caller (own `users` row, own `blocks` rows); cross-user reads go through
/// the `public_profiles` view. A concrete struct — one implementation, no
/// protocol (matches AuthRepository).
struct ProfileRepository: Sendable {

    private let auth = AuthRepository()
    private var client: SupabaseClient { SupabaseClientProvider.shared }

    /// Reads the caller's own profile. RLS (`users_select_own`) plus the explicit
    /// `.eq` limit this to the caller's row.
    func fetchOwnProfile() async throws -> ProfileSummary {
        let userID = try await auth.refreshedUserID()
        struct Row: Decodable {
            let id: UUID
            let handle: String
            let display_name: String
            let bio: String?
            let interests: [String]
        }
        do {
            let row: Row = try await client
                .from("users")
                .select("id, handle, display_name, bio, interests")
                .eq("id", value: userID.uuidString)
                .single()
                .execute()
                .value
            return ProfileSummary(
                id: row.id, handle: row.handle, displayName: row.display_name,
                bio: row.bio, interests: row.interests
            )
        } catch {
            throw AuthRepository.mapError(error)
        }
    }

    /// Updates the caller's editable text fields. The migration grants UPDATE on
    /// exactly `(handle, display_name, bio, …)`; the `.eq` + `users_update_own`
    /// policy scope the write to the caller's row. A handle collision surfaces as
    /// a `PostgrestError` with code `23505` — rethrown for the caller to map to
    /// "That handle is taken" (this is the only path allowed to leak that a
    /// handle exists, and only to its would-be owner).
    func updateProfile(handle: String, displayName: String, bio: String?) async throws {
        let userID = try await auth.refreshedUserID()
        struct Update: Encodable { let handle: String; let display_name: String; let bio: String? }
        try await client
            .from("users")
            .update(Update(handle: handle, display_name: displayName, bio: bio), returning: .minimal)
            .eq("id", value: userID.uuidString)
            .execute()
    }

    /// Lists the caller's blocked users as public profiles. Two scoped reads:
    /// the caller's own `blocks` rows, then the matching `public_profiles`.
    /// Embedding a view isn't reliably auto-detected by PostgREST, so this joins
    /// client-side — a bounded list (mass-block is rate-limited server-side).
    func fetchBlockedProfiles() async throws -> [ProfileSummary] {
        let userID = try await auth.refreshedUserID()
        do {
            struct BlockRow: Decodable { let blocked_id: UUID }
            let blocks: [BlockRow] = try await client
                .from("blocks")
                .select("blocked_id")
                .eq("blocker_id", value: userID.uuidString)
                .execute()
                .value
            guard !blocks.isEmpty else { return [] }

            struct PublicRow: Decodable { let id: UUID; let handle: String; let display_name: String }
            let profiles: [PublicRow] = try await client
                .from("public_profiles")
                .select("id, handle, display_name")
                .in("id", values: blocks.map { $0.blocked_id.uuidString })
                .execute()
                .value
            return profiles.map {
                ProfileSummary(id: $0.id, handle: $0.handle, displayName: $0.display_name,
                               bio: nil, interests: [])
            }
        } catch {
            throw AuthRepository.mapError(error)
        }
    }
}

// MARK: - View model

@MainActor
final class ProfileViewModel: ObservableObject {

    enum LoadState: Equatable {
        case loading
        case loaded(ProfileSummary)
        case failed(String)
    }

    /// Result of an edit save. `handleTaken` is distinct so the edit form can
    /// pin the message to the handle field.
    enum SaveOutcome: Equatable { case saved, handleTaken, failed(String) }

    @Published private(set) var state: LoadState = .loading
    /// Transient feedback for a block/report action from the `.other`-mode menu.
    @Published var actionMessage: String?

    private let repository = ProfileRepository()
    private let auth = AuthRepository()
    private let functions = EdgeFunctionClient()

    var profile: ProfileSummary? {
        if case let .loaded(summary) = state { return summary }
        return nil
    }

    func loadOwnProfile() async {
        state = .loading
        do {
            state = .loaded(try await repository.fetchOwnProfile())
        } catch {
            state = .failed(ProfileErrorCopy.message(for: error))
        }
    }

    /// Persists edited fields. Text fields go through `ProfileRepository`; the
    /// interests reuse AuthRepository's validated writer (the trust boundary for
    /// the `interests` array). On success the loaded state reflects the new
    /// values so the profile screen updates without a reload.
    ///
    /// ponytail: two writes (text fields, then interests) are not a single
    /// transaction — both are RLS-scoped to the caller's own row and idempotent
    /// on retry, so a partial save is safe to re-run. Upgrade to one Edge
    /// Function write if profile edits ever need atomicity across fields.
    func saveProfile(handle rawHandle: String, displayName rawName: String,
                     bio rawBio: String, interests: Set<String>) async -> SaveOutcome {
        let handle = ProfileValidation.normalizeHandle(rawHandle)
        let displayName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBio = rawBio.trimmingCharacters(in: .whitespacesAndNewlines)
        let bio: String? = trimmedBio.isEmpty ? nil : trimmedBio

        do {
            try await repository.updateProfile(handle: handle, displayName: displayName, bio: bio)
            try await auth.updateInterests(Array(interests))
            if let current = profile {
                state = .loaded(ProfileSummary(id: current.id, handle: handle,
                                               displayName: displayName, bio: bio,
                                               interests: Array(interests)))
            }
            return .saved
        } catch AuthRepository.ValidationError.invalidInterestSlug {
            return .failed("Please choose from the listed interests.")
        } catch {
            if Self.isHandleTaken(error) { return .handleTaken }
            return .failed(ProfileErrorCopy.message(for: error))
        }
    }

    /// Blocks a user from the `.other`-mode menu, then surfaces a neutral notice.
    func blockUser(_ userID: UUID) async {
        do {
            try await functions.block(userID: userID)
            actionMessage = "This person has been blocked."
            // Block invalidation (T18): tell Discover to re-fetch so this person's
            // events/previews drop off promptly, not on the next manual refresh.
            BlockSignal.userBlocked()
        } catch {
            actionMessage = ProfileErrorCopy.message(for: error)
        }
    }

    /// True when `error` is a Postgres unique-violation (SQLSTATE 23505) — a
    /// handle collision. Factored off the `PostgrestError.code` string so the
    /// mapping is unit-testable without constructing an SDK error.
    nonisolated static func isHandleTaken(_ error: Error) -> Bool {
        handleTaken(fromPostgrestCode: (error as? PostgrestError)?.code)
    }

    nonisolated static func handleTaken(fromPostgrestCode code: String?) -> Bool {
        code == "23505"
    }
}
