//
//  OnboardingCoordinator.swift
//  ThrdSpaces — Features/Onboarding
//
//  Owns the onboarding state machine and app-launch navigation:
//
//    welcome → sign-in → age gate → EULA → interests → location → done
//
//  On launch it refreshes the persisted session (rotating an expired access
//  token) and re-ensures the user's profile row before any profile-dependent
//  write — the two hard requirements inherited from T5. A returning, already
//  onboarded user skips straight to the tab shell; a returning user who never
//  finished resumes at the age gate (they're already signed in).
//
//  "Onboarded" has no dedicated column in Phase 1 and none may be added, so it
//  is derived from the user's own `users.interests` (see `bootstrap`). This file
//  spells no Supabase types — all backend work goes through `AuthRepository`.
//

import SwiftUI
import Combine

@MainActor
final class OnboardingCoordinator: ObservableObject {

    enum Step: Equatable {
        case loading   // refreshing session / reading interests on launch
        case welcome   // intro carousel (signed-out only)
        case signIn
        case ageGate
        case eula
        case interests
        case location
        case done      // RootTabView
    }

    @Published private(set) var step: Step = .loading

    private let repository = AuthRepository()

    // MARK: - Launch bootstrap

    /// Runs once when onboarding appears. Refreshes the session on launch and
    /// re-ensures the profile row (both HARD requirements from T5), then routes:
    /// onboarded users straight to `.done`, everyone else into the post-auth
    /// chain. No session → start at `.welcome`.
    func bootstrap() async {
        step = .loading
        do {
            // Refresh-on-launch: rotates an expired access token before the first
            // authenticated call (closes T5's synchronous restore-session ponytail).
            let userID = try await repository.refreshedUserID()
            // Re-ensure the profile row before any profile-dependent write
            // (closes T5's ensure-only-in-sign-in ponytail).
            try await repository.ensureUserRow(userID: userID)

            let interests = try await repository.fetchOwnInterests()
            // ponytail: "onboarded" is derived as
            // interests.count >= InterestPickerViewModel.minimumSelection, read
            // from the user's own row — Phase 1 has no completion column and none
            // may be added. The interest picker guarantees ≥ 3 on completion, so
            // this is a faithful proxy. Upgrade path: add a dedicated
            // `users.onboarding_completed_at` column in a Phase 2 migration and
            // read that instead of inferring from interests.
            step = interests.count >= InterestPickerViewModel.minimumSelection ? .done : .ageGate
        } catch {
            // sessionMissing (or a refresh failure) → sign in from the top.
            step = .welcome
        }
    }

    // MARK: - Transitions (pure, synchronous — unit-tested)

    func completeWelcome()   { step = .signIn }
    func completeSignIn()    { step = .ageGate }
    func completeAgeGate()   { step = .eula }
    func completeEULA()      { step = .interests }
    func completeInterests() { step = .location }
    func completeLocation()  { step = .done }
    func resetToWelcome()    { step = .welcome }

    // MARK: - Post sign-in

    /// Called when SignInView reports a session. Re-ensures the profile row
    /// (hard requirement) before advancing to the age gate — best-effort, since
    /// a transient failure here shouldn't wedge onboarding and the interest
    /// write would surface any hard failure later.
    func handleSignedIn() async {
        do {
            let userID = try await repository.refreshedUserID()
            try await repository.ensureUserRow(userID: userID)
        } catch { /* proceed; see note above */ }
        completeSignIn()
    }
}

// MARK: - Root view

/// The onboarding host. Swaps the visible screen on `coordinator.step` and is
/// the app's root scene (see thrdspacesApp).
struct OnboardingRootView: View {
    @StateObject private var coordinator = OnboardingCoordinator()

    var body: some View {
        Group {
            switch coordinator.step {
            case .loading:
                ProgressView()
                    .accessibilityLabel("Loading")
            case .welcome:
                WelcomeCarouselView(onGetStarted: coordinator.completeWelcome)
            case .signIn:
                SignInView(onAuthenticated: { Task { await coordinator.handleSignedIn() } })
            case .ageGate:
                AgeGateView(onPassed: coordinator.completeAgeGate,
                            onBlockedSignOut: coordinator.resetToWelcome)
            case .eula:
                EULAView(onAccepted: coordinator.completeEULA)
            case .interests:
                InterestPickerView(onComplete: coordinator.completeInterests)
            case .location:
                LocationPrimerView(onComplete: coordinator.completeLocation)
            case .done:
                // Sign-out / confirmed account deletion in the Profile tab routes
                // back to the onboarding root (T7a).
                RootTabView(onSignOut: coordinator.resetToWelcome)
            }
        }
        .task { await coordinator.bootstrap() }
    }
}
