//
//  DiscoverRepository.swift
//  ThrdSpaces — Features/Discover
//
//  The discovery read seam. Two conformers now share it: `MockDiscoverRepository`
//  (previews/tests) and `SupabaseDiscoverRepository` (the live RPC-backed
//  implementation, T13). Both return the canonical `NearbySpace`/`NearbyEvent`
//  DTOs from Models/ — the Phase-1 local mock entity types were deleted in T13
//  in favor of those.
//
//  Every method takes a `Geohash5`, never a raw coordinate or a `String` cell:
//  the user's location is snapped on-device before it can reach a repository, so
//  the location-coarsening boundary (D8) is enforced at compile time.
//

import Foundation

// MARK: - Repository

/// Sanctioned exception to "no protocol with one conformer": this seam has two
/// real implementations — `MockDiscoverRepository` for previews/tests and
/// `SupabaseDiscoverRepository` for the live PostGIS-backed RPCs — so the view
/// model can be driven by either without change (T14 flips the default to the
/// Supabase one once the UI handles live loading/empty/error states).
protocol DiscoverRepository {
    /// Spaces within `radiusMeters` of the snapped cell, nearest first.
    func nearbySpaces(near cell: Geohash5, radiusMeters: Int) async throws -> [NearbySpace]
    /// Published events starting within `horizonDays`, within `radiusMeters` of
    /// the snapped cell, ordered by distance then start time.
    func nearbyEvents(near cell: Geohash5, radiusMeters: Int, horizonDays: Int) async throws -> [NearbyEvent]

    // MARK: Detail reads (T15)

    /// Upcoming PUBLISHED events at a venue, soonest first (Space Detail). RLS
    /// (`events_select_published`) is the real gate; the query is explicit anyway.
    func events(atSpace spaceID: UUID) async throws -> [Event]
    /// First-name + avatar social proof for an event's `going` attendees
    /// (`attendee_previews` view — no handles, no ids). Empty for a private/
    /// unpublished event or one with no attendees.
    func attendeePreviews(eventID: UUID) async throws -> [AttendeePreview]
    /// A single user's public profile row, or nil when the id is private,
    /// deleted, or not found (Event Detail host section).
    func publicProfile(id: UUID) async throws -> PublicProfile?
    /// Public communities whose home venue is this space (Space Detail
    /// "communities that meet here"). RLS shows only `public` visibility.
    func communitiesMeetingAt(spaceID: UUID) async throws -> [Community]

    // MARK: Own tickets (T17)

    /// The caller's own GOING/WAITLIST tickets. Powers the Event Detail CTA's
    /// initial state and the Discover "your spot" badges. Scoped to the caller
    /// (RLS `tickets_select_own_or_host` + an explicit `user_id` filter — the
    /// host clause of that policy must never leak other attendees' tickets in as
    /// "your spot"). Cancelled/checked-in tickets are excluded: a cancelled RSVP
    /// reads as "not going" so re-RSVP is offered.
    func ownActiveTickets() async throws -> [Ticket]
}

// MARK: - Mock

/// Static Bengaluru fixtures for previews and unit tests. Keeps the spirit of
/// the four Phase-1 venues, now shaped as the real `NearbySpace`/`NearbyEvent`
/// DTOs. Ignores the cell/radius/horizon — it always returns the same rows —
/// so it exercises the view layer without a backend.
struct MockDiscoverRepository: DiscoverRepository {

    // MARK: Test seams (previews/production use the defaults)

    /// When set, the four detail reads throw this — lets a test exercise the
    /// detail view models' error path (e.g. a non-leaking host-profile failure)
    /// without a second conforming type.
    var detailError: Error?
    /// When true, the collection detail reads (events/attendees/communities)
    /// return empty — drives the detail screens' empty states in tests/previews.
    /// `publicProfile` still resolves (a host always exists for an event).
    var returnsEmptyDetails = false

    /// The caller's own active tickets to return from `ownActiveTickets()` —
    /// default empty (no "your spot" badge / a fresh RSVP CTA). Tests seed this
    /// to exercise the Going/Waitlisted initial states.
    var ownTicketRows: [Ticket] = []

    /// A stable mock host so Event Detail can render a consistent public profile
    /// across previews and tests.
    static let mockHost = PublicProfile(
        id: UUID(uuidString: "5057E15A-0000-4000-8000-000000000001")!,
        handle: "priya_k", displayName: "Priya Kumar",
        avatarUrl: nil, interests: ["books", "coffee"])

    // Stored so the events below can reference a stable `spaceId`, mirroring how
    // a real query resolves venue identity via the space join.
    private let thirdWaveCoffee = NearbySpace(
        id: UUID(), ownerUserId: nil, name: "Third Wave Coffee, Indiranagar",
        category: .cafe, latitude: 12.9719, longitude: 77.6412,
        address: "100 Feet Rd, Indiranagar", photos: [], amenities: ["wifi", "outdoor"],
        hours: nil, capacity: 40, isPartner: true, ratingAgg: nil,
        createdAt: .now, distanceMeters: 5010, upcomingEventCount: 1)
    private let cubbonPark = NearbySpace(
        id: UUID(), ownerUserId: nil, name: "Cubbon Park Bandstand",
        category: .park, latitude: 12.9763, longitude: 77.5929,
        address: "Cubbon Park, Bengaluru", photos: [], amenities: [],
        hours: nil, capacity: nil, isPartner: false, ratingAgg: nil,
        createdAt: .now, distanceMeters: 620, upcomingEventCount: 1)
    private let attaGalatta = NearbySpace(
        id: UUID(), ownerUserId: nil, name: "Atta Galatta",
        category: .venue, latitude: 12.9346, longitude: 77.6139,
        address: "440, 1st Main Rd, Koramangala", photos: [], amenities: ["books"],
        hours: nil, capacity: 80, isPartner: true, ratingAgg: nil,
        createdAt: .now, distanceMeters: 4600, upcomingEventCount: 0)
    private let clayStation = NearbySpace(
        id: UUID(), ownerUserId: nil, name: "Clay Station Studio",
        category: .studio, latitude: 12.9583, longitude: 77.6408,
        address: "HSR Layout, Bengaluru", photos: [], amenities: ["kiln"],
        hours: nil, capacity: 12, isPartner: false, ratingAgg: nil,
        createdAt: .now, distanceMeters: 5240, upcomingEventCount: 1)

