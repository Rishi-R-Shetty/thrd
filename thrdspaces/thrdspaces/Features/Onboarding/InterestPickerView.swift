//
//  InterestPickerView.swift
//  ThrdSpaces — Features/Onboarding
//
//  Pick at least 3 interests. Reuses the T2 `ChipGroup` (multi-select over a
//  `Set<String>` of tag slugs) fed from the fixed `InterestTag.all` list. On
//  continue the slugs are written to `users.interests` through the repository,
//  which validates them against the contract list before the DB write.
//

import SwiftUI
import Combine

struct InterestPickerView: View {
    /// Fired once the interests have persisted (≥ 3 written).
    var onComplete: () -> Void

    @StateObject private var viewModel = InterestPickerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                ChipGroup(items: viewModel.chipItems, selection: $viewModel.selection)
                    .padding(Theme.Spacing.lg)
            }
            footer
        }
        .background(Theme.cream.ignoresSafeArea())
        .task { viewModel.onComplete = onComplete }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Text("What are you into?")
                .font(Theme.Typography.largeTitle)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("Pick at least \(InterestPickerViewModel.minimumSelection) to help us find your people.")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("What are you into? Pick at least \(InterestPickerViewModel.minimumSelection) to help us find your people.")
    }

    // MARK: - Footer (progress + continue)

    private var footer: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text(viewModel.progressText)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(viewModel.progressAccessibilityLabel)

            if let message = viewModel.errorMessage {
                Text(message)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.terracotta)
                    .accessibilityAddTraits(.isStaticText)
            }

            ThrdButton(title: "Continue", isLoading: viewModel.isBusy) {
                Task { await viewModel.save() }
            }
            .disabled(!viewModel.canContinue || viewModel.isBusy)
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
    }
}

// MARK: - View model

@MainActor
final class InterestPickerViewModel: ObservableObject {
    @Published var selection: Set<String> = []
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    var onComplete: (() -> Void)?
    private let repository = AuthRepository()

    /// Client-side minimum. The server CHECK caps the array at ≤ 12; the fixed
    /// list contains exactly 12, so the upper bound can't be exceeded here.
    static let minimumSelection = 3

    var chipItems: [ChipItem] {
        InterestTag.all.map { ChipItem(id: $0.id, label: $0.label, systemImage: $0.sfSymbol) }
    }

    var canContinue: Bool { selection.count >= Self.minimumSelection }

    var progressText: String {
        canContinue ? "\(selection.count) selected"
                    : "\(selection.count) of \(Self.minimumSelection) selected"
    }

    var progressAccessibilityLabel: String {
        canContinue
            ? "\(selection.count) interests selected."
            : "\(selection.count) of \(Self.minimumSelection) required interests selected."
    }

    func save() async {
        guard canContinue, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            // The repository rejects any slug outside `InterestTag.all` before
            // the DB write — the trust boundary for the interests array.
            try await repository.updateInterests(Array(selection))
            onComplete?()
        } catch {
            errorMessage = "We couldn't save your interests. Please try again."
        }
    }
}

// MARK: - Preview

#Preview("InterestPicker · Light") {
    InterestPickerView(onComplete: {})
        .preferredColorScheme(.light)
}

#Preview("InterestPicker · Dark") {
    InterestPickerView(onComplete: {})
        .preferredColorScheme(.dark)
}
