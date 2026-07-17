//
//  AccountDeletionView.swift
//  ThrdSpaces — Features/Profile
//
//  In-app account deletion (App Store Guideline 5.1.1(v)). Two-step confirmation
//  with plain-language copy about what is deleted and the 30-day grace window.
//  Calls the `delete_account` Edge Function; the client signs out locally and
//  returns to onboarding ONLY on a confirmed 200. If the function is unavailable
//  (not deployed / unreachable → 404/503), it shows an error and does NOT sign
//  out or pretend the account was deleted.
//

import SwiftUI
import Combine

struct AccountDeletionView: View {
    var onSignOut: () -> Void = {}

    @StateObject private var viewModel = AccountDeletionViewModel()
    @State private var showFinalConfirm = false

    private let auth = AuthRepository()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                whatGetsDeleted
                graceExplanation
                if case let .failed(message) = viewModel.phase {
                    Text(message)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.terracotta)
                        .accessibilityAddTraits(.isStaticText)
                }
                ThrdButton(title: "Delete my account", isLoading: viewModel.phase == .deleting) {
                    showFinalConfirm = true
                }
                .disabled(viewModel.phase == .deleting)
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.cream.ignoresSafeArea())
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        // Step 2 of the two-step confirmation.
        .confirmationDialog(
            "Permanently delete your account?",
            isPresented: $showFinalConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task { await performDeletion() }
            }
            Button("Keep my account", role: .cancel) {}
        } message: {
            Text("Your account is deactivated now and deleted after 30 days. This can't be undone once the 30 days pass.")
        }
    }

    // MARK: Copy

    private var header: some View {
        Text("Deleting your account removes your profile and personal data from Thrd Spaces.")
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.ink)
    }

    private var whatGetsDeleted: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("What gets deleted")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.ink)
            bullet("Your profile — handle, display name, bio, and interests")
            bullet("Your RSVPs and community memberships")
            bullet("For safety and legal reasons, any reports you filed are kept only as anonymized records with your identity removed")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("What gets deleted: your profile, handle, display name, bio and interests; your RSVPs and community memberships. For safety and legal reasons, any reports you filed are kept only as anonymized records with your identity removed.")
    }

    private var graceExplanation: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("30-day grace period")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.ink)
            Text("Your account is deactivated immediately and permanently deleted after 30 days. Sign in again within 30 days to cancel the deletion.")
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("30-day grace period. Your account is deactivated immediately and permanently deleted after 30 days. Sign in again within 30 days to cancel the deletion.")
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Action

    private func performDeletion() async {
        await viewModel.delete(deviceID: KeychainTokenStore().deviceFingerprint) {
            // Only reached on a confirmed 200. Clear the local session and route
            // back to onboarding; a local sign-out hiccup still routes home
            // (the server already recorded the deletion).
            try? await auth.signOut()
            onSignOut()
        }
    }
}

// MARK: - View model

@MainActor
final class AccountDeletionViewModel: ObservableObject {
    enum Phase: Equatable { case idle, deleting, failed(String), deleted }

    @Published private(set) var phase: Phase = .idle

    private let functions = EdgeFunctionClient()

    /// Requests deletion. On a confirmed 200 it sets `.deleted` and runs
    /// `onDeleted` (local sign-out + routing). On any failure it sets `.failed`
    /// and never runs `onDeleted` — the user stays signed in.
    func delete(deviceID: String, onDeleted: () async -> Void) async {
        guard phase != .deleting else { return }
        phase = .deleting
        let result: Result<Void, Error>
        do {
            _ = try await functions.deleteAccount(deviceID: deviceID)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        if applyDeletionResult(result) {
            await onDeleted()
        }
    }

    /// Applies a deletion result to `phase` and reports whether the caller should
    /// sign out. Factored out so the "sign out only on 200, never on error"
    /// invariant is unit-testable without a live function.
    @discardableResult
    func applyDeletionResult(_ result: Result<Void, Error>) -> Bool {
        switch result {
        case .success:
            phase = .deleted
            return true
        case let .failure(error):
            phase = .failed(ProfileErrorCopy.message(for: error))
            return false
        }
    }
}

// MARK: - Preview

#Preview("Delete Account") {
    NavigationStack { AccountDeletionView() }
}