    func nearbySpaces(near cell: Geohash5, radiusMeters: Int) async throws -> [NearbySpace] {
        [cubbonPark, attaGalatta, thirdWaveCoffee, clayStation]
    }

    func nearbyEvents(near cell: Geohash5, radiusMeters: Int, horizonDays: Int) async throws -> [NearbyEvent] {
        [
            event(title: "Sunday Morning Run Club", at: cubbonPark,
                  inHours: 4, rsvpCount: 24, price: 0),
            event(title: "Silent Book Club", at: thirdWaveCoffee,
                  inHours: 28, rsvpCount: 12, price: 0),
            event(title: "Beginner Pottery Session", at: clayStation,
                  inHours: 50, rsvpCount: 8, price: 500),
        ]
    }

    /// Builds a `NearbyEvent` at a fixture space, carrying that space's
    /// denormalized venue name/coords — the shape the RPC returns.
    private func event(title: String, at space: NearbySpace,
                       inHours: Double, rsvpCount: Int, price: Int) -> NearbyEvent {
        let start = Date.now.addingTimeInterval(3600 * inHours)
        return NearbyEvent(
            id: UUID(), communityId: nil, hostId: UUID(), spaceId: space.id,
            title: title, description: nil, coverUrl: nil,
            startsAt: start, endsAt: start.addingTimeInterval(3600 * 2),
            recurrenceRule: nil, capacity: nil, price: price, status: .published,
            rsvpCount: rsvpCount, createdAt: .now, venueName: space.name,
            latitude: space.latitude, longitude: space.longitude,
            distanceMeters: space.distanceMeters)
    }

    // MARK: Detail reads (T15)

    func events(atSpace spaceID: UUID) async throws -> [Event] {
        if let detailError { throw detailError }
        guard !returnsEmptyDetails else { return [] }
        let start = Date.now.addingTimeInterval(3600 * 6)
        return [
            Event(id: UUID(uuidString: "E5E10000-0000-4000-8000-000000000001")!,
                  communityId: nil, hostId: Self.mockHost.id, spaceId: spaceID,
                  title: "Silent Book Club", description: "Bring a book, read together, then chat.",
                  coverUrl: nil, startsAt: start, endsAt: start.addingTimeInterval(7200),
                  recurrenceRule: nil, capacity: 40, price: 0, status: .published,
                  rsvpCount: 12, createdAt: .now),
            Event(id: UUID(uuidString: "E5E10000-0000-4000-8000-000000000002")!,
                  communityId: nil, hostId: Self.mockHost.id, spaceId: spaceID,
                  title: "Latte Art Workshop", description: "Hands-on with a barista.",
                  coverUrl: nil, startsAt: start.addingTimeInterval(86_400),
                  endsAt: start.addingTimeInterval(86_400 + 5400),
                  recurrenceRule: nil, capacity: 12, price: 50000, status: .published,
                  rsvpCount: 5, createdAt: .now),
        ]
    }

    func attendeePreviews(eventID: UUID) async throws -> [AttendeePreview] {
        if let detailError { throw detailError }
        guard !returnsEmptyDetails else { return [] }
        // First names only — mirrors the view's `split_part(display_name,' ',1)`.
        return ["Arjun", "Meera", "Dev", "Sana"].map {
            AttendeePreview(eventId: eventID, firstName: $0, avatarUrl: nil)
        }
    }

    func publicProfile(id: UUID) async throws -> PublicProfile? {
        if let detailError { throw detailError }
        return Self.mockHost
    }

    func communitiesMeetingAt(spaceID: UUID) async throws -> [Community] {
        if let detailError { throw detailError }
        guard !returnsEmptyDetails else { return [] }
        return [
            Community(id: UUID(uuidString: "C0111100-0000-4000-8000-000000000001")!,
                      creatorId: Self.mockHost.id, name: "Bangalore Readers",
                      description: "Monthly book meetups.", coverUrl: nil,
                      interestTags: ["books"], visibility: .public, memberCount: 128,
                      homeSpaceId: spaceID, createdAt: .now),
            Community(id: UUID(uuidString: "C0111100-0000-4000-8000-000000000002")!,
                      creatorId: Self.mockHost.id, name: "Third Wave Regulars",
                      description: nil, coverUrl: nil,
                      interestTags: ["coffee"], visibility: .public, memberCount: 64,
                      homeSpaceId: spaceID, createdAt: .now),
        ]
    }

    func ownActiveTickets() async throws -> [Ticket] {
        if let detailError { throw detailError }
        return ownTicketRows
    }
}
