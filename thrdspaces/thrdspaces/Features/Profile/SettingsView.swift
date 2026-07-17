//
//  SettingsView.swift
//  ThrdSpaces — Features/Profile
//
//  Settings tree under Profile: Terms of Use (the T6 EULA copy, read-only — no
//  re-acceptance), a monitored contact email, blocked users, sign out, and the
//  App Store 5.1.1(v) account-deletion entry. The contact email is read from
//  `Configuration.plist` (amendment A3) — no email literal appears in Swift
//  source. Sign-out clears the Keychain session via AuthRepository and returns
//  to the onboarding root.
//

import SwiftUI

/// App-level support metadata sourced from `Configuration.plist`. Keeping the
/// contact address in config (A3) means no support-email literal lives in Swift
/// source — the plist is the single place to change it.
enum AppSupport {
    static var supportEmail: String? {
        guard
            let url = Bundle.main.url(forResource: "Configuration", withExtension: "plist"),
            let dict = NSDictionary(contentsOf: url),
            let email = dict["SupportEmail"] as? String,
            !email.isEmpty
        else { return nil }
        return email
    }
}

struct SettingsView: View {
    var onSignOut: () -> Void = {}

    @State private var isSigningOut = false
    @State private var showSignOutConfirm = false
    @State private var signOutError: String?

    private let auth = AuthRepository()

    var body: some View {
        Form {
            aboutSection
            safetySection
            accountSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Sign out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await signOut() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't sign out", isPresented: Binding(
            get: { signOutError != nil }, set: { if !$0 { signOutError = nil } }
        )) {
            Button("OK", role: .cancel) { signOutError = nil }
        } message: {
            Text(signOutError ?? "")
        }
    }

    // MARK: Sections

    private var aboutSection: some View {
        Section("About") {
            NavigationLink {
                TermsOfUseView()
            } label: {
                Label("Terms of Use", systemImage: "doc.text")
            }
            .accessibilityLabel("Terms of Use")

            if let email = AppSupport.supportEmail, let url = URL(string: "mailto:\(email)") {
                Link(destination: url) {
                    HStack {
                        Label("Contact support", systemImage: "envelope")
                        Spacer()
                        Text(email)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Contact support at \(email)")
            }
        }
    }

    private var safetySection: some View {
        Section("Safety") {
            NavigationLink {
                BlockedUsersView()
            } label: {
                Label("Blocked users", systemImage: "hand.raised")
            }
            .accessibilityLabel("Blocked users")
        }
    }

    private var accountSection: some View {
        Section("Account") {
            Button {
                showSignOutConfirm = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(isSigningOut)
            .accessibilityLabel("Sign out")

            NavigationLink {
                AccountDeletionView(onSignOut: onSignOut)
            } label: {
                Label("Delete account", systemImage: "trash")
                    .foregroundStyle(Theme.terracotta)
            }
            .accessibilityLabel("Delete account")
        }
    }

    // MARK: Actions

    private func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try await auth.signOut()
            onSignOut()
        } catch {
            signOutError = ProfileErrorCopy.message(for: error)
        }
    }
}

// MARK: - Read-only Terms of Use

/// Renders the T6 EULA copy read-only. Reuses `EULAViewModel.sections` — the
/// single source of terms text — without the acceptance gate (that flow, and its
/// audit write, belongs only to onboarding).
private struct TermsOfUseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(EULAViewModel.sections, id: \.heading) { section in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(section.heading)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.ink)
                        Text(section.body)
                            .font(Theme.Typography.body)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(section.heading). \(section.body)")
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.cream.ignoresSafeArea())
        .navigationTitle("Terms of Use")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Preview

#Preview("Settings") {
    NavigationStack { SettingsView() }
}
