//
//  Event.swift
//  ThrdSpaces — Models
//
//  Mirrors `public.events` (migration 0001) byte-for-byte via snake_case
//  CodingKeys. Decodable only — Phase 2's only client write path touching
//  this table is `rsvp_event` (T16), which mutates `tickets`/`rsvp_count`
//  through its own request/response contract (Artifact B), not a client-side
//  Event insert. Event creation is a Phase 3 host flow.
//

import Foundation

enum EventStatus: String, Decodable, CaseIterable {
    case draft, published, cancelled, completed
}

struct Event: Identifiable, Decodable, Equatable {
    let id: UUID
    let communityId: UUID?
    let hostId: UUID
    let spaceId: UUID
    let title: String
    let description: String?
    let coverUrl: String?
    let startsAt: Date
    let endsAt: Date
    let recurrenceRule: String?
    let capacity: Int?
    let price: Int
    let status: EventStatus
    let rsvpCount: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case communityId = "community_id"
        case hostId = "host_id"
        case spaceId = "space_id"
        case title
        case description
        case coverUrl = "cover_url"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case recurrenceRule = "recurrence_rule"
        case capacity
        case price
        case status
        case rsvpCount = "rsvp_count"
        case createdAt = "created_at"
    }
}
