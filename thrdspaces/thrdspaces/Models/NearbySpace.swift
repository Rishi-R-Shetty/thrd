//
//  NearbySpace.swift
//  ThrdSpaces — Models
//
//  RPC DTO for `public.nearby_spaces(cell, radius_m)` (migration 0003, T12).
//  Fields mirror that function's `RETURNS TABLE` column list byte-for-byte via
//  snake_case CodingKeys — this is the source-of-truth contract for the
//  discovery read path (D10: canonical shapes live in Models/).
//
//  Unlike `Models/Space`, `latitude`/`longitude` are NON-optional here: the RPC
//  projects them from PostGIS unconditionally, so every row this DTO decodes
//  carries a coordinate. That non-optionality must not smear back into `Space`'s
//  optional handling (Space models raw-row fetches that omit the columns) — the
//  two types are deliberately distinct on this one field.
//
//  Decodable only — there is no client write path for spaces (the seed pipeline
//  writes with the service-role key, T20). Reuses the canonical `SpaceCategory`
//  enum from Models/Space.swift; never redeclared (D10).
//

import Foundation

struct NearbySpace: Identifiable, Decodable, Equatable {
    let id: UUID
    let ownerUserId: UUID?
    let name: String
    let category: SpaceCategory
    let latitude: Double
    let longitude: Double
    let address: String
    let photos: [String]
    let amenities: [String]
    let hours: JSONValue?
    let capacity: Int?
    let isPartner: Bool
    let ratingAgg: Decimal?
    let createdAt: Date
    /// Great-circle distance from the query cell's origin, computed server-side
    /// via `ST_Distance` — never an entity field, always RPC-derived.
    let distanceMeters: Int
    /// Count of this space's published, future events (RPC subquery).
    let upcomingEventCount: Int

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
        case distanceMeters = "distance_meters"
        case upcomingEventCount = "upcoming_event_count"
    }
}
