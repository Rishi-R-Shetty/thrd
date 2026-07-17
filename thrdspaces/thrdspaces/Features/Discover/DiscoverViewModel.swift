//
//  DiscoverViewModel.swift
//  ThrdSpaces — Features/Discover
//
//  Owns the LocationManager observation for Discover. Never calls
//  requestPermission() — the onboarding primer (T6) owns that ask — and
//  never starts continuous updates itself; LocationManager already
//  starts/stops updates internally on authorization change (T8). This view
//  model only observes the coarse coordinate and authorization state T8
//  publishes and reacts to them.
//
//  T14 flipped the production default repository to the live
//  SupabaseDiscoverRepository (previews/tests still inject the mock), replaced
//  T9's single `defaultCity` constant with the two-city `LaunchCity` resolver
//  (D6), and added the list ranking + Today/This Week/Free/category filters.
//

import Combine
import CoreLocation
import MapKit
import SwiftUI

// MARK: - Discover pill filters

/// The Discover event pills. Multi-select and AND-combined (an event must match
/// every active filter). Pure predicates so the filter bar is unit-testable
/// against fixture dates/prices with an injected `now`.
enum EventFilter: String, CaseIterable, Identifiable {
    case today
    case thisWeek = "this_week"
    case free

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "Today"
        case .thisWeek: "This Week"
        case .free: "Free"
        }
    }

    func matches(_ event: NearbyEvent, now: Date, calendar: Calendar) -> Bool {
        switch self {
        case .today:
            return calendar.isDate(event.startsAt, inSameDayAs: now)
        case .thisWeek:
            // Rolling 7-day window from now. The RPC already excludes past
            // events and caps the horizon at 30 days; this narrows that fetched
            // window down to the coming week.
            guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: now) else { return true }
            return event.startsAt <= weekEnd
        case .free:
            return event.price == 0 // price is minor units; 0 == free (migration 0001)
        }
    }
}

// MARK: - View model

@MainActor
final class DiscoverViewModel: ObservableObject {

