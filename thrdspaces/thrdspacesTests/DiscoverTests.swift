//
//  DiscoverTests.swift
//  thrdspacesTests
//
//  Discover unit coverage (pure logic — no live backend, no live CoreLocation):
//   • DiscoverViewModel treats denied/restricted location as an empty state
//     and never calls the repository in that state
//   • MockDiscoverRepository returns the NearbySpace/NearbyEvent DTO shapes
//     (T13), with every event's spaceId resolving to a space it also returned
//   • Own tickets (T17): load() populates the "your spot" map from
//     ownActiveTickets(), so ticketStatus(for:) reflects the caller's state
//     (T9's console-print toggle was replaced by the real RSVP call on Event
//     Detail — see RSVPTests for the CTA state machine)
//   • TD2/D6: the initial camera center and the load() fallback center both
//     resolve to the single source of truth — LaunchCity.nearest(to:)'s
//     terminal fallback (which replaced DiscoverViewModel.defaultCity)
//   • Geohash5 (T13, D8): the compile-time cell boundary rejects malformed
//     cells and snaps a coordinate to the same cell the server expects
//   • LaunchCity (T14, D6): nearest-city resolver for the two launch cities
//   • Ranking (T14): distance × interest-overlap scorer + rankedEvents ordering
//   • Filters (T14): Today / This Week / Free predicates + category chips
//

import CoreLocation
import XCTest
@testable import thrdspaces

final class DiscoverTests: XCTestCase {

    // MARK: - Location-denied empty state

    @MainActor
    func testDeniedLocationSkipsLoadAndStaysEmpty() async {
        let vm = DiscoverViewModel(repository: MockDiscoverRepository(),
                                   initialAuthorizationStatus: .denied)
        XCTAssertTrue(vm.isLocationDenied)

        await vm.load()

        XCTAssertTrue(vm.spaces.isEmpty, "denied state must not fetch spaces")
        XCTAssertTrue(vm.events.isEmpty, "denied state must not fetch events")
    }

    @MainActor
    func testRestrictedLocationAlsoCountsAsDenied() {
        let vm = DiscoverViewModel(repository: MockDiscoverRepository(),
                                   initialAuthorizationStatus: .restricted)
        XCTAssertTrue(vm.isLocationDenied)
    }

    @MainActor
    func testAuthorizedLocationLoadsMockData() async {
        let vm = DiscoverViewModel(repository: MockDiscoverRepository(),
                                   initialAuthorizationStatus: .authorizedWhenInUse)
        XCTAssertFalse(vm.isLocationDenied)

        await vm.load()

        XCTAssertFalse(vm.spaces.isEmpty)
        XCTAssertFalse(vm.events.isEmpty)
    }

    // MARK: - Repository returns mock DTOs shaped per Models/ (T13)

