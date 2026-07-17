//
//  AgeGateView.swift
//  ThrdSpaces — Features/Onboarding
//
//  The 18+ gate (D3 + amendment A1). No under-18 account may reach an active
//  state — a non-negotiable guard.
//
//  Order of enforcement:
//   1. Ask the OS Declared Age Range API for a single 18-gate. A shared result
//      that reads as 18+ passes; under-18 blocks account creation (terminal
//      screen + sign-out).
//   2. If the API is unavailable in this region / for this account, or the user
//      declines to share, fall back to an explicit 18+ self-attestation
//      (unchecked by default; Continue stays disabled until it is checked).
//   3. Age data is used ephemerally at the decision point. The only thing that
//      persists is the audit `age_attestation` event, whose metadata is a
//      coarse over/under-18 category — never a precise age.
//

import SwiftUI
import Combine
import DeclaredAgeRange

// MARK: - View

struct AgeGateView: View {
    /// Cleared the 18+ gate → advance to the EULA.
    var onPassed: () -> Void
    /// Under-18: signed out; the coordinator returns to the top of the flow.
    var onBlockedSignOut: () -> Void

    @StateObject private var viewModel: AgeGateViewModel
    @Environment(\.requestAgeRange) private var requestAgeRange

    init(onPassed: @escaping () -> Void,
         onBlockedSignOut: @escaping () -> Void,
         viewModel: AgeGateViewModel = AgeGateViewModel()) {
        self.onPassed = onPassed
        self.onBlockedSignOut = onBlockedSignOut
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            Theme.cream.ignoresSafeArea()
            content
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: 480)
        }
        .task {
            // Wire the coordinator callbacks before any transition can fire.
            viewModel.onPassed = onPassed
            viewModel.onBlockedSignOut = onBlockedSignOut
            if viewModel.autoRunAgeCheck { await performAgeCheck() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .checking: checkingView
        case .attestation: attestationView
        case .blocked: blockedView
        case .passed: ProgressView() // coordinator swaps this view out
        }
    }

    // MARK: - Checking (API in flight, or a pass-audit retry)

    private var checkingView: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .accessibilityLabel("Checking your age")
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.terracotta)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isStaticText)
                ThrdButton(title: "Try again", isLoading: viewModel.isBusy) {
                    Task { await viewModel.retryPass() }
                }
            }
        }
    }

    // MARK: - Self-attestation fallback

    private var attestationView: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("One quick check")
                    .font(Theme.Typography.largeTitle)
                    .foregroundStyle(Theme.ink)
                Text("Thrd Spaces is for adults. Please confirm your age to continue.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Toggle(isOn: $viewModel.attestationChecked) {
                Text("I confirm I am 18 years of age or older.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.ink)
            }
            .tint(Theme.terracotta)
            .accessibilityLabel("I confirm I am 18 years of age or older")
            .accessibilityHint("Required to continue")

            if let message = viewModel.errorMessage {
                Text(message)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.terracotta)
                    .accessibilityAddTraits(.isStaticText)
            }

            ThrdButton(title: "Continue", isLoading: viewModel.isBusy) {
                Task { await viewModel.confirmAttestation() }
            }
            .disabled(!viewModel.attestationChecked || viewModel.isBusy)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Blocked terminal

    private var blockedView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(Theme.terracotta)
                .accessibilityHidden(true)
            Text("You must be 18 or older")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("Thanks for your interest in Thrd Spaces. Accounts are for adults aged 18 and over, so we can't set one up right now.")
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ThrdButton(title: "Back to sign in", style: .secondary) {
                Task { await viewModel.signOutFromBlock() }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: - OS age-range request

    private func performAgeCheck() async {
        // Compile-time availability guard: `DeclaredAgeRange` requires iOS 26.0.
        // The deployment target is already ≥ 26, so this branch is always taken
        // today — it keeps the gate correct if the target is ever lowered. The
        // *substantive* availability handling is the runtime fallback below
        // (`.declinedSharing` / a thrown `.notAvailable`).
        if #available(iOS 26.0, *) {
            do {
                let response = try await requestAgeRange(ageGates: AgeGateViewModel.threshold)
                switch response {
                case .declinedSharing:
                    viewModel.fallBackToAttestation()
                case .sharing(let range):
                    await viewModel.applyAPIResult(lowerBound: range.lowerBound,
                                                   upperBound: range.upperBound)
                @unknown default:
                    viewModel.fallBackToAttestation()
                }
            } catch {
                // API unavailable (region / older account) or a transport
                // failure → explicit self-attestation (D3).
                viewModel.fallBackToAttestation()
            }
        } else {
            viewModel.fallBackToAttestation()
        }
    }
}

