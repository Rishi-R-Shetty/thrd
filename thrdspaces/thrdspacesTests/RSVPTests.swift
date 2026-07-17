//
//  RSVPTests.swift
//  thrdspacesTests
//
//  T17 unit coverage for the RSVP path (pure logic — no live backend):
//   • EdgeFunctionClient.mapRSVPError: every wire status → the right stable
//     RSVPError; the two 400 codes split on the {"error"} slug (event_not_open
//     vs the client-bug invalid_action → .unexpected)
//   • RSVPError.userMessage: copy is non-leaking (no status codes, slugs, or SQL)
//     and matches the specified strings for 429 / event_not_open /
//     verification_required
//   • EdgeFunctionClient.rsvpResult: the 200 body decodes into the canonical
//     TicketStatus + rsvp_count
//   • EventDetailViewModel RSVP state machine: optimistic "going", server
//     reconcile to waitlist, rollback on error, cancel clears the spot, and the
//     initial state seeds from the caller's own ticket
//
//  Does NOT import Supabase (only the app under test links it), mirroring
//  ProfileTests — the error mapping is exercised on decoded byte buffers.
//

import XCTest
@testable import thrdspaces

final class RSVPTests: XCTestCase {

    // MARK: - mapRSVPError: status + slug → stable RSVPError