    func testMockRepositoryReturnsExpectedSpacesAndEvents() async throws {
        let repository = MockDiscoverRepository()
        let cell = try XCTUnwrap(Geohash5(cell: "tdr1v"), "Bengaluru fixture cell must be valid")

        let spaces = try await repository.nearbySpaces(near: cell, radiusMeters: 5000)
        let events = try await repository.nearbyEvents(near: cell, radiusMeters: 5000, horizonDays: 7)

        XCTAssertEqual(spaces.count, 4)
        XCTAssertEqual(events.count, 3)

        // Every event references a space nearbySpaces() also returned — the
        // RPC denormalizes the venue name, but spaceId is still the join key.
        let spaceIDs = Set(spaces.map(\.id))
        XCTAssertTrue(events.allSatisfy { spaceIDs.contains($0.spaceId) },
                      "every event must reference a space nearbySpaces() returned")

        // The denormalized venueName matches the referenced space's name.
        let nameByID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.name) })
        XCTAssertTrue(events.allSatisfy { nameByID[$0.spaceId] == $0.venueName },
                      "each event's venueName must match its space's name")

        // Distances are the RPC-computed field, never negative.
        XCTAssertTrue(spaces.allSatisfy { $0.distanceMeters >= 0 })
        // At least one free event (price == 0 means free, per migration).
        XCTAssertTrue(events.contains { $0.price == 0 })
    }

    // MARK: - Own tickets → "your spot" badges (T17)

    @MainActor
    func testLoadPopulatesYourSpotFromOwnTickets() async {
        // Seed the caller's own tickets keyed by fixed event ids; load() surfaces
        // them as the your-spot state for cards with those ids.
        let goingID = UUID()
        let waitlistID = UUID()
        var mock = MockDiscoverRepository()
        mock.ownTicketRows = [
            Ticket(id: UUID(), eventId: goingID, userId: UUID(), type: .rsvp,
                   status: .going, qrCodeToken: nil, purchasedAt: .now, checkedInAt: nil),
            Ticket(id: UUID(), eventId: waitlistID, userId: UUID(), type: .rsvp,
                   status: .waitlist, qrCodeToken: nil, purchasedAt: .now, checkedInAt: nil),
        ]
        let vm = DiscoverViewModel(repository: mock, initialAuthorizationStatus: .authorizedWhenInUse)

        await vm.load()

        XCTAssertEqual(vm.ticketStatus(for: makeEvent(id: goingID, distanceMeters: 0)), .going)
        XCTAssertEqual(vm.ticketStatus(for: makeEvent(id: waitlistID, distanceMeters: 0)), .waitlist)
        XCTAssertNil(vm.ticketStatus(for: makeEvent(id: UUID(), distanceMeters: 0)),
                     "an event the caller holds no ticket for shows no badge")
    }

    @MainActor
    func testLoadToleratesOwnTicketsFailureWithoutBlockingTheMap() async {
        // A tickets read failure must not blank the map — spaces/events still
        // load (they ignore detailError) and the your-spot map is simply empty.
        var mock = MockDiscoverRepository()
        mock.detailError = APIError.server(status: 500) // ownActiveTickets throws
        let vm = DiscoverViewModel(repository: mock, initialAuthorizationStatus: .authorizedWhenInUse)

        await vm.load()

        XCTAssertFalse(vm.spaces.isEmpty, "a tickets failure must not blank the spaces")
        XCTAssertFalse(vm.events.isEmpty, "a tickets failure must not blank the events")
        XCTAssertFalse(vm.loadError, "the tickets read is non-fatal to the screen")
        XCTAssertTrue(vm.ownTickets.isEmpty, "no badges when the tickets read fails")
    }

    // MARK: - TD2 / D6: one source of truth for the default coordinate

    @MainActor
    func testCenterResolvesToLaunchCityDefaultWithoutCoordinate() async {
        // No CoreLocation delegate callback ever fires in a unit test, so
        // coarseCoordinate stays nil throughout — both the initial center and
        // load()'s fallback center must resolve to the same source of truth,
        // now the two-city resolver's terminal fallback (LaunchCity.bengaluru,
        // == nearest(to: nil)). This is TD2's single-source invariant carried
        // onto the D6 LaunchCity, which replaced DiscoverViewModel.defaultCity.
        let fallback = LaunchCity.nearest(to: nil).center
        XCTAssertEqual(fallback.latitude, LaunchCity.bengaluru.center.latitude)

        let vm = DiscoverViewModel(repository: MockDiscoverRepository(),
                                   initialAuthorizationStatus: .authorizedWhenInUse)

        XCTAssertEqual(vm.centerCoordinate.latitude, fallback.latitude)
        XCTAssertEqual(vm.centerCoordinate.longitude, fallback.longitude)

        await vm.load()

        XCTAssertEqual(vm.centerCoordinate.latitude, fallback.latitude)
        XCTAssertEqual(vm.centerCoordinate.longitude, fallback.longitude)
    }

    // MARK: - Geohash5: the compile-time cell boundary (T13, D8)

    func testGeohash5AcceptsAValidFiveCharCell() {
        XCTAssertNotNil(Geohash5(cell: "tdr1v"), "a valid geohash-5 cell must be accepted")
        XCTAssertEqual(Geohash5(cell: "tdr1v")?.cell, "tdr1v")
    }

    func testGeohash5RejectsWrongLengthCells() {
        // The server (assert_geohash5, migration 0003) rejects anything that is
        // not exactly 5 chars with SQLSTATE 22023 — the client rejects it first.
        XCTAssertNil(Geohash5(cell: "tdr1"), "4-char cell is too coarse — rejected")
        XCTAssertNil(Geohash5(cell: "tdr1vf"), "6-char cell is too precise — rejected")
        XCTAssertNil(Geohash5(cell: ""), "empty string is not a cell")
    }

    func testGeohash5RejectsInvalidAlphabet() {
        // The geohash base-32 alphabet excludes a, i, l, o and is lowercase.
        XCTAssertNil(Geohash5(cell: "TDR1V"), "uppercase is outside the geohash alphabet")
        XCTAssertNil(Geohash5(cell: "tdria"), "'a' and 'i' are not geohash characters")
        XCTAssertNil(Geohash5(cell: "12.97"), "a raw-coordinate-looking string is not a cell")
    }

    @MainActor
    func testGeohash5SnapsBengaluruCenterToTdr1v() {
        // Snapping the Bengaluru center on-device must produce exactly the cell
        // the server (and the T12 hostile suite) expects for that city. The
        // coordinate is sourced from LaunchCity so the launch-city constant
        // lives in exactly one place (D6 / the grep-enforced single source).
        let center = LaunchCity.bengaluru.center
        let cell = Geohash5(latitude: center.latitude, longitude: center.longitude)
        XCTAssertEqual(cell.cell, "tdr1v")
    }

    // MARK: - LaunchCity: two-city resolver (T14, D6)

    func testNearestLaunchCityPicksBengaluruForBengaluruCoordinate() {
        // The city center itself, and a nearby Bengaluru coordinate, both resolve
        // to Bengaluru (not Mumbai ~840km away).
        XCTAssertEqual(LaunchCity.nearest(to: LaunchCity.bengaluru.center), .bengaluru)
        XCTAssertEqual(
            LaunchCity.nearest(to: CLLocationCoordinate2D(latitude: 13.02, longitude: 77.62)),
            .bengaluru)
    }

    func testNearestLaunchCityPicksMumbaiForMumbaiCoordinate() {
        XCTAssertEqual(LaunchCity.nearest(to: LaunchCity.mumbai.center), .mumbai)
        XCTAssertEqual(
            LaunchCity.nearest(to: CLLocationCoordinate2D(latitude: 19.10, longitude: 72.90)),
            .mumbai)
    }

    func testNearestLaunchCityFallsBackToBengaluruWhenIndeterminate() {
        // nil coordinate → terminal fallback (D6: coordinate → locale → Bengaluru;
        // the locale tier is a no-op while both cities share a country).
        XCTAssertEqual(LaunchCity.nearest(to: nil), .bengaluru)
    }

    func testLaunchCityGeohash5IsAValidCellAndBengaluruMatchesTdr1v() {
        // Each city's fallback query cell is a valid geohash-5 (5 chars), and
        // Bengaluru's is the same "tdr1v" cell the T12/T13 fixtures use.
        XCTAssertEqual(LaunchCity.bengaluru.geohash5.cell, "tdr1v")
        XCTAssertEqual(LaunchCity.mumbai.geohash5.cell.count, 5)
        XCTAssertNotEqual(LaunchCity.bengaluru.geohash5.cell, LaunchCity.mumbai.geohash5.cell)
    }

    // MARK: - Ranking scorer (T14)
    // Overlap is always 0 in Phase 2 (no tag source on the DTOs), but the scoring
    // function must still respond correctly to a nonzero overlap parameter so the
    // Phase 4 ranking upgrade is a drop-in. score = distance × (1 − 0.15·min(ov,3)).

    func testRankingScoreIsPureDistanceAtZeroOverlap() {
        XCTAssertEqual(DiscoverViewModel.rankingScore(distanceMeters: 1000, interestOverlap: 0),
                       1000, accuracy: 0.001)
    }

    func testRankingScoreDiscountsWithOverlapAndCapsAtThree() {
        // 3 shared tags shave 45% off the effective distance.
        XCTAssertEqual(DiscoverViewModel.rankingScore(distanceMeters: 1000, interestOverlap: 3),
                       550, accuracy: 0.001)
        // Overlap is capped at 3 — a 5th shared tag adds nothing.
        XCTAssertEqual(DiscoverViewModel.rankingScore(distanceMeters: 1000, interestOverlap: 5),
                       DiscoverViewModel.rankingScore(distanceMeters: 1000, interestOverlap: 3),
                       accuracy: 0.001)
        // Negative overlap is clamped to 0 (never inflates distance).
        XCTAssertEqual(DiscoverViewModel.rankingScore(distanceMeters: 1000, interestOverlap: -1),
                       1000, accuracy: 0.001)
    }

    func testFartherEventWithOverlapOutranksCloserEventWithoutOverlap() {
        // The PRD heuristic in action: a 1500m event sharing 3 tags scores below
        // (ranks above) a 1000m event sharing none — 1500·0.55 = 825 < 1000.
        let farWithOverlap = DiscoverViewModel.rankingScore(distanceMeters: 1500, interestOverlap: 3)
        let nearNoOverlap = DiscoverViewModel.rankingScore(distanceMeters: 1000, interestOverlap: 0)
        XCTAssertLessThan(farWithOverlap, nearNoOverlap)
    }

    // MARK: - rankedEvents: filtering + distance ordering (overlap currently 0)

    @MainActor
    func testRankedEventsOrdersByDistanceAscending() {
        let vm = DiscoverViewModel(repository: MockDiscoverRepository(),
                                   initialAuthorizationStatus: .authorizedWhenInUse)
        // Seed out of distance order; rankedEvents must reorder near → far.
        vm.events = [makeEvent(title: "Far", distanceMeters: 5000),
                     makeEvent(title: "Near", distanceMeters: 500),
                     makeEvent(title: "Mid", distanceMeters: 2000)]

        XCTAssertEqual(vm.rankedEvents.map(\.title), ["Near", "Mid", "Far"])
    }

    @MainActor
    func testRankedEventsAppliesFreeFilter() {
        let vm = DiscoverViewModel(repository: MockDiscoverRepository(),
                                   initialAuthorizationStatus: .authorizedWhenInUse)
        vm.events = [makeEvent(title: "Free", distanceMeters: 800, price: 0),
                     makeEvent(title: "Paid", distanceMeters: 400, price: 500)]
        vm.activeEventFilterIDs = ["free"]

        XCTAssertEqual(vm.rankedEvents.map(\.title), ["Free"], "only the free event survives the Free pill")
    }

    @MainActor
    func testFilteredSpacesAppliesCategoryChips() {
        let vm = DiscoverViewModel(repository: MockDiscoverRepository(),
                                   initialAuthorizationStatus: .authorizedWhenInUse)
        vm.spaces = [makeSpace(name: "Brew", category: .cafe),
                     makeSpace(name: "Green", category: .park)]

        XCTAssertEqual(Set(vm.filteredSpaces.map(\.name)), ["Brew", "Green"], "empty selection shows all")

        vm.selectedCategoryIDs = [SpaceCategory.cafe.rawValue]
        XCTAssertEqual(vm.filteredSpaces.map(\.name), ["Brew"], "cafe chip keeps only cafes")
    }

    // MARK: - EventFilter predicates (deterministic with an injected `now`)

    func testEventFilterTodayMatchesOnlySameDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let noonToday = calendar.startOfDay(for: now).addingTimeInterval(12 * 3600)

        let today = makeEvent(distanceMeters: 0, startsAt: noonToday)
        let inThreeDays = makeEvent(distanceMeters: 0, startsAt: noonToday.addingTimeInterval(3 * 86_400))

        XCTAssertTrue(EventFilter.today.matches(today, now: now, calendar: calendar))
        XCTAssertFalse(EventFilter.today.matches(inThreeDays, now: now, calendar: calendar))
    }

    func testEventFilterThisWeekMatchesWithinSevenDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let noonToday = calendar.startOfDay(for: now).addingTimeInterval(12 * 3600)

        let inThreeDays = makeEvent(distanceMeters: 0, startsAt: noonToday.addingTimeInterval(3 * 86_400))
        let inTenDays = makeEvent(distanceMeters: 0, startsAt: noonToday.addingTimeInterval(10 * 86_400))

        XCTAssertTrue(EventFilter.thisWeek.matches(inThreeDays, now: now, calendar: calendar))
        XCTAssertFalse(EventFilter.thisWeek.matches(inTenDays, now: now, calendar: calendar))
    }

    func testEventFilterFreeMatchesOnlyZeroPrice() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        XCTAssertTrue(EventFilter.free.matches(makeEvent(distanceMeters: 0, price: 0),
                                               now: now, calendar: calendar))
        XCTAssertFalse(EventFilter.free.matches(makeEvent(distanceMeters: 0, price: 500),
                                                now: now, calendar: calendar))
    }

    // MARK: - Space Detail view model (T15)

    @MainActor
    func testSpaceDetailLoadsCommunitiesAndEvents() async {
        let vm = SpaceDetailViewModel(space: makeSpace(name: "Third Wave", category: .cafe),
                                      repository: MockDiscoverRepository())
        await vm.load()

        XCTAssertFalse(vm.communities.isEmpty, "mock must return communities that meet here")
        XCTAssertFalse(vm.upcomingEvents.isEmpty, "mock must return upcoming events")
        XCTAssertFalse(vm.communitiesError)
        XCTAssertFalse(vm.eventsError)
        // Every returned event is published (Space Detail only shows published).
        XCTAssertTrue(vm.upcomingEvents.allSatisfy { $0.status == .published })
    }

    @MainActor
    func testSpaceDetailEmptyStates() async {
        var mock = MockDiscoverRepository()
        mock.returnsEmptyDetails = true
        let vm = SpaceDetailViewModel(space: makeSpace(name: "Quiet Park", category: .park),
                                      repository: mock)
        await vm.load()

        XCTAssertTrue(vm.communities.isEmpty)
        XCTAssertTrue(vm.upcomingEvents.isEmpty)
        XCTAssertFalse(vm.communitiesError, "an empty result is not an error")
        XCTAssertFalse(vm.eventsError, "an empty result is not an error")
    }

    @MainActor
    func testSpaceDetailLoadErrorSetsBothSectionFlags() async {
        var mock = MockDiscoverRepository()
        mock.detailError = APIError.server(status: 500)
        let vm = SpaceDetailViewModel(space: makeSpace(name: "Studio", category: .studio),
                                      repository: mock)
        await vm.load()

        XCTAssertTrue(vm.communitiesError)
        XCTAssertTrue(vm.eventsError)
        XCTAssertTrue(vm.communities.isEmpty)
        XCTAssertTrue(vm.upcomingEvents.isEmpty)
    }

    @MainActor
    func testSpaceDetailPartialFailureKeepsLoadedSection() async {
        // Events fail, communities succeed → the loaded communities must survive
        // (the pre-fix single-flag design masked them behind a retry state).
        let repo = PartialFailRepository(failEvents: true)
        let vm = SpaceDetailViewModel(space: makeSpace(name: "Third Wave", category: .cafe),
                                      repository: repo)
        await vm.load()

        XCTAssertFalse(vm.communities.isEmpty, "loaded communities must not be masked by the events failure")
        XCTAssertFalse(vm.communitiesError)
        XCTAssertTrue(vm.eventsError)
        XCTAssertTrue(vm.upcomingEvents.isEmpty)
    }

    @MainActor
    func testSpaceDetailSynthesizesNearbyEventFromVenue() async {
        let space = makeSpace(name: "Atta Galatta", category: .venue)
        let vm = SpaceDetailViewModel(space: space, repository: MockDiscoverRepository())
        await vm.load()
        let event = try! XCTUnwrap(vm.upcomingEvents.first)

        // The synthesized NearbyEvent must carry the venue's identity/coords so
        // Event Detail stays one shape regardless of entry point.
        let nearby = vm.nearbyEvent(for: event)
        XCTAssertEqual(nearby.venueName, space.name)
        XCTAssertEqual(nearby.latitude, space.latitude)
        XCTAssertEqual(nearby.longitude, space.longitude)
        XCTAssertEqual(nearby.distanceMeters, space.distanceMeters)
        XCTAssertEqual(nearby.id, event.id)
    }

    // MARK: - Event Detail view model (T15)

    @MainActor
    func testEventDetailLoadsHostAndAttendees() async {
        let vm = EventDetailViewModel(event: makeEvent(distanceMeters: 500),
                                      venueSpace: makeSpace(name: "Venue", category: .cafe),
                                      repository: MockDiscoverRepository())
        await vm.load()

        XCTAssertNotNil(vm.host, "host public profile must load")
        XCTAssertFalse(vm.attendeePreviews.isEmpty, "attendee previews must load")
        XCTAssertFalse(vm.hostError)
        XCTAssertFalse(vm.attendeesError)
        // Previews are first-name-only — never a space or a handle string.
        XCTAssertTrue(vm.attendeePreviews.allSatisfy { !$0.firstName.contains(" ") },
                      "attendee previews expose first name only")
    }

    @MainActor
    func testEventDetailOverflowGoingCount() async {
        // rsvpCount 10, four previews → "and 6 more going".
        let event = NearbyEvent(
            id: UUID(), communityId: nil, hostId: MockDiscoverRepository.mockHost.id,
            spaceId: UUID(), title: "Popular Event", description: nil, coverUrl: nil,
            startsAt: .now.addingTimeInterval(3600), endsAt: .now.addingTimeInterval(7200),
            recurrenceRule: nil, capacity: nil, price: 0, status: .published,
            rsvpCount: 10, createdAt: .now, venueName: "Venue",
            latitude: 12.97, longitude: 77.59, distanceMeters: 100)
        let vm = EventDetailViewModel(event: event, repository: MockDiscoverRepository())
        await vm.load()

        XCTAssertEqual(vm.attendeePreviews.count, 4)
        XCTAssertEqual(vm.overflowGoingCount, 6)
    }

    @MainActor
    func testEventDetailLoadErrorShowsNonLeakingMessage() async {
        var mock = MockDiscoverRepository()
        mock.detailError = APIError.server(status: 500)
        let vm = EventDetailViewModel(event: makeEvent(distanceMeters: 500), repository: mock)
        await vm.load()

        XCTAssertTrue(vm.hostError)
        XCTAssertTrue(vm.attendeesError)
        XCTAssertNil(vm.host)
        let message = try! XCTUnwrap(vm.attendeesErrorMessage)
        // The copy must not leak the backend status or any schema detail.
        XCTAssertFalse(message.contains("500"), "no server status in user-facing copy")
        XCTAssertEqual(message, "Something went wrong. Please try again.")
    }

    @MainActor
    func testEventDetailPartialFailureKeepsLoadedSection() async {
        // Host fails, attendees succeed → the loaded attendee strip must survive
        // (the pre-fix single-flag design masked it behind the host failure).
        let repo = PartialFailRepository(failHost: true)
        let vm = EventDetailViewModel(event: makeEvent(distanceMeters: 500), repository: repo)
        await vm.load()

        XCTAssertFalse(vm.attendeePreviews.isEmpty, "loaded attendees must not be masked by the host failure")
        XCTAssertFalse(vm.attendeesError)
        XCTAssertTrue(vm.hostError)
        XCTAssertNil(vm.host)
    }

    // MARK: - Fixture builders

    private func makeEvent(id: UUID = UUID(),
                           title: String = "Event",
                           distanceMeters: Int,
                           startsAt: Date = Date().addingTimeInterval(3600),
                           price: Int = 0) -> NearbyEvent {
        NearbyEvent(id: id, communityId: nil, hostId: UUID(), spaceId: UUID(),
                    title: title, description: nil, coverUrl: nil,
                    startsAt: startsAt, endsAt: startsAt.addingTimeInterval(7200),
                    recurrenceRule: nil, capacity: nil, price: price, status: .published,
                    rsvpCount: 0, createdAt: .now, venueName: "Venue",
                    latitude: 12.97, longitude: 77.59, distanceMeters: distanceMeters)
    }

    private func makeSpace(name: String, category: SpaceCategory) -> NearbySpace {
        NearbySpace(id: UUID(), ownerUserId: nil, name: name, category: category,
                    latitude: 12.97, longitude: 77.59, address: "Addr", photos: [], amenities: [],
                    hours: nil, capacity: nil, isPartner: false, ratingAgg: nil,
                    createdAt: .now, distanceMeters: 100, upcomingEventCount: 0)
    }
}

