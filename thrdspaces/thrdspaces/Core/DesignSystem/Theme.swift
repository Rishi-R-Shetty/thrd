//
//  Theme.swift
//  ThrdSpaces — shared design tokens
//
//  Single source of truth for color, typography, spacing, and radii.
//  Light-mode color values are seeded verbatim from the original embedded
//  Theme in DiscoverView so existing screens render identically. Dark-mode
//  variants are supplied via a UIKit dynamic provider — no asset catalog.
//

import SwiftUI
import UIKit

// MARK: - Dynamic color helper

extension Color {
    /// Builds a color that resolves to `light` or `dark` based on the active
    /// interface style. Asset-catalog-free so tokens stay in code.
    init(light: Color, dark: Color) {
        self = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

// MARK: - Design tokens

enum Theme {

    // MARK: Colors
    // Light values are the originals from DiscoverView's embedded Theme.

    /// Primary brand color / calls to action.
    /// Light value darkened from the original mock (0.85, 0.45, 0.32) per TD4:
    /// white-on-terracotta now clears WCAG AA 4.5:1 for normal text.
    static let terracotta = Color(
        light: Color(red: 0.78, green: 0.38, blue: 0.26),
        dark:  Color(red: 0.90, green: 0.53, blue: 0.41)
    )

    /// App background.
    static let cream = Color(
        light: Color(red: 0.98, green: 0.96, blue: 0.92),
        dark:  Color(red: 0.10, green: 0.10, blue: 0.11)
    )

    /// Accent / secondary emphasis.
    static let forest = Color(
        light: Color(red: 0.15, green: 0.32, blue: 0.25),
        dark:  Color(red: 0.45, green: 0.70, blue: 0.55)
    )

    /// Primary text.
    static let ink = Color(
        light: Color(red: 0.12, green: 0.12, blue: 0.14),
        dark:  Color(red: 0.96, green: 0.95, blue: 0.92)
    )

    /// Elevated card / control surface. White in light mode to match the
    /// original card look; a raised near-black in dark mode.
    static let surface = Color(
        light: .white,
        dark:  Color(red: 0.16, green: 0.16, blue: 0.18)
    )

    // MARK: Corner radii

    /// Kept for source compatibility with existing screens.
    static let cardRadius: CGFloat = Radius.card

    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let card: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: Spacing (4-pt scale)

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Typography
    // Semantic text styles so every token scales with Dynamic Type.

    enum Typography {
        static let largeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let title = Font.system(.title2, design: .rounded).weight(.bold)
        static let headline = Font.headline
        static let body = Font.body
        static let subheadline = Font.subheadline
        static let caption = Font.caption.weight(.medium)
        static let button = Font.system(.headline, design: .rounded).weight(.semibold)
    }
}

// MARK: - Token gallery preview

private struct ThemeGallery: View {
    private let colors: [(String, Color)] = [
        ("terracotta", Theme.terracotta),
        ("cream", Theme.cream),
        ("forest", Theme.forest),
        ("ink", Theme.ink),
        ("surface", Theme.surface),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Colors")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.ink)
                VStack(spacing: Theme.Spacing.xs) {
                    ForEach(colors, id: \.0) { name, color in
                        HStack(spacing: Theme.Spacing.sm) {
                            RoundedRectangle(cornerRadius: Theme.Radius.small)
                                .fill(color)
                                .frame(width: 56, height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.small)
                                        .strokeBorder(Theme.ink.opacity(0.1))
                                )
                            Text(name)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.ink)
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(name) color token")
                    }
                }

                Text("Typography")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Large title").font(Theme.Typography.largeTitle)
                    Text("Title").font(Theme.Typography.title)
                    Text("Headline").font(Theme.Typography.headline)
                    Text("Body").font(Theme.Typography.body)
                    Text("Subheadline").font(Theme.Typography.subheadline)
                    Text("Caption").font(Theme.Typography.caption)
                }
                .foregroundStyle(Theme.ink)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.cream)
    }
}

#Preview("Theme · Light") {
    ThemeGallery()
        .preferredColorScheme(.light)
}

#Preview("Theme · Dark") {
    ThemeGallery()
        .preferredColorScheme(.dark)
}