// MARK: - View model

@MainActor
final class AgeGateViewModel: ObservableObject {

    enum State: Equatable { case checking, attestation, blocked, passed }
    enum Decision: Equatable { case adult, minor }

    @Published private(set) var state: State = .checking
    @Published var attestationChecked = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    /// The single gate we enforce at launch: 18+ (D3 — no under-18 accounts).
    nonisolated static let threshold = 18

    /// Coarse gate-result categories for the audit trail. Deliberately binary
    /// (over/under the gate), never a precise age — this is the gate result,
    /// not persisted age data (A1).
    nonisolated static let adultCategory = "18_or_over"
    nonisolated static let minorCategory = "under_18"

    var onPassed: (() -> Void)?
    var onBlockedSignOut: (() -> Void)?

    /// When false the view skips the OS age request on appear — used by previews
    /// (and any host without the entitlement) to render a seeded state.
    let autoRunAgeCheck: Bool

    /// `nonisolated` so it can be used as the default argument of the
    /// (nonisolated) `AgeGateView.init` without hopping to the main actor.
    nonisolated init(autoRunAgeCheck: Bool = true) {
        self.autoRunAgeCheck = autoRunAgeCheck
    }

    private let repository = AuthRepository()
    private var deviceID: String { KeychainTokenStore().deviceFingerprint }

    /// Remembers a pass whose audit write failed, so it can be retried without
    /// re-presenting the system age sheet.
    private var pendingPass: AgeAttestationMetadata?

    // MARK: Pure decision (unit-tested)

    /// Maps a single-gate API range to adult/minor. A shared range brackets the
    /// user against `threshold`: `lowerBound >= threshold` ⇒ adult; anything
    /// else (including an open/absent lower bound) ⇒ minor. Fails closed toward
    /// `.minor`, so a malformed or empty range can never grant an adult pass.
    nonisolated static func evaluate(lowerBound: Int?,
                                     upperBound: Int?,
                                     threshold: Int = AgeGateViewModel.threshold) -> Decision {
        if let lower = lowerBound, lower >= threshold { return .adult }
        return .minor
    }

    // MARK: API result

    func applyAPIResult(lowerBound: Int?, upperBound: Int?) async {
        switch Self.evaluate(lowerBound: lowerBound, upperBound: upperBound) {
        case .adult:
            await recordAndPass(AgeAttestationMetadata(deviceID: deviceID,
                                                       method: .api,
                                                       apiResult: Self.adultCategory))
        case .minor:
            await block(category: Self.minorCategory)
        }
    }

    func fallBackToAttestation() {
        state = .attestation
    }

    // MARK: Self-attestation

    func confirmAttestation() async {
        guard attestationChecked, !isBusy else { return }
        await recordAndPass(AgeAttestationMetadata(deviceID: deviceID,
                                                   method: .attestation,
                                                   apiResult: nil))
    }

    // MARK: Blocked terminal

    func signOutFromBlock() async {
        // Sign out so a blocked account can't reach an active state; the
        // coordinator then returns to the top of the flow.
        try? await repository.signOut()
        onBlockedSignOut?()
    }

    // MARK: Retry

    func retryPass() async {
        guard let pending = pendingPass else { return }
        await recordAndPass(pending)
    }

    // MARK: Internals

    private func recordAndPass(_ metadata: AgeAttestationMetadata) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await repository.logConsent(action: .ageAttestation, metadata: metadata.json)
            pendingPass = nil
            state = .passed
            onPassed?()
        } catch {
            // Consent must be recorded before an account becomes active, so a
            // write failure keeps the user here with a retry rather than
            // silently advancing.
            pendingPass = metadata
            errorMessage = "We couldn't confirm that. Check your connection and try again."
        }
    }

    private func block(category: String) async {
        // Best-effort trail — the block does NOT depend on the audit write
        // succeeding. The gate result is what matters; we still record it when
        // we can for the age-gate audit trail (A1).
        try? await repository.logConsent(
            action: .ageAttestation,
            metadata: AgeAttestationMetadata(deviceID: deviceID,
                                             method: .api,
                                             apiResult: category).json
        )
        state = .blocked
    }
}

// MARK: - Preview

#Preview("AgeGate · Attestation") {
    let vm = AgeGateViewModel(autoRunAgeCheck: false)
    vm.fallBackToAttestation() // deterministically render the attestation screen
    return AgeGateView(onPassed: {}, onBlockedSignOut: {}, viewModel: vm)
}
