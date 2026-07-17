//
//  ThrdCard.swift
//  ThrdSpaces — card container
//
//  Matches the mock's card look: surface fill, rounded corners, soft shadow.
//

import SwiftUI

struct ThrdCard<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.md
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }
}

// MARK: - Previews

#Preview("ThrdCard · Light") {
    CardGallery()
        .preferredColorScheme(.light)
}

#Preview("ThrdCard · Dark") {
    CardGallery()
        .preferredColorScheme(.dark)
}

private struct CardGallery: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            ThrdCard {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Silent Book Club")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.ink)
                    Text("Third Wave Coffee · in 4 hours")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(.secondary)
                    Text("12 going · Free")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.forest)
                }
            }
            ThrdCard {
                Text("A card wraps any content.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.ink)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cream)
    }
}
