//
//  ModelsTests.swift
//  thrdspacesTests
//
//  T11 byte-exactness enforcement for Models/ against
//  supabase/migrations/0001_initial_schema.sql. Two kinds of assertion:
//
//   1. Fixture decode per entity: a JSON object keyed by the migration's
//      snake_case COLUMN NAMES decodes with every field — including every
//      optional — populated to the fixture value. A wrong CodingKey on a
//      required field throws; on an optional field it would silently yield
//      nil, so every optional here is given a non-nil value and asserted
//      non-nil. That is the byte-exact CodingKey check (not eyeballed).
//
//   2. Enum parity: each enum's `allCases.map(\.rawValue)` is asserted equal
//      to the SQL enum label list copied VERBATIM from migration 0001. The
//      hardcoded arrays below ARE the source-of-truth mirror; order matters,
//      so this also pins the declaration order to the SQL order.
//
//  Dates decode with the PostgREST/Supabase ISO-8601 style: fractional
//  seconds tolerated but not required (a bare `Z` and a 6-digit-microsecond
//  offset both parse). The models themselves are decoder-agnostic; this
//  decoder mirrors what the Phase-2 repository (T13) will configure.
//

import XCTest
@testable import thrdspaces

final class ModelsTests: XCTestCase {

    // MARK: - PostgREST-style decoder

