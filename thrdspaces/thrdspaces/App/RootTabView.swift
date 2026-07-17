//
//  RootTabView.swift
//  thrdspaces
//
//  5-tab app shell. Design tokens land in T2 — plain SwiftUI for now.
//

import SwiftUI

struct RootTabView: View {
    /// Returns to the onboarding root after a sign-out or a confirmed account
    /// deletion from the Profile tab. Owned by OnboardingCoordinator (the only
    /// place that maps app state back to `.welcome`).
    var onSignOut: () -> Void = {}

    var body: some View {
        TabView {
            DiscoverView()
                .tabItem {
                    Label("Discover", systemImage: "map.fill")
                        .accessibilityLabel("Discover")
                }

            CommunitiesPlaceholderView()
                .tabItem {
                    Label("Communities", systemImage: "person.3.fill")
                        .accessibilityLabel("Communities")
                }

            CreatePlaceholderView()
                .tabItem {
                    Label("Create", systemImage: "plus.circle.fill")
                        .accessibilityLabel("Create")
                }

            MessagesPlaceholderView()
                .tabItem {
                    Label("Messages", systemImage: "message.fill")
                        .accessibilityLabel("Messages")
                }

            ProfileView(mode: .own, onSignOut: onSignOut)
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle.fill")
                        .accessibilityLabel("Profile")
                }
        }
    }
}

#Preview {
    RootTabView()
}
