//
//  SpaceDetailViewModel.swift
//  ThrdSpaces — Features/Discover
//
//  Loads the two backend-sourced sections of Space Detail — the communities that
//  meet at this venue and its upcoming published events — through the
//  `DiscoverRepository` seam (previews/tests inject the mock). The venue's own
//  attributes (name/category/address/hours/amenities/coords) come from the
//  `NearbySpace` handed in at construction, so no extra fetch is needed for the
//  header. Views never reach the Supabase client; this view model doesn't either.
//

import Combine
import Foundation

@MainActor
final class SpaceDetailViewModel: ObservableObject {

    /// The venue whose detail this screen renders — its header fields come
    /// straight from the discovery DTO (already loaded when the user tapped in).
    let space: NearbySpace

    @Published private(set) var communities: [Community] = []
    @Published private(set) var upcomingEvents: [Event] = []
    @Published private(set) var isLoading = false
    /// Per-section failure flags — the two fetches are independent, so one
    /// section erroring must never discard or hide the other's loaded data.
    /// Each section shows a retry affordance for its own flag; no server message
    /// text is surfaced (non-leaking).
    @Published private(set) var communitiesError = false
    @Published private(set) var eventsError = false

    private let repository: DiscoverRepository

    init(space: NearbySpace, repository: DiscoverRepository = SupabaseDiscoverRepository()) {
        self.space = space
        self.repository = repository
    }

    func load() async {
        isLoading = true
        communitiesError = false
        eventsError = false
        defer { isLoading = false }
        // Both fetches start concurrently; each is awaited in its own do/catch so
        // a failure in one leaves the other's assigned result intact.
        async let communitiesResult = repository.communitiesMeetingAt(spaceID: space.id)
        async let eventsResult = repository.events(atSpace: space.id)
        do { communities = try await communitiesResult } catch { communitiesError = true }
        do { upcomingEvents = try await eventsResult } catch { eventsError = true }
    }

    /// Rebuilds a `NearbyEvent` from an `Event` at this venue for navigation into
    /// Event Detail: the venue name/coords come from `space`, and the distance is
    /// this space's own distance (the event is here), so Event Detail stays a
    /// single shape regardless of whether it was reached from the map or here.
    func nearbyEvent(for event: Event) -> NearbyEvent {
        NearbyEvent(
            id: event.id, communityId: event.communityId, hostId: event.hostId,
            spaceId: event.spaceId, title: event.title, description: event.description,
            coverUrl: event.coverUrl, startsAt: event.startsAt, endsAt: event.endsAt,
            recurrenceRule: event.recurrenceRule, capacity: event.capacity,
            price: event.price, status: event.status, rsvpCount: event.rsvpCount,
            createdAt: event.createdAt, venueName: space.name,
            latitude: space.latitude, longitude: space.longitude,
            distanceMeters: space.distanceMeters)
    }
}