    /// Tolerates both `...Z`/`+00:00` (no fractional) and `...123456+00:00`
    /// (fractional microseconds): a single ISO8601DateFormatter can do one or
    /// the other, never both, so we try fractional first then fall back.
    private func makeDecoder() -> JSONDecoder {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = withFractional.date(from: string) ?? plain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not ISO-8601: \(string)"
            )
        }
        return decoder
    }

    /// Reference parse for expected date values in fixtures.
    private func iso(_ string: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)!
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try makeDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Date decoding: fractional tolerated, not required

    func testDateDecodingToleratesFractionalAndBareZ() throws {
        struct Wrapper: Decodable { let t: Date }

        let fractional = try decode(Wrapper.self, #"{"t":"2026-01-15T10:30:00.500000+00:00"}"#)
        XCTAssertEqual(fractional.t.timeIntervalSince1970, 1_768_473_000.5, accuracy: 0.0001,
                       "6-digit microsecond fractional seconds must survive decoding")

        let bareZ = try decode(Wrapper.self, #"{"t":"2026-01-15T10:30:00Z"}"#)
        XCTAssertEqual(bareZ.t.timeIntervalSince1970, 1_768_473_000.0, accuracy: 0.0001,
                       "a bare Z with no fractional seconds must also decode")
    }

    // MARK: - Space (RPC-sourced lat/lng populated)

    func testSpaceDecodesEveryField() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "owner_user_id": "22222222-2222-2222-2222-222222222222",
          "name": "Third Wave Coffee",
          "category": "cafe",
          "latitude": 12.9719,
          "longitude": 77.6412,
          "address": "100 Feet Rd, Indiranagar",
          "photos": ["a.jpg", "b.jpg"],
          "amenities": ["wifi", "outdoor"],
          "hours": {"mon": "9-5", "open": true},
          "capacity": 40,
          "is_partner": true,
          "rating_agg": 4.5,
          "created_at": "2026-01-15T10:30:00+00:00"
        }
        """#
        let space = try decode(Space.self, json)

        XCTAssertEqual(space.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(space.ownerUserId, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(space.name, "Third Wave Coffee")
        XCTAssertEqual(space.category, .cafe)
        XCTAssertEqual(space.latitude, 12.9719)
        XCTAssertEqual(space.longitude, 77.6412)
        XCTAssertEqual(space.address, "100 Feet Rd, Indiranagar")
        XCTAssertEqual(space.photos, ["a.jpg", "b.jpg"])
        XCTAssertEqual(space.amenities, ["wifi", "outdoor"])
        XCTAssertEqual(space.hours, .object(["mon": .string("9-5"), "open": .bool(true)]))
        XCTAssertEqual(space.capacity, 40)
        XCTAssertTrue(space.isPartner)
        XCTAssertEqual(space.ratingAgg, Decimal(string: "4.5"))
        XCTAssertEqual(space.createdAt, iso("2026-01-15T10:30:00+00:00"))
    }

    /// Raw-row fetches (no RPC) omit latitude/longitude — they must decode to
    /// nil, never fail. Confirms the pre-decided optional modeling (they are
    /// non-optional on the DTO path, absent on raw rows).
    func testSpaceWithoutCoordinatesDecodesToNil() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "owner_user_id": null,
          "name": "Unclaimed Venue",
          "category": "venue",
          "address": "MG Road",
          "photos": [],
          "amenities": [],
          "hours": null,
          "capacity": null,
          "is_partner": false,
          "rating_agg": null,
          "created_at": "2026-01-15T10:30:00+00:00"
        }
        """#
        let space = try decode(Space.self, json)
        XCTAssertNil(space.latitude)
        XCTAssertNil(space.longitude)
        XCTAssertNil(space.ownerUserId)
        XCTAssertNil(space.hours)
        XCTAssertNil(space.capacity)
        XCTAssertNil(space.ratingAgg)
    }

    // MARK: - Event

    func testEventDecodesEveryField() throws {
        let json = #"""
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "community_id": "44444444-4444-4444-4444-444444444444",
          "host_id": "55555555-5555-5555-5555-555555555555",
          "space_id": "66666666-6666-6666-6666-666666666666",
          "title": "Sunday Run Club",
          "description": "Easy 5k",
          "cover_url": "https://example.com/c.jpg",
          "starts_at": "2026-02-01T02:30:00+00:00",
          "ends_at": "2026-02-01T04:00:00+00:00",
          "recurrence_rule": "FREQ=WEEKLY",
          "capacity": 30,
          "price": 500,
          "status": "published",
          "rsvp_count": 24,
          "created_at": "2026-01-15T10:30:00+00:00"
        }
        """#
        let event = try decode(Event.self, json)

        XCTAssertEqual(event.id, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        XCTAssertEqual(event.communityId, UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        XCTAssertEqual(event.hostId, UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        XCTAssertEqual(event.spaceId, UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        XCTAssertEqual(event.title, "Sunday Run Club")
        XCTAssertEqual(event.description, "Easy 5k")
        XCTAssertEqual(event.coverUrl, "https://example.com/c.jpg")
        XCTAssertEqual(event.startsAt, iso("2026-02-01T02:30:00+00:00"))
        XCTAssertEqual(event.endsAt, iso("2026-02-01T04:00:00+00:00"))
        XCTAssertEqual(event.recurrenceRule, "FREQ=WEEKLY")
        XCTAssertEqual(event.capacity, 30)
        XCTAssertEqual(event.price, 500)
        XCTAssertEqual(event.status, .published)
        XCTAssertEqual(event.rsvpCount, 24)
        XCTAssertEqual(event.createdAt, iso("2026-01-15T10:30:00+00:00"))
    }

    // MARK: - Community

    func testCommunityDecodesEveryField() throws {
        let json = #"""
        {
          "id": "77777777-7777-7777-7777-777777777777",
          "creator_id": "88888888-8888-8888-8888-888888888888",
          "name": "Indiranagar Runners",
          "description": "We run.",
          "cover_url": "https://example.com/cover.jpg",
          "interest_tags": ["running", "wellness"],
          "visibility": "public",
          "member_count": 128,
          "home_space_id": "99999999-9999-9999-9999-999999999999",
          "created_at": "2026-01-15T10:30:00+00:00"
        }
        """#
        let community = try decode(Community.self, json)

        XCTAssertEqual(community.id, UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        XCTAssertEqual(community.creatorId, UUID(uuidString: "88888888-8888-8888-8888-888888888888"))
        XCTAssertEqual(community.name, "Indiranagar Runners")
        XCTAssertEqual(community.description, "We run.")
        XCTAssertEqual(community.coverUrl, "https://example.com/cover.jpg")
        XCTAssertEqual(community.interestTags, ["running", "wellness"])
        XCTAssertEqual(community.visibility, .public)
        XCTAssertEqual(community.memberCount, 128)
        XCTAssertEqual(community.homeSpaceId, UUID(uuidString: "99999999-9999-9999-9999-999999999999"))
        XCTAssertEqual(community.createdAt, iso("2026-01-15T10:30:00+00:00"))
    }

    // MARK: - CommunityMembership (composite PK, no synthetic id)

    func testCommunityMembershipDecodesEveryField() throws {
        let json = #"""
        {
          "community_id": "77777777-7777-7777-7777-777777777777",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "role": "moderator",
          "tier": "regular",
          "joined_at": "2026-01-10T08:00:00+00:00",
          "events_attended_count": 7
        }
        """#
        let membership = try decode(CommunityMembership.self, json)

        XCTAssertEqual(membership.communityId, UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        XCTAssertEqual(membership.userId, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(membership.role, .moderator)
        XCTAssertEqual(membership.tier, .regular)
        XCTAssertEqual(membership.joinedAt, iso("2026-01-10T08:00:00+00:00"))
        XCTAssertEqual(membership.eventsAttendedCount, 7)
    }

    // MARK: - Ticket

    func testTicketDecodesEveryField() throws {
        let json = #"""
        {
          "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
          "event_id": "33333333-3333-3333-3333-333333333333",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "type": "paid",
          "status": "checked_in",
          "qr_code_token": "signed.jwt.token",
          "purchased_at": "2026-01-20T12:00:00+00:00",
          "checked_in_at": "2026-02-01T02:35:00+00:00"
        }
        """#
        let ticket = try decode(Ticket.self, json)

        XCTAssertEqual(ticket.id, UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        XCTAssertEqual(ticket.eventId, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        XCTAssertEqual(ticket.userId, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(ticket.type, .paid)
        XCTAssertEqual(ticket.status, .checkedIn)
        XCTAssertEqual(ticket.qrCodeToken, "signed.jwt.token")
        XCTAssertEqual(ticket.purchasedAt, iso("2026-01-20T12:00:00+00:00"))
        XCTAssertEqual(ticket.checkedInAt, iso("2026-02-01T02:35:00+00:00"))
    }

    // MARK: - Report

    func testReportDecodesEveryField() throws {
        let json = #"""
        {
          "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
          "reporter_id": "22222222-2222-2222-2222-222222222222",
          "subject_type": "event",
          "subject_id": "33333333-3333-3333-3333-333333333333",
          "reason": "safety",
          "detail": "felt unsafe",
          "status": "reviewed",
          "created_at": "2026-01-21T09:15:00+00:00"
        }
        """#
        let report = try decode(Report.self, json)

        XCTAssertEqual(report.id, UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        XCTAssertEqual(report.reporterId, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(report.subjectType, .event)
        XCTAssertEqual(report.subjectId, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        XCTAssertEqual(report.reason, .safety)
        XCTAssertEqual(report.detail, "felt unsafe")
        XCTAssertEqual(report.status, .reviewed)
        XCTAssertEqual(report.createdAt, iso("2026-01-21T09:15:00+00:00"))
    }

    // MARK: - JSONValue (all cases)

    func testJSONValueDecodesEveryCase() throws {
        struct Wrapper: Decodable { let v: JSONValue }

        XCTAssertEqual(try decode(Wrapper.self, #"{"v":"hi"}"#).v, .string("hi"))
        XCTAssertEqual(try decode(Wrapper.self, #"{"v":3.5}"#).v, .number(3.5))
        XCTAssertEqual(try decode(Wrapper.self, #"{"v":true}"#).v, .bool(true))
        XCTAssertEqual(try decode(Wrapper.self, #"{"v":null}"#).v, .null)
        XCTAssertEqual(try decode(Wrapper.self, #"{"v":[1,"a",false]}"#).v,
                       .array([.number(1), .string("a"), .bool(false)]))
        XCTAssertEqual(try decode(Wrapper.self, #"{"v":{"k":"val","n":2}}"#).v,
                       .object(["k": .string("val"), "n": .number(2)]))
    }

    // MARK: - Enum parity: allCases raw values == verbatim SQL enum labels
    //
    // Right-hand arrays copied verbatim from migration 0001. Order-sensitive:
    // also pins Swift declaration order to SQL order.

    func testSpaceCategoryMatchesSQL() {
        // create type public.space_category as enum ('cafe','park','studio','venue','other');
        XCTAssertEqual(SpaceCategory.allCases.map(\.rawValue),
                       ["cafe", "park", "studio", "venue", "other"])
    }

    func testCommunityVisibilityMatchesSQL() {
        // create type public.community_visibility as enum ('public','approval','private');
        XCTAssertEqual(CommunityVisibility.allCases.map(\.rawValue),
                       ["public", "approval", "private"])
    }

    func testMembershipRoleMatchesSQL() {
        // create type public.membership_role as enum ('member','moderator','host');
        XCTAssertEqual(MembershipRole.allCases.map(\.rawValue),
                       ["member", "moderator", "host"])
    }

    func testMembershipTierMatchesSQL() {
        // create type public.membership_tier as enum ('newcomer','regular','core');
        XCTAssertEqual(MembershipTier.allCases.map(\.rawValue),
                       ["newcomer", "regular", "core"])
    }

    func testEventStatusMatchesSQL() {
        // create type public.event_status as enum ('draft','published','cancelled','completed');
        XCTAssertEqual(EventStatus.allCases.map(\.rawValue),
                       ["draft", "published", "cancelled", "completed"])
    }

    func testTicketTypeMatchesSQL() {
        // create type public.ticket_type as enum ('rsvp','paid');
        XCTAssertEqual(TicketType.allCases.map(\.rawValue),
                       ["rsvp", "paid"])
    }

    func testTicketStatusMatchesSQL() {
        // create type public.ticket_status as enum ('going','waitlist','checked_in','cancelled');
        XCTAssertEqual(TicketStatus.allCases.map(\.rawValue),
                       ["going", "waitlist", "checked_in", "cancelled"])
    }

    func testReportSubjectMatchesSQL() {
        // create type public.report_subject as enum ('user','event','community','message');
        XCTAssertEqual(ReportSubject.allCases.map(\.rawValue),
                       ["user", "event", "community", "message"])
    }

    func testReportReasonMatchesSQL() {
        // create type public.report_reason as enum ('safety','harassment','spam','other');
        XCTAssertEqual(ReportReason.allCases.map(\.rawValue),
                       ["safety", "harassment", "spam", "other"])
    }

    func testReportStatusMatchesSQL() {
        // create type public.report_status as enum ('open','reviewed','actioned');
        XCTAssertEqual(ReportStatus.allCases.map(\.rawValue),
                       ["open", "reviewed", "actioned"])
    }
}
