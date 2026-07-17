//
//  CommunityMembership.swift
//  ThrdSpaces — Models
//
//  Mirrors `public.community_memberships` (migration 0001) byte-for-byte via
//  snake_case CodingKeys. Composite primary key (community_id, user_id) — no
//  synthetic `id` column exists, so this type is intentionally NOT
//  `Identifiable` (inventing an id would be adding a field the schema
//  doesn't have). Decodable only — no Phase 1/2 client write path; joining/
//  role changes are Phase 3.
//

import Foundation

enum MembershipRole: String, Decodable, CaseIterable {
    case member, moderator, host
}

enum MembershipTier: String, Decodable, CaseIterable {
    case newcomer, regular, core
}

struct CommunityMembership: Decodable, Equatable {
    let communityId: UUID
    let userId: UUID
    let role: MembershipRole
    let tier: MembershipTier
    let joinedAt: Date
    let eventsAttendedCount: Int

    enum CodingKeys: String, CodingKey {
        case communityId = "community_id"
        case userId = "user_id"
        case role
        case tier
        case joinedAt = "joined_at"
        case eventsAttendedCount = "events_attended_count"
    }
}
