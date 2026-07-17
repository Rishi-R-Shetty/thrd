//
//  LocationPrimerView.swift
//  ThrdSpaces — Features/Onboarding
//
//  Value-first location primer. The system When-In-Use prompt is triggered ONLY
//  by the Allow button here — never automatically — so the user always sees why
//  we're asking first (App Store Guideline 5.1.5). "Not now" is a first-class
//  path: Discover degrades to a permission-off empty state (T9), so denial
//  never blocks onboarding.
//

import SwiftUI

struct LocationPrimerView: View {
    /// Fired after the user chooses Allow or Not now. Progression does not
    /// depend on the permission outcome.
    var onComplete: () -> Void

    // Owned solely to trigger the system prompt on demand. Constructing it does
    // NOT prompt — LocationManager only asks when `requestPermission()` is
    // called (verified in T8), which happens exclusively in `allowTapped`.
    @StateObject private var locationManager = LocationManager()

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            Image(systemName: "location.circle.fill")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(Theme.terracotta)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Find spaces within walking distance")
                    .font(Theme.Typography.largeTitle)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text("We use your approximate location to show cafes, events, and communities near you. Your exact location is never shared.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.md)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Find spaces within walking distance. We use your approximate location to show cafes, events, and communities near you. Your exact location is never shared.")

            Spacer()

            VStack(spacing: Theme.Spacing.sm) {
                ThrdButton(title: "Allow location") { allowTapped() }
                    .accessibilityHint("Shows the system location permission prompt")

                Button("Not now", action: onComplete)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.terracotta)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("Not now")
                    .accessibilityHint("Continues without sharing your location")
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cream.ignoresSafeArea())
    }

    private func allowTapped() {
        // The one and only place the system prompt is requested.
        locationManager.requestPermission()
        // Advance regardless of the user's choice — the prompt resolves over the
        // next screen and Discover handles every authorization state.
        onComplete()
    }
}

// MARK: - Preview

#Preview("LocationPrimer · Light") {
    LocationPrimerView(onComplete: {})
        .preferredColorScheme(.light)
}

#Preview("LocationPrimer · Dark") {
    LocationPrimerView(onComplete: {})
        .preferredColorScheme(.dark)
}
