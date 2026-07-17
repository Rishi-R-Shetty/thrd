//
//  Space.swift
//  ThrdSpaces — Models
//
//  Mirrors `public.spaces` (migration 0001) byte-for-byte via snake_case
//  CodingKeys. Decodable only — no Phase 1/2 client write path exists for
//  spaces (the seed pipeline, T20, writes with the service-role key, never
//  through this type; creation UI is Phase 3+), so there is no Encodable
//  conformance to maintain here.
//
//  The PostGIS `location` column is NEVER decoded client-side (threat-model:
//  raw coordinates are a trust-boundary concern, not a plain column read —
//  see docs/security/threat-model.md). Phase 2's `nearby_spaces`/
//  `nearby_events` RPCs (T12) instead project `latitude`/`longitude` as plain
//  doubles onto the rows they return, which is why those two fields are
//  modeled here even though they are not real `spaces` columns. They are
//  optional — not a second "RPC-only" Space type — because every Phase 2
//  read path is RPC-sourced and always populates them; a hypothetical future
//  decode path that skips the RPC is the only way to see nil.
//

import Foundation

enum SpaceCategory: String, Decodable, CaseIterable {
    case cafe, park, studio, venue, other
}

struct Space: Identifiable, Decodable, Equatable {
    let id: UUID
    let ownerUserId: UUID?
    let name: String
    let category: SpaceCategory
    /// RPC-sourced only — see file header doc comment.
    let latitude: Double?
    let longitude: Double?
    let address: String
    let photos: [String]
    let amenities: [String]
    let hours: JSONValue?
    let capacity: Int?
    let isPartner: Bool
    let ratingAgg: Decimal?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case ownerUserId = "owner_user_id"
        case name
        case category
        case latitude
        case longitude
        case address
        case photos
        case amenities
        case hours
        case capacity
        case isPartner = "is_partner"
        case ratingAgg = "rating_agg"
        case createdAt = "created_at"
    }
}
