//
//  ThrdButton.swift
//  ThrdSpaces — primary/secondary action button
//

import SwiftUI

struct ThrdButton: View {
    enum Style { case primary, secondary }

    let title: String
    var style: Style = .primary
    var isLoading: Bool = false
    let action: () -> Void

    // Disabled state comes from the environment so callers use `.disabled(_:)`.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                // Keep label in the layout while loading so width doesn't jump.
                Text(title)
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .tint(foreground)
                }
            }
            .font(Theme.Typography.button)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 44) // min 44pt hit target
            .padding(.horizontal, Theme.Spacing.md)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .strokeBorder(Theme.terracotta, lineWidth: style == .secondary ? 1.5 : 0)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? Text("Loading") : Text(""))
        .accessibilityAddTraits(.isButton)
    }

    private var foreground: Color {
        style == .primary ? .white : Theme.terracotta
    }

    private var background: Color {
        style == .primary ? Theme.terracotta : Color.clear
    }
}

// MARK: - Previews

#Preview("ThrdButton · Light") {
    ButtonGallery()
        .preferredColorScheme(.light)
}

#Preview("ThrdButton · Dark") {
    ButtonGallery()
        .preferredColorScheme(.dark)
}

private struct ButtonGallery: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            ThrdButton(title: "Primary", style: .primary) {}
            ThrdButton(title: "Secondary", style: .secondary) {}
            ThrdButton(title: "Loading", style: .primary, isLoading: true) {}
            ThrdButton(title: "Disabled", style: .primary) {}
                .disabled(true)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cream)
    }
}
