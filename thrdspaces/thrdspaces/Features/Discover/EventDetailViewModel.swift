//
//  EventDetailViewModel.swift
//  ThrdSpaces — Features/Discover
//
//  Loads the two backend-sourced sections of Event Detail — the host's public
//  profile and the attendee-preview strip — through the `DiscoverRepository`
//  seam. Block goes through `EdgeFunctionClient` (the same privileged-call
//  boundary Profile uses); the target is the host user id, derived here from the
//  event, and identity of the actor is JWT-side only. The view model imports no
//  Supabase; error copy reuses `ProfileErrorCopy` so nothing server-shaped leaks.
//

import Combine
import Foundation

@MainActor
final class EventDetailViewModel: ObservableObject {

    let event: NearbyEvent
    /// The resolved venue for the snippet + venue navigation. Present when the
    /// caller could resolve the event's space from the loaded discovery set
    /// (the common case — the venue is nearby); nil falls back to `event`'s
    /// denormalized `venueName` with no drill-in.
    let venueSpace: NearbySpace?

    @Published private(set) var host: PublicProfile?
    @Published private(set) var attendeePreviews: [AttendeePreview] = []
    @Published private(set) var isLoading = false
    /// Per-section failure flags — host and attendees are independent fetches, so
    /// one failing must never hide the other's loaded data. The host section
    /// degrades to static "Host unavailable" copy; the attendee section shows
    /// `attendeesErrorMessage` (non-leaking, via `ProfileErrorCopy`).
    @Published private(set) var hostError = false
    @Published private(set) var attendeesError = false
    /// Non-leaking copy for an attendee-strip load failure. Derived via
    /// `ProfileErrorCopy`, so no backend message text reaches the UI.
    @Published private(set) var attendeesErrorMessage: String?
    /// Transient feedback after a block from the host menu.
    @Published var actionMessage: String?

    // MARK: RSVP state (T17)

    /// The caller's own ticket state for THIS event: nil = not going, else
    /// `.going` / `.waitlist`. Drives the CTA. Reconciled from the server on
    /// every RSVP/cancel (the server is authoritative — never a local count).
    @Published private(set) var rsvpStatus: TicketStatus?
    /// The event's going-count as shown. Seeded from the event, reconciled to the
    /// server's `rsvp_count` after each RSVP/cancel (and optimistically nudged in
    /// between). Powers `overflowGoingCount`.
    @Published private(set) var rsvpCount: Int
    /// True while an RSVP/cancel round-trip is in flight (drives the CTA spinner
    /// and blocks a second concurrent tap).
    @Published private(set) var isSubmittingRSVP = false
    /// Non-leaking copy for an RSVP failure — shown in an alert, then cleared.
    @Published var rsvpErrorMessage: String?
    /// Monotonic triggers for `.sensoryFeedback`: bumped on a confirmed success
    /// and on a failure respectively (a changing value is what fires the haptic).
    @Published private(set) var rsvpSuccessPulse = 0
    @Published private(set) var rsvpErrorPulse = 0

    private let repository: DiscoverRepository
    private let functions = EdgeFunctionClient()
    /// The center block-invalidation posts/observes on (T18) — a test seam;
    /// production uses `.default`.
    private let notificationCenter: NotificationCenter
    private var cancellables = Set<AnyCancellable>()
    /// The RSVP write, injected so tests can drive optimistic/reconcile/rollback
    /// without a live backend. Production uses the real Edge Function call.
    private let performRSVP: @Sendable (UUID, RSVPAction) async throws -> RSVPResult

    init(event: NearbyEvent, venueSpace: NearbySpace? = nil,
         repository: DiscoverRepository = SupabaseDiscoverRepository(),
         notificationCenter: NotificationCenter = .default,
         performRSVP: @escaping @Sendable (UUID, RSVPAction) async throws -> RSVPResult
            = { try await EdgeFunctionClient().rsvp(eventID: $0, action: $1) }) {
        self.event = event
        self.venueSpace = venueSpace
        self.repository = repository
        self.notificationCenter = notificationCenter
        self.rsvpCount = event.rsvpCount
        self.performRSVP = performRSVP

        // Block invalidation (T18): if a block happens anywhere while this detail
        // is on screen, re-fetch the attendee strip so a now-excluded attendee
        // drops off. Previews carry no ids (first name only), so a known-blocked
        // row can't be filtered client-side — a re-fetch through the server's
        // 0005 exclusion is the only correct drop. Silent refetch (no host-loader
        // flash); host isn't reloaded because a block never changes it here.
        notificationCenter.publisher(for: .thrdUserBlocked)
            .sink { [weak self] _ in Task { await self?.refreshAttendeesAfterBlock() } }
            .store(in: &cancellables)
    }