    private static let defaultSpan = MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)

    // ponytail: fixed 5km radius — none of the PRD pills (Today · This Week ·
    // Free · category) is a radius control, so radius stays constant until a
    // distance filter is designed. The server caps it at 10km regardless (D8).
    private static let defaultRadiusMeters = 5000
    // A wide fetch window that the Today / This Week pills narrow client-side;
    // the server caps the horizon at 30 days regardless (D8).
    private static let defaultHorizonDays = 30

    @Published var spaces: [NearbySpace] = []
    @Published var events: [NearbyEvent] = []
    @Published var selectedSpace: NearbySpace?
    @Published var isLoading = false
    /// True when the live load threw — the view shows a retryable error state
    /// instead of an empty map (which would misread as "nothing nearby").
    @Published private(set) var loadError = false

    /// Active event pills, by `EventFilter.id`. Stringly-typed so it binds
    /// straight to `ChipGroup` (which is `Set<String>`-based); `rankedEvents`
    /// reconstructs the typed filters. Empty = no event filter.
    @Published var activeEventFilterIDs: Set<String> = []
    /// Selected space categories, by `SpaceCategory.rawValue`. Empty = all.
    @Published var selectedCategoryIDs: Set<String> = []

    /// The coordinate driving the map camera — the single source of truth for
    /// the center (TD2). `region` is derived from it.
    @Published private(set) var centerCoordinate: CLLocationCoordinate2D
    /// The caller's own active ticket per event id (`going` / `waitlist`), read
    /// from the backend on `load()`. Drives the "your spot" badge on event cards.
    /// Read-only social proof of the caller's own state — the RSVP write itself
    /// lives on Event Detail (the CTA), never as an inline toggle here.
    @Published private(set) var ownTickets: [UUID: TicketStatus] = [:]
    @Published private var authorizationStatus: CLAuthorizationStatus

    private let repository: DiscoverRepository
    private let locationManager: LocationManager
    private var cancellables = Set<AnyCancellable>()

    /// The map region, derived from the single-source `centerCoordinate`.
    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: centerCoordinate, span: Self.defaultSpan)
    }

    /// Whether the map may show the blue user dot. Gated to authorized state so
    /// showing the dot can never coax the permission prompt from Discover.
    var showsUserLocation: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    /// Spaces after the category chips. Category is a Space attribute (events
    /// carry none), so the chips gate the map's markers; empty selection = all.
    var filteredSpaces: [NearbySpace] {
        guard !selectedCategoryIDs.isEmpty else { return spaces }
        return spaces.filter { selectedCategoryIDs.contains($0.category.rawValue) }
    }

    /// The list view's events: the active pills applied, then ranked.
    var rankedEvents: [NearbyEvent] {
        let now = Date()
        let calendar = Calendar.current
        let filters = activeEventFilterIDs.compactMap(EventFilter.init(rawValue:))
        return events
            .filter { event in filters.allSatisfy { $0.matches(event, now: now, calendar: calendar) } }
            .sorted { lhs, rhs in
                // ponytail: interestOverlap is 0 for every event (see
                // rankingScore) — the list is pure-distance-ordered in Phase 2.
                Self.rankingScore(distanceMeters: lhs.distanceMeters, interestOverlap: 0)
                    < Self.rankingScore(distanceMeters: rhs.distanceMeters, interestOverlap: 0)
            }
    }

    /// List-view ranking score — LOWER ranks higher (it is distance-derived).
    ///
    /// PRD heuristic: order by distance, discounted by how many of the item's
    /// interest tags the user shares, so a slightly-farther event the user is
    /// more likely to care about can rank above a closer one. Each shared tag
    /// (capped at 3) shaves 15% off the effective distance:
    ///
    ///     score = distanceMeters × (1 − 0.15 × min(overlap, 3))
    ///
    /// Kept a pure function so Phase 4 can replace the ranking wholesale (PRD:
    /// distance × similarity × social proof × host quality) and unit-test it.
    // ponytail: `interestOverlap` is ALWAYS 0 in Phase 2 — neither NearbySpace
    // nor NearbyEvent carries interest tags. The only tag source is an event's
    // community.interest_tags, which is not on the DTO or the nearby_events RPC,
    // so the list ranks by pure distance today. Phase 4 wires real overlap by
    // joining community tags into the RPC AND fetching users.interests
    // (AuthRepository.fetchOwnInterests) to intersect against — do NOT add a tag
    // field to the DTO to shortcut this.
    nonisolated static func rankingScore(distanceMeters: Int, interestOverlap: Int) -> Double {
        Double(distanceMeters) * (1.0 - 0.15 * Double(min(max(interestOverlap, 0), 3)))
    }

    /// True only once the system has actively denied or restricted location —
    /// the state Discover shows an empty state for instead of the map.
    /// `.notDetermined` is not treated as denied: the onboarding primer (T6)
    /// asks before Discover is ever reached, so by the time this view
    /// appears the answer is normally already settled either way.
    var isLocationDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// `initialAuthorizationStatus` is a test/preview seam only — it lets the
    /// denied empty state be simulated deterministically without depending
    /// on the simulator's live Settings state. Production call sites never
    /// pass it, so the view model falls back to whatever LocationManager
    /// actually reports.
    ///
    /// `repository`/`locationManager` default to `nil` and are constructed
    /// inside the initializer body rather than as default argument values —
    /// both `SupabaseDiscoverRepository()` and `LocationManager()` touch
    /// MainActor-isolated state, and default-argument expressions evaluate
    /// outside this initializer's actor isolation.
    init(repository: DiscoverRepository? = nil,
         locationManager: LocationManager? = nil,
         notificationCenter: NotificationCenter = .default,
         initialAuthorizationStatus: CLAuthorizationStatus? = nil) {
        let locationManager = locationManager ?? LocationManager()
        // T14 flip: the live repository is the production default now that this
        // view handles loading/empty/error states. Previews and tests keep
        // injecting MockDiscoverRepository. Both conform to DiscoverRepository.
        self.repository = repository ?? SupabaseDiscoverRepository()
        self.locationManager = locationManager
        self.authorizationStatus = initialAuthorizationStatus ?? locationManager.authorizationStatus

        // Resolve the initial map center from the two-city defaults (D6):
        // nearest launch city to whatever coarse coordinate we already have (nil
        // before the first fix → the terminal fallback, Bengaluru).
        self.centerCoordinate = LaunchCity.nearest(to: locationManager.coarseCoordinate).center

        // Block invalidation (T18): after ANY successful block the server already
        // excludes the blocked user bidirectionally (migration 0005), so a
        // re-fetch drops their events/spaces. Re-run load() on the signal so a
        // blocked host's card can't linger from a pre-block fetch when the user
        // pops back to Discover. Wired before the seam guard so it is always
        // active — block safety must not depend on the live-location path.
        // ponytail: reloads the whole nearby set on any block — trivial at
        // Phase 2 fetch sizes; a targeted single-row drop is the upgrade if the
        // reload cost ever shows up in profiling.
        notificationCenter.publisher(for: .thrdUserBlocked)
            .sink { [weak self] _ in Task { await self?.load() } }
            .store(in: &cancellables)

        // The test/preview seam freezes state on purpose: CLLocationManager
        // delivers an authorization callback asynchronously right after a
        // delegate is assigned (independent of Combine's subscribe-time
        // replay), which would otherwise race in moments later and stomp the
        // seeded status with the simulator's real live value. Real call
        // sites (initialAuthorizationStatus == nil) still get live tracking.
        guard initialAuthorizationStatus == nil else { return }

        // Keep authorization state in sync, and retry a load if the user
        // grants access later (e.g. after following the Settings deep
        // link) — never call locationManager.requestPermission() from here.
        // dropFirst(): @Published's publisher replays the current value
        // immediately on subscribe; that replay is just this init's own
        // `locationManager.authorizationStatus` reassigned to itself, so
        // skipping it avoids a redundant no-op update, not a correctness fix.
        locationManager.$authorizationStatus
            .dropFirst()
            .sink { [weak self] status in
                guard let self else { return }
                let wasDenied = self.isLocationDenied
                self.authorizationStatus = status
                if wasDenied, status != .denied, status != .restricted {
                    Task { await self.load() }
                }
            }
            .store(in: &cancellables)

        // One-shot location read: react to the first coarse coordinate
        // LocationManager publishes. LocationManager already starts
        // updating on its own once authorized (T8's
        // locationManagerDidChangeAuthorization) — no new LocationManager
        // API is added here, this only observes what it already publishes.
        locationManager.$coarseCoordinate
            .compactMap { $0 }
            .first()
            .sink { [weak self] _ in
                Task { await self?.load() }
            }
            .store(in: &cancellables)
    }

    func load() async {
        guard !isLocationDenied else { return }
        isLoading = true
        loadError = false
        defer { isLoading = false }

        let coordinate = locationManager.coarseCoordinate
        let city = LaunchCity.nearest(to: coordinate)
        setCenter(coordinate ?? city.center)

        // Snap the coarse coordinate to a geohash-5 cell on-device BEFORE any
        // request (D8) — the repository accepts only a Geohash5, so the raw
        // coordinate cannot reach the transport. With no coordinate yet, query
        // the nearest launch city's cell.
        let cell = coordinate.map { Geohash5(latitude: $0.latitude, longitude: $0.longitude) }
            ?? city.geohash5

        // Own tickets start concurrently with the geo reads but reconcile
        // independently — a tickets failure must never blank the map.
        async let ticketsResult = repository.ownActiveTickets()
        do {
            async let spacesResult = repository.nearbySpaces(
                near: cell, radiusMeters: Self.defaultRadiusMeters)
            async let eventsResult = repository.nearbyEvents(
                near: cell, radiusMeters: Self.defaultRadiusMeters, horizonDays: Self.defaultHorizonDays)
            spaces = try await spacesResult
            events = try await eventsResult
        } catch {
            // The live path can throw (network, auth, server). Surface a
            // retryable error state; no server message text is shown (mapError
            // already stripped it — no schema leak).
            loadError = true
        }
        // "Your spot" badges are a nice-to-have overlay: degrade to none on a
        // tickets read failure rather than failing the whole screen.
        // ponytail: badges reflect the last Discover load — a fresh RSVP made on
        // Event Detail shows here after the next load/refresh, not instantly. A
        // shared RSVP store is the upgrade if live cross-screen sync is wanted;
        // out of scope for Phase 2 (no observed staleness in the RSVP flow).
        ownTickets = ((try? await ticketsResult) ?? [])
            .reduce(into: [:]) { $0[$1.eventId] = $1.status }
    }

    private func setCenter(_ coordinate: CLLocationCoordinate2D) {
        centerCoordinate = coordinate
    }

    /// The caller's own ticket status for an event, if any — nil renders no
    /// badge. The RSVP write lives on Event Detail; this is a read-only reflection
    /// of what the last load returned.
    func ticketStatus(for event: NearbyEvent) -> TicketStatus? {
        ownTickets[event.id]
    }
}
