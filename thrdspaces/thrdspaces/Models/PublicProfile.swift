//
//  PublicProfile.swift
//  ThrdSpaces — Models
//
//  DTO for the `public.public_profiles` view (migration 0001) — the ONLY
//  cross-user read surface for a user (limited columns, definer semantics that
//  bypass `users` RLS by design; excludes private and deletion-grace accounts).
//  Columns are byte-exact to the view: id, handle, display_name, avatar_url,
//  interests (D10: canonical shapes live in Models/).
//
//  Distinct from `ProfileSummary` (Features/Profile), which is the UI-facing
//  value type that also carries an own-profile `bio`; this is the raw view row.
//  Decodable only — profile writes go through the users table (own row) or an
//  Edge Function, never this view.
//

import Foundation

struct PublicProfile: Identifiable, Decodable, Equatable {
    let id: UUID
    let handle: String
    let displayName: String
    /// Present in the view but NOT loaded as an image this phase (D2). Avatars
    /// render as initials derived from the display name / handle.
    let avatarUrl: String?
    let interests: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case handle
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case interests
    }
}
