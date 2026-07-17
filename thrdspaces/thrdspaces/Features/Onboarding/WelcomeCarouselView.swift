//
//  WelcomeCarouselView.swift
//  ThrdSpaces — Features/Onboarding
//
//  Three intro screens (third-space idea → communities → safety), skippable at
//  any point. Uses the native paged TabView rather than a hand-rolled pager so
//  the page dots, swipe gestures, and VoiceOver page navigation come for free.
//

import SwiftUI

struct WelcomeCarouselView: View {
    /// Fired when the user finishes the last page or taps Skip.
    var onGetStarted: () -> Void

    @State private var page = 0

    private struct Slide: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let body: String
    }

    private let slides = [
        Slide(symbol: "mappin.and.ellipse",
              title: "Your third space",
              body: "Beyond home and work — the cafes, parks, and studios where people actually meet."),
        Slide(symbol: "person.3.fill",
              title: "Find your people",
              body: "Join book clubs, run crews, chess nights, and more happening in the places near you."),
        Slide(symbol: "checkmark.shield.fill",
              title: "Built to feel safe",
              body: "Real, identity-tied profiles. Block and report anyone. You're always in control of who sees you."),
    ]

    private var isLastPage: Bool { page == slides.count - 1 }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            skipBar

            TabView(selection: $page) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                    slideView(slide)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            ThrdButton(title: isLastPage ? "Get started" : "Next") {
                if isLastPage {
                    onGetStarted()
                } else {
                    // Native paged animation between slides.
                    withAnimation { page += 1 }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.lg)
        }
        .background(Theme.cream.ignoresSafeArea())
    }

    // MARK: - Skip

    private var skipBar: some View {
        HStack {
            Spacer()
            Button("Skip", action: onGetStarted)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.terracotta)
                .padding(Theme.Spacing.md)
                .accessibilityLabel("Skip introduction")
                .accessibilityHint("Goes straight to sign in")
        }
    }

    // MARK: - Slide

    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: slide.symbol)
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(Theme.terracotta)
                .accessibilityHidden(true)
            Text(slide.title)
                .font(Theme.Typography.largeTitle)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(slide.body)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One combined element per slide so VoiceOver reads title + body and
        // page-swipes navigate between slides.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slide.title). \(slide.body)")
    }
}

// MARK: - Preview

#Preview("Welcome · Light") {
    WelcomeCarouselView(onGetStarted: {})
        .preferredColorScheme(.light)
}

#Preview("Welcome · Dark") {
    WelcomeCarouselView(onGetStarted: {})
        .preferredColorScheme(.dark)
}
