//
//  ProfileView.swift
//  ThrdSpaces — Features/Profile
//
//  The Profile tab (own profile) and the presentational profile screen for any
//  `public_profiles` row. Avatars are initials on a deterministic color derived
//  from the user id (D2) — there is NO image picker or upload path anywhere in
//  Phase 1 (the CSAM scan pipeline doesn't land until Phase 3).
//
//  `.own` loads the caller's row through `ProfileViewModel` and offers Edit +
//  Settings. `.other` renders an injected summary and offers a ⋯ menu (Report /
//  Block) — Phase 1 only ever shows the user's own profile in the tab, so the
//  `.other` menu is exercised via BlockedUsersView rows and previews/tests.
//

import SwiftUI

// MARK: - Initials avatar (D2)

/// Deterministic initials + color for a user, derived from id and name. Pure so
/// the determinism is unit-testable; no image path exists (D2).
enum Avatar {
    /// A fixed palette. Text is always white on these, so they read in light and
    /// dark without per-scheme variants.
    static let palette: [Color] = [
        Color(hue: 0.02, saturation: 0.55, brightness: 0.80), // terracotta
        Color(hue: 0.38, saturation: 0.45, brightness: 0.55), // forest
        Color(hue: 0.58, saturation: 0.50, brightness: 0.70), // teal
        Color(hue: 0.72, saturation: 0.42, brightness: 0.70), // violet
        Color(hue: 0.10, saturation: 0.60, brightness: 0.80), // amber
        Color(hue: 0.90, saturation: 0.45, brightness: 0.72), // rose
    ]

    /// Up to two uppercase initials from the display name, falling back to the
    /// handle. Splits on spaces and underscores.
    static func initials(displayName: String, handle: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? handle : trimmed
        let words = source.split { $0 == " " || $0 == "_" }.prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : String(letters.prefix(2))
    }

    /// A stable palette index for a user id — same id always maps to the same
    /// color. Sums the uuid bytes so the whole id contributes.
    static func paletteIndex(for id: UUID) -> Int {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 + Int($1) }
        return sum % palette.count
    }

    static func color(for id: UUID) -> Color { palette[paletteIndex(for: id)] }
}

/// The circular initials badge.
struct InitialsAvatar: View {
    let profile: ProfileSummary
    var diameter: CGFloat = 96

    var body: some View {
        Circle()
            .fill(Avatar.color(for: profile.id))
            .frame(width: diameter, height: diameter)
            .overlay(
                Text(Avatar.initials(displayName: profile.displayName, handle: profile.handle))
                    .font(.system(size: diameter * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
            // The initials are decorative — the name is announced separately.
            .accessibilityHidden(true)
    }
}

// MARK: - Profile screen

struct ProfileView: View {
    enum Mode: Equatable {
        case own
        case other(ProfileSummary)
    }

    let mode: Mode
    /// Invoked after a local sign-out (from Settings) or a confirmed account
    /// deletion, to return to the onboarding root.
    var onSignOut: () -> Void = {}

    @StateObject private var viewModel = ProfileViewModel()
    @State private var showEdit = false
    @State private var showReport = false
    @State private var showBlockConfirm = false

    private var isOwn: Bool { mode == .own }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.cream.ignoresSafeArea())
                .navigationTitle("Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .task { if isOwn { await viewModel.loadOwnProfile() } }
        .sheet(isPresented: $showEdit) {
            if let current = viewModel.profile {
                ProfileEditView(viewModel: viewModel, current: current)
            }
        }
        .sheet(isPresented: $showReport) {
            if case let .other(summary) = mode {
                ReportSheetView(subjectID: summary.id, subjectName: "@\(summary.handle)")
            }
        }
        .confirmationDialog("Block this person?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            if case let .other(summary) = mode {
                Button("Block", role: .destructive) {
                    Task { await viewModel.blockUser(summary.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They won't be able to see you or contact you, and you won't see them.")
        }
        .alert("Done", isPresented: Binding(
            get: { viewModel.actionMessage != nil },
            set: { if !$0 { viewModel.actionMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.actionMessage = nil }
        } message: {
            Text(viewModel.actionMessage ?? "")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .own:
            switch viewModel.state {
            case .loading:
                ProgressView().accessibilityLabel("Loading your profile")
            case let .loaded(summary):
                profileBody(summary)
            case let .failed(message):
                failure(message)
            }
        case let .other(summary):
            profileBody(summary)
        }
    }

    private func profileBody(_ summary: ProfileSummary) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.md) {
                InitialsAvatar(profile: summary)
                    .padding(.top, Theme.Spacing.lg)

                VStack(spacing: Theme.Spacing.xxs) {
                    Text(summary.displayName)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    Text("@\(summary.handle)")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(summary.displayName), handle @\(summary.handle)")

                if let bio = summary.bio, !bio.isEmpty {
                    Text(bio)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.lg)
                }

                if !summary.interestLabels.isEmpty {
                    ReadOnlyChips(labels: summary.interestLabels)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Interests: \(summary.interestLabels.joined(separator: ", "))")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ThrdButton(title: "Try again", style: .secondary) {
                Task { await viewModel.loadOwnProfile() }
            }
            .fixedSize()
        }
        .padding(Theme.Spacing.xl)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        switch mode {
        case .own:
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView(onSignOut: onSignOut)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEdit = true }
                    .disabled(viewModel.profile == nil)
                    .accessibilityLabel("Edit profile")
            }
        case .other:
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showReport = true
                    } label: {
                        Label("Report", systemImage: "flag")
                    }
                    Button(role: .destructive) {
                        showBlockConfirm = true
                    } label: {
                        Label("Block", systemImage: "hand.raised")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }
        }
    }
}

// MARK: - Read-only interest chips

/// Non-interactive capsules for displaying interests. Reuses the adaptive-grid
/// flow of `ChipGroup` without its selection behaviour (that component is for
/// multi-select input; these are labels).
private struct ReadOnlyChips: View {
    let labels: [String]
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.xs)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Theme.Spacing.md)
                    .frame(minHeight: 36)
                    .frame(maxWidth: .infinity)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.15), lineWidth: 1))
            }
        }
    }
}

// MARK: - Previews

private extension ProfileSummary {
    static let preview = ProfileSummary(
        id: UUID(uuidString: "1E1C0DED-0000-4000-8000-000000000001")!,
        handle: "ada_l", displayName: "Ada Lovelace",
        bio: "Mathematician. Always up for coffee and a long walk.",
        interests: ["books", "coffee", "tech"]
    )
}

// Both previews use `.other` — `.own` loads from the backend at runtime.
#Preview("Profile · Light") {
    ProfileView(mode: .other(.preview))
        .preferredColorScheme(.light)
}

#Preview("Profile · Dark") {
    ProfileView(mode: .other(.preview))
        .preferredColorScheme(.dark)
}
