//
//  thrdspacesApp.swift
//  thrdspaces
//
//  Created by Rishi Ravindra Shetty on 10/07/26.
//

import SwiftUI

@main
struct thrdspacesApp: App {
    // OnboardingRootView owns launch navigation: it refreshes the session,
    // re-ensures the profile row, and routes through
    // welcome → sign-in → age gate → EULA → interests → location → tab shell,
    // sending an already-onboarded user straight to RootTabView.
    var body: some Scene {
        WindowGroup {
            OnboardingRootView()
        }
    }
}
