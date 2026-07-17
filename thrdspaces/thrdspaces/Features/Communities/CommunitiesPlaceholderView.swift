//
//  CommunitiesPlaceholderView.swift
//  thrdspaces
//
//  Placeholder for T1 shell — real Communities feature lands in a later phase task.
//

import SwiftUI

struct CommunitiesPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Communities")
                .font(.title2.weight(.semibold))
            Text("Coming soon")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Communities, coming soon")
    }
}

#Preview {
    CommunitiesPlaceholderView()
}
