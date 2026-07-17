//
//  Ticket.swift
//  ThrdSpaces — Models
//
//  Mirrors `public.tickets` (migration 0001) byte-for-byte via snake_case
//  CodingKeys. Decodable only for T11 — the `rsvp_event` Edge Function
//  (T16) is the Phase 2 write path, but it mutates rows through its own
//  request/response envelope (Artifact B), not a client-side Ticket insert,
//  so no Encodable conformance is needed on this type.
//

import Foundation

enum TicketType: String, Decodable, CaseIterable {
    case rsvp, paid
}

enum TicketStatus: String, Decodable, CaseIterable {
    case going
    case waitlist
    case checkedIn = "checked_in"
    case cancelled
}

struct Ticket: Identifiable, Decodable, Equatable {
    let id: UUID
    let eventId: UUID
    let userId: UUID
    let type: TicketType
    let status: TicketStatus
    let qrCodeToken: String?
    let purchasedAt: Date
    let checkedInAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case eventId = "event_id"
        case userId = "user_id"
        case type
        case status
        case qrCodeToken = "qr_code_token"
        case purchasedAt = "purchased_at"
        case checkedInAt = "checked_in_at"
    }
}
