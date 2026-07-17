//
//  EULAView.swift
//  ThrdSpaces — Features/Onboarding
//
//  Terms of Use acceptance (App Store Guideline 1.2). The user must explicitly
//  accept before the account becomes active; acceptance is recorded as an
//  `eula_accept` audit event. Accept unlocks once the user has either scrolled
//  to the end of the terms or ticked the agreement checkbox — the checkbox path
//  keeps the gate reachable for VoiceOver users who don't scroll visually.
//

import SwiftUI
import Combine

struct EULAView: View {
    /// Fired once acceptance has been recorded in the audit trail.
    var onAccepted: () -> Void

    @StateObject private var viewModel = EULAViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            termsScroll
            footer
        }
        .background(Theme.cream.ignoresSafeArea())
        .task { viewModel.onAccepted = onAccepted }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Text("Terms of Use")
                .font(Theme.Typography.largeTitle)
                .foregroundStyle(Theme.ink)
            Text("Please read and accept to continue.")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terms of Use. Please read and accept to continue.")
    }

    // MARK: - Scrollable terms

    private var termsScroll: some View {
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
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.lg)
        }
        // Native scroll-position detection — enables Accept once the reader
        // reaches the end of the terms.
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 24
        } action: { _, reachedBottom in
            if reachedBottom { viewModel.markScrolledToBottom() }
        }
    }

    // MARK: - Footer (checkbox + accept)

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Toggle(isOn: $viewModel.acceptedCheckbox) {
                Text("I have read and agree to the Terms of Use.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.ink)
            }
            .tint(Theme.terracotta)
            .accessibilityLabel("I have read and agree to the Terms of Use")

            if let message = viewModel.errorMessage {
                Text(message)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.terracotta)
                    .accessibilityAddTraits(.isStaticText)
            }

            ThrdButton(title: "Accept and continue", isLoading: viewModel.isBusy) {
                Task { await viewModel.accept() }
            }
            .disabled(!viewModel.canAccept || viewModel.isBusy)
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
    }
}

// MARK: - View model

@MainActor
final class EULAViewModel: ObservableObject {
    @Published var acceptedCheckbox = false
    @Published private(set) var hasScrolledToBottom = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    var onAccepted: (() -> Void)?
    private let repository = AuthRepository()

    /// Version tag recorded alongside each acceptance so the consent trail is
    /// versioned when the hosted terms are updated.
    ///
    /// ponytail: placeholder in-app terms copy below — the hosted Terms of Use
    /// (docs/compliance/terms.md) replaces this text and this version tag before
    /// App Store submission. Wire the final copy + version when that doc lands.
    static let termsVersion = "placeholder-2026-07"

    var canAccept: Bool { acceptedCheckbox || hasScrolledToBottom }

    func markScrolledToBottom() {
        // Latch — once reached, stays enabled even if the user scrolls back up.
        if !hasScrolledToBottom { hasScrolledToBottom = true }
    }

    func accept() async {
        guard canAccept, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let metadata = AuthRepository.eulaConsentMetadata(
            deviceID: KeychainTokenStore().deviceFingerprint,
            termsVersion: Self.termsVersion
        )
        do {
            try await repository.logConsent(action: .eulaAccept, metadata: metadata)
            onAccepted?()
        } catch {
            // Acceptance must be recorded before proceeding — keep the user here
            // to retry rather than advancing without the consent record.
            errorMessage = "We couldn't record your acceptance. Check your connection and try again."
        }
    }

    // Placeholder terms copy (see `termsVersion` ponytail). Covers the
    // Guideline 1.2 categories reviewers look for: prohibited content, reporting,
    // blocking, zero tolerance for objectionable users, and the 18+ requirement.
    struct Section { let heading: String; let body: String }
    static let sections: [Section] = [
        Section(heading: "Welcome to Thrd Spaces",
                body: "Thrd Spaces helps you discover communities and events in the physical places near you. By creating an account you agree to these Terms of Use."),
        Section(heading: "You must be 18 or older",
                body: "Accounts are for adults aged 18 and over. You confirm that you meet this requirement."),
        Section(heading: "Be respectful",
                body: "There is zero tolerance for objectionable content or abusive behaviour, including harassment, hate speech, threats, and spam. Content that violates these rules may be removed and accounts may be suspended."),
        Section(heading: "Reporting and blocking",
                body: "You can report any content or person, and block anyone, from within the app. Reports are reviewed and acted on. Blocking removes that person from your experience."),
        Section(heading: "Your safety",
                body: "Meet in public places and use your judgement. Thrd Spaces provides safety tools but cannot guarantee the conduct of others."),
        Section(heading: "Contact",
                body: "Questions about these terms can be sent to the support contact listed in the app's settings."),
    ]
}

// MARK: - Preview

#Preview("EULA · Light") {
    EULAView(onAccepted: {})
        .preferredColorScheme(.light)
}

#Preview("EULA · Dark") {
    EULAView(onAccepted: {})
        .preferredColorScheme(.dark)
}
