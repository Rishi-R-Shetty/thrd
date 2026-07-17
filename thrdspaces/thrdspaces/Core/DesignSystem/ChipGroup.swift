//
//  ChipGroup.swift
//  ThrdSpaces — multi-select chip grid
//
//  Binds to a Set<String> of selected ids. The T6 interest picker will feed
//  it InterestTag.id strings mapped into ChipItem — this component does not
//  know about any Models/ type.
//

import SwiftUI

/// A selectable chip: a stable id, a display label, and an optional SF Symbol.
struct ChipItem: Identifiable, Hashable {
    let id: String
    let label: String
    var systemImage: String? = nil
}

struct ChipGroup: View {
    let items: [ChipItem]
    @Binding var selection: Set<String>

    // Adaptive grid keeps chips flowing across rows without a custom Layout.
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.xs)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(items) { item in
                Chip(item: item, isSelected: selection.contains(item.id)) {
                    toggle(item.id)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}

private struct Chip: View {
    let item: ChipItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xxs) {
                if let symbol = item.systemImage {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                }
                Text(item.label)
                    .lineLimit(1)
            }
            .font(Theme.Typography.subheadline)
            .foregroundStyle(isSelected ? .white : Theme.ink)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: 44) // min 44pt hit target
            .frame(maxWidth: .infinity)
            .background(isSelected ? Theme.terracotta : Theme.surface,
                        in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.clear : Theme.ink.opacity(0.15),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Previews

#Preview("ChipGroup · Light") {
    ChipGroupPreview()
        .preferredColorScheme(.light)
}

#Preview("ChipGroup · Dark") {
    ChipGroupPreview()
        .preferredColorScheme(.dark)
}

private struct ChipGroupPreview: View {
    @State private var selection: Set<String> = ["music"]

    private let items = [
        ChipItem(id: "music", label: "Live Music", systemImage: "music.note"),
        ChipItem(id: "run", label: "Running", systemImage: "figure.run"),
        ChipItem(id: "books", label: "Book Clubs", systemImage: "book.fill"),
        ChipItem(id: "art", label: "Pottery", systemImage: "paintpalette.fill"),
        ChipItem(id: "coffee", label: "Coffee", systemImage: "cup.and.saucer.fill"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ChipGroup(items: items, selection: $selection)
            Text("Selected: \(selection.sorted().joined(separator: ", "))")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.cream)
    }
}
