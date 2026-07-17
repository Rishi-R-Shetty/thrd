//
//  CreatePlaceholderView.swift
//  thrdspaces
//
//  Placeholder for T1 shell — real Create flow lands in a later phase task.
//

import SwiftUI

struct CreatePlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Create")
                .font(.title2.weight(.semibold))
            Text("Coming soon")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Create, coming soon")
    }
}

#Preview {
    CreatePlaceholderView()
}
