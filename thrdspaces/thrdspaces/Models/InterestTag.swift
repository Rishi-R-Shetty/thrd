//
//  InterestTag.swift
//  ThrdSpaces — Models
//
//  The fixed Phase-1 interest list (PRD §3 / phase-1 data-shape contract).
//  There is NO `interest_tags` DB table in Phase 1: `id` is the slug written
//  verbatim into `users.interests` (a `text[]`). This list is therefore the
//  single source of truth for which slugs may ever be stored — the repository
//  validates every write against `InterestTag.all` before it touches the DB.
//

import Foundation

struct InterestTag: Identifiable, Hashable {
    /// The slug stored in `users.interests`. Must match the migration's
    /// expectations exactly (lowercase, `[a-z0-9_]`).
    let id: String
    let label: String
    let sfSymbol: String

    /// Exactly the 12 tags in the data-shape contract, in a stable display
    /// order. Any change here is a schema/contract change, not a UI tweak.
    static let all: [InterestTag] = [
        InterestTag(id: "books",       label: "Books",       sfSymbol: "book.fill"),
        InterestTag(id: "running",     label: "Running",     sfSymbol: "figure.run"),
        InterestTag(id: "chess",       label: "Chess",       sfSymbol: "checkerboard.rectangle"),
        InterestTag(id: "coffee",      label: "Coffee",      sfSymbol: "cup.and.saucer.fill"),
        InterestTag(id: "music",       label: "Music",       sfSymbol: "music.note"),
        InterestTag(id: "wellness",    label: "Wellness",    sfSymbol: "leaf.fill"),
        InterestTag(id: "art",         label: "Art",         sfSymbol: "paintpalette.fill"),
        InterestTag(id: "food",        label: "Food",        sfSymbol: "fork.knife"),
        InterestTag(id: "sport",       label: "Sport",       sfSymbol: "sportscourt.fill"),
        InterestTag(id: "tech",        label: "Tech",        sfSymbol: "laptopcomputer"),
        InterestTag(id: "language",    label: "Language",    sfSymbol: "character.bubble.fill"),
        InterestTag(id: "board_games", label: "Board Games", sfSymbol: "dice.fill"),
    ]
}