// MARK: - Partial-failure repository (T15.1)

/// Wraps `MockDiscoverRepository`, failing individual detail reads on demand so a
/// test can exercise the per-section error handling (one section loads while the
/// other throws). Delegates every non-failed method to the base mock.
private struct PartialFailRepository: DiscoverRepository {
    var base = MockDiscoverRepository()
    var failCommunities = false
    var failEvents = false
    var failHost = false
    var failAttendees = false

    func nearbySpaces(near cell: Geohash5, radiusMeters: Int) async throws -> [NearbySpace] {
        try await base.nearbySpaces(near: cell, radiusMeters: radiusMeters)
    }

    func nearbyEvents(near cell: Geohash5, radiusMeters: Int, horizonDays: Int) async throws -> [NearbyEvent] {
        try await base.nearbyEvents(near: cell, radiusMeters: radiusMeters, horizonDays: horizonDays)
    }

    func events(atSpace spaceID: UUID) async throws -> [Event] {
        if failEvents { throw APIError.server(status: 500) }
        return try await base.events(atSpace: spaceID)
    }

    func attendeePreviews(eventID: UUID) async throws -> [AttendeePreview] {
        if failAttendees { throw APIError.server(status: 500) }
        return try await base.attendeePreviews(eventID: eventID)
    }

    func publicProfile(id: UUID) async throws -> PublicProfile? {
        if failHost { throw APIError.server(status: 500) }
        return try await base.publicProfile(id: id)
    }

    func communitiesMeetingAt(spaceID: UUID) async throws -> [Community] {
        if failCommunities { throw APIError.server(status: 500) }
        return try await base.communitiesMeetingAt(spaceID: spaceID)
    }

    func ownActiveTickets() async throws -> [Ticket] {
        try await base.ownActiveTickets()
    }
}