    /// Attendees beyond the ones shown as previews — "and N more going". Clamped
    /// at zero (the preview count can exceed the reconciled `rsvpCount`).
    var overflowGoingCount: Int {
        max(rsvpCount - attendeePreviews.count, 0)
    }

    func load() async {
        isLoading = true
        hostError = false
        attendeesError = false
        attendeesErrorMessage = nil
        defer { isLoading = false }
        // All three fetches start concurrently; each is awaited in its own
        // do/catch so a failure in one leaves the others' results intact.
        async let hostResult = repository.publicProfile(id: event.hostId)
        async let attendeesResult = repository.attendeePreviews(eventID: event.id)
        async let ticketsResult = repository.ownActiveTickets()
        do { host = try await hostResult } catch { hostError = true }
        do {
            attendeePreviews = try await attendeesResult
        } catch {
            attendeesError = true
            attendeesErrorMessage = ProfileErrorCopy.message(for: error)
        }
        // Own-ticket read is a nice-to-have: a failure just leaves the CTA in its
        // "RSVP" state (tapping then reconciles idempotently against the server).
        if let tickets = try? await ticketsResult {
            rsvpStatus = tickets.first { $0.eventId == event.id }?.status
        }
    }

    /// RSVP to this event. Optimistically shows "going" (the common outcome),
    /// then reconciles to whatever the server returns (which may be "waitlist" if
    /// the event filled). Rolls back visually on failure.
    func rsvp() async { await submitRSVP(.rsvp) }

    /// Cancel the caller's RSVP. Optimistically clears the spot, then reconciles.
    func cancelRSVP() async { await submitRSVP(.cancel) }

    private func submitRSVP(_ action: RSVPAction) async {
        guard !isSubmittingRSVP else { return }
        let previousStatus = rsvpStatus
        let previousCount = rsvpCount
        isSubmittingRSVP = true
        rsvpErrorMessage = nil

        // Optimistic UI — reconciled to the server response below. Only the
        // going-count moves optimistically; the server owns the true count.
        switch action {
        case .rsvp:
            if previousStatus == nil { rsvpCount += 1 }
            rsvpStatus = .going
        case .cancel:
            if previousStatus == .going { rsvpCount = max(rsvpCount - 1, 0) }
            rsvpStatus = nil
        }

        do {
            let result = try await performRSVP(event.id, action)
            // Server is the source of truth: reconcile status + count exactly.
            // A `cancelled` status maps to "not going" (nil) for the CTA.
            rsvpStatus = result.status == .cancelled ? nil : result.status
            rsvpCount = result.rsvpCount
            rsvpSuccessPulse += 1
        } catch {
            // Roll back the optimistic change and surface non-leaking copy.
            rsvpStatus = previousStatus
            rsvpCount = previousCount
            rsvpErrorMessage = (error as? RSVPError)?.userMessage ?? RSVPError.unexpected.userMessage
            rsvpErrorPulse += 1
        }
        isSubmittingRSVP = false
    }

    /// Blocks the host, then surfaces a neutral notice (mirrors
    /// `ProfileViewModel.blockUser`). The block affects another user, so it goes
    /// through the Edge Function, never a direct table write (threat-model rule 8).
    func blockHost() async {
        do {
            try await functions.block(userID: event.hostId)
            actionMessage = "This person has been blocked."
            // Tell Discover (and any open attendee strip) to re-fetch so the now-
            // excluded host drops off without waiting for a manual pull-to-refresh.
            BlockSignal.userBlocked(on: notificationCenter)
        } catch {
            actionMessage = ProfileErrorCopy.message(for: error)
        }
    }

    /// Silent attendee-strip refetch after a block signal (T18). The server
    /// (migration 0005) now excludes the blocked user, so a re-fetch is what drops
    /// any blocked attendee from the preview strip. A failure leaves the current
    /// strip in place — degrade to stale rather than blanking a working section.
    private func refreshAttendeesAfterBlock() async {
        if let previews = try? await repository.attendeePreviews(eventID: event.id) {
            attendeePreviews = previews
        }
    }
}
