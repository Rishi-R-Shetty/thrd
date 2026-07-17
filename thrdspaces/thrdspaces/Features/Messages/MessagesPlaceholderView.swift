//
//  MessagesPlaceholderView.swift
//  thrdspaces
//
//  Placeholder for T1 shell — real Messages feature lands in a later phase task.
//

import SwiftUI

struct MessagesPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Messages")
                .font(.title2.weight(.semibold))
            Text("Coming soon")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Messages, coming soon")
    }
}

#Preview {
    MessagesPlaceholderView()
}