    func testMapRSVPErrorMapsEachStatus() {
        func map(_ status: Int, _ body: String) -> RSVPError {
            EdgeFunctionClient.mapRSVPError(status: status, data: Data(body.utf8))
        }
        XCTAssertEqual(map(401, #"{"error":"unauthorized"}"#), .auth)
        XCTAssertEqual(map(403, #"{"error":"verification_required"}"#), .verificationRequired)
        XCTAssertEqual(map(404, #"{"error":"not_found"}"#), .notFound)
        XCTAssertEqual(map(429, #"{"error":"rate_limited"}"#), .rateLimited)
        XCTAssertEqual(map(503, #"{"error":"unavailable"}"#), .unavailable)
        XCTAssertEqual(map(500, #"{"error":"internal"}"#), .unexpected)
    }

    func testMapRSVPErrorSplitsTheTwo400Codes() {
        // event_not_open is a real user-facing state; invalid_action can only be a
        // client bug (we send validated actions) and must not leak a raw code.
        XCTAssertEqual(
            EdgeFunctionClient.mapRSVPError(status: 400, data: Data(#"{"error":"event_not_open"}"#.utf8)),
            .eventNotOpen)
        XCTAssertEqual(
            EdgeFunctionClient.mapRSVPError(status: 400, data: Data(#"{"error":"invalid_action"}"#.utf8)),
            .unexpected)
        // A 400 with no decodable slug also collapses to .unexpected.
        XCTAssertEqual(
            EdgeFunctionClient.mapRSVPError(status: 400, data: Data("{}".utf8)),
            .unexpected)
    }

    // MARK: - RSVPError copy is non-leaking + matches the spec

    func testRSVPErrorCopyMatchesSpecAndNeverLeaks() {
        XCTAssertEqual(RSVPError.eventNotOpen.userMessage, "This event isn't open for RSVP.")

        let rate = RSVPError.rateLimited.userMessage.lowercased()
        XCTAssertTrue(rate.contains("too often"), "429 copy is a generic 'too many attempts' message")

        let verify = RSVPError.verificationRequired.userMessage.lowercased()
        XCTAssertTrue(verify.contains("phone"), "verification copy explains phone verification")

        // No case leaks a status code, error slug, or SQL/schema token.
        let leaky = ["429", "403", "400", "404", "503", "500", "rate_limited",
                     "event_not_open", "verification_required", "sql", "select", "tickets"]
        for error in [RSVPError.eventNotOpen, .verificationRequired, .rateLimited,
                      .notFound, .auth, .unavailable, .network, .unexpected] {
            let message = error.userMessage.lowercased()
            for token in leaky {
                XCTAssertFalse(message.contains(token),
                               "RSVP copy must not leak '\(token)' — got: \(error.userMessage)")
            }
        }
    }

    // MARK: - rsvpResult: 200 body → RSVPResult

    func testRSVPResultDecodesStatusAndCount() throws {
        let going = try EdgeFunctionClient.rsvpResult(from: Data(#"{"status":"going","rsvp_count":25}"#.utf8))
        XCTAssertEqual(going, RSVPResult(status: .going, rsvpCount: 25))

        let waitlist = try EdgeFunctionClient.rsvpResult(from: Data(#"{"status":"waitlist","rsvp_count":40}"#.utf8))
        XCTAssertEqual(waitlist, RSVPResult(status: .waitlist, rsvpCount: 40))

        let cancelled = try EdgeFunctionClient.rsvpResult(from: Data(#"{"status":"cancelled","rsvp_count":39}"#.utf8))
        XCTAssertEqual(cancelled, RSVPResult(status: .cancelled, rsvpCount: 39))
    }

    func testRSVPResultThrowsOnMalformedBody() {
        XCTAssertThrowsError(try EdgeFunctionClient.rsvpResult(from: Data(#"{"status":"bogus"}"#.utf8)),
                             "an unknown status is a decode failure the client maps to .unexpected")
    }

    // MARK: - EventDetailViewModel RSVP state machine

    @MainActor
    func testRSVPGoingOptimisticThenReconciles() async {
        let event = makeEvent(rsvpCount: 24)
        let vm = EventDetailViewModel(event: event, repository: MockDiscoverRepository(),
                                      performRSVP: { _, _ in RSVPResult(status: .going, rsvpCount: 25) })
        XCTAssertNil(vm.rsvpStatus)
        XCTAssertEqual(vm.rsvpCount, 24)

        await vm.rsvp()

        XCTAssertEqual(vm.rsvpStatus, .going)
        XCTAssertEqual(vm.rsvpCount, 25, "count reconciles to the server's rsvp_count")
        XCTAssertFalse(vm.isSubmittingRSVP)
        XCTAssertEqual(vm.rsvpSuccessPulse, 1, "success emits one haptic pulse")
        XCTAssertNil(vm.rsvpErrorMessage)
    }

    @MainActor
    func testRSVPReconcilesToWaitlistWhenFull() async {
        // Optimistic UI shows "going", but the server placed the caller on the
        // waitlist (event full) — the UI must reconcile to the server truth.
        let vm = EventDetailViewModel(event: makeEvent(rsvpCount: 40), repository: MockDiscoverRepository(),
                                      performRSVP: { _, _ in RSVPResult(status: .waitlist, rsvpCount: 40) })
        await vm.rsvp()

        XCTAssertEqual(vm.rsvpStatus, .waitlist, "reconciles the optimistic 'going' down to waitlist")
        XCTAssertEqual(vm.rsvpCount, 40, "a waitlisted RSVP does not change the going-count")
    }

    @MainActor
    func testRSVPRollsBackOnError() async {
        let vm = EventDetailViewModel(event: makeEvent(rsvpCount: 12), repository: MockDiscoverRepository(),
                                      performRSVP: { _, _ in throw RSVPError.eventNotOpen })
        await vm.rsvp()

        XCTAssertNil(vm.rsvpStatus, "the optimistic 'going' rolls back to not-going on failure")
        XCTAssertEqual(vm.rsvpCount, 12, "the optimistic count increment rolls back")
        XCTAssertEqual(vm.rsvpErrorMessage, RSVPError.eventNotOpen.userMessage)
        XCTAssertFalse(vm.rsvpErrorMessage!.contains("400"), "no raw status in the surfaced copy")
        XCTAssertEqual(vm.rsvpErrorPulse, 1, "failure emits one error haptic pulse")
    }

    @MainActor
    func testCancelClearsSpotAndReconcilesCount() async {
        // Start "going" (seeded from an own ticket), then cancel.
        var mock = MockDiscoverRepository()
        let event = makeEvent(rsvpCount: 25)
        mock.ownTicketRows = [
            Ticket(id: UUID(), eventId: event.id, userId: UUID(), type: .rsvp,
                   status: .going, qrCodeToken: nil, purchasedAt: .now, checkedInAt: nil),
        ]
        let vm = EventDetailViewModel(event: event, repository: mock,
                                      performRSVP: { _, action in
            XCTAssertEqual(action, .cancel)
            return RSVPResult(status: .cancelled, rsvpCount: 24)
        })
        await vm.load()
        XCTAssertEqual(vm.rsvpStatus, .going, "initial state seeds from the own ticket")

        await vm.cancelRSVP()

        XCTAssertNil(vm.rsvpStatus, "a cancelled ticket reads as not-going")
        XCTAssertEqual(vm.rsvpCount, 24, "count reconciles to the server after promotion accounting")
    }

    @MainActor
    func testInitialStateIsNotGoingWithoutAnOwnTicket() async {
        let vm = EventDetailViewModel(event: makeEvent(rsvpCount: 3), repository: MockDiscoverRepository())
        await vm.load()
        XCTAssertNil(vm.rsvpStatus, "no own ticket → the CTA shows RSVP")
    }

    // MARK: - Fixture

    private func makeEvent(rsvpCount: Int) -> NearbyEvent {
        NearbyEvent(id: UUID(), communityId: nil, hostId: MockDiscoverRepository.mockHost.id,
                    spaceId: UUID(), title: "Silent Book Club", description: nil, coverUrl: nil,
                    startsAt: .now.addingTimeInterval(3600 * 6), endsAt: .now.addingTimeInterval(3600 * 8),
                    recurrenceRule: nil, capacity: 40, price: 0, status: .published,
                    rsvpCount: rsvpCount, createdAt: .now, venueName: "Third Wave Coffee",
                    latitude: 12.9719, longitude: 77.6412, distanceMeters: 5010)
    }
}
