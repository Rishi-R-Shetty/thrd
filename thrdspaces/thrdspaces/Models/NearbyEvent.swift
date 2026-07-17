//
//  NearbyEvent.swift
//  ThrdSpaces — Models
//
//  RPC DTO for `public.nearby_events(cell, radius_m, horizon)` (migration 0003,
//  T12). Fields mirror that function's `RETURNS TABLE` column list byte-for-byte
//  via snake_case CodingKeys (D10: canonical shapes live in Models/).
//
//  It is the `Event` columns plus the joined venue's `venue_name`/`latitude`/
//  `longitude` and the computed `distance_meters`. `latitude`/`longitude` are
//  NON-optional (the RPC always projects the venue's PostGIS point). `venueName`
//  is carried denormalized by the RPC, so consumers no longer need to resolve a
//  space name via `spaceId` client-side.
//
//  Decodable only — the sole Phase-2 write path touching events is `rsvp_event`
//  (T16), which never inserts an Event from the client. Reuses the canonical
//  `EventStatus` enum from Models/Event.swift; never redeclared (D10).
//

import Foundation

struct NearbyEvent: Identifiable, Decodable, Equatable {
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
    let venueName: String
    let latitude: Double
    let longitude: Double
    /// Great-circle distance from the query cell's origin to the venue,
    /// computed server-side via `ST_Distance` — always RPC-derived.
    let distanceMeters: Int

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
        case venueName = "venue_name"
        case latitude
        case longitude
        case distanceMeters = "distance_meters"
    }
}
