//
//  Community.swift
//  ThrdSpaces — Models
//
//  Mirrors `public.communities` (migration 0001) byte-for-byte via
//  snake_case CodingKeys. Decodable only — creation and membership
//  management are Phase 3; Phase 2 only reads public communities (space/
//  event detail joins per the data-shape contract).
//

import Foundation

enum CommunityVisibility: String, Decodable, CaseIterable {
    case `public`, approval, `private`
}

struct Community: Identifiable, Decodable, Equatable {
    let id: UUID
    let creatorId: UUID
    let name: String
    let description: String?
    let coverUrl: String?
    let interestTags: [String]
    let visibility: CommunityVisibility
    let memberCount: Int
    let homeSpaceId: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case creatorId = "creator_id"
        case name
        case description
        case coverUrl = "cover_url"
        case interestTags = "interest_tags"
        case visibility
        case memberCount = "member_count"
        case homeSpaceId = "home_space_id"
        case createdAt = "created_at"
    }
}
