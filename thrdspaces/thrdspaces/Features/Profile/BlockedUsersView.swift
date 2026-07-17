//
//  BlockedUsersView.swift
//  ThrdSpaces — Features/Profile
//
//  Lists the users the caller has blocked (own `blocks` rows joined to
//  `public_profiles`). Unblock goes through `manage_block` — the only write path
//  to `blocks` (D4); the body carries only the target id, never `blocker_id`.
//  Each row also exposes the ⋯ Report menu, which is where Phase 1 exercises the
//  reusable report sheet on a real other-user profile context.
//

import SwiftUI
import Combine

struct BlockedUsersView: View {
    @StateObject private var viewModel = BlockedUsersViewModel()
    @State private var reportTarget: ProfileSummary?

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView().accessibilityLabel("Loading blocked users")
            case let .loaded(profiles) where profiles.isEmpty:
                emptyState
            case let .loaded(profiles):
                list(profiles)
            case let .failed(message):
                failure(message)
            }
        }
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.cream.ignoresSafeArea())
        .task { await viewModel.load() }
        .sheet(item: $reportTarget) { target in
            ReportSheetView(subjectID: target.id, subjectName: "@\(target.handle)")
        }
        .alert("Couldn't update", isPresented: Binding(
            get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private func list(_ profiles: [ProfileSummary]) -> some View {
        List(profiles) { profile in
            HStack(spacing: Theme.Spacing.sm) {
                InitialsAvatar(profile: profile, diameter: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.ink)
                    Text("@\(profile.handle)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button {
                        reportTarget = profile
                    } label: {
                        Label("Report", systemImage: "flag")
                    }
                    Button {
                        Task { await viewModel.unblock(profile.id) }
                    } label: {
                        Label("Unblock", systemImage: "hand.raised.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Actions for \(profile.displayName)")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(profile.displayName), @\(profile.handle)")
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "hand.raised.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("You haven't blocked anyone.")
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You haven't blocked anyone.")
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ThrdButton(title: "Try again", style: .secondary) {
                Task { await viewModel.load() }
            }
            .fixedSize()
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - View model

@MainActor
final class BlockedUsersViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded([ProfileSummary])
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published var errorMessage: String?

    private let repository = ProfileRepository()
    private let functions = EdgeFunctionClient()

    func load() async {
        state = .loading
        do {
            state = .loaded(try await repository.fetchBlockedProfiles())
        } catch {
            state = .failed(ProfileErrorCopy.message(for: error))
        }
    }

    /// Unblocks the user and drops them from the list on success. `manage_block`
    /// is idempotent, so a retry after a partial failure is safe.
    func unblock(_ userID: UUID) async {
        do {
            try await functions.unblock(userID: userID)
            if case let .loaded(profiles) = state {
                state = .loaded(profiles.filter { $0.id != userID })
            }
        } catch {
            errorMessage = ProfileErrorCopy.message(for: error)
        }
    }
}

// MARK: - Preview

#Preview("Blocked Users") {
    NavigationStack { BlockedUsersView() }
}
