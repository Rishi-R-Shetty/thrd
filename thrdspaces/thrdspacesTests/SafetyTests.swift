//
//  SafetyTests.swift
//  thrdspacesTests
//
//  T19 unit coverage for the safety surfaces (pure logic — no live backend, no
//  Messages/dialer launch):
//   • First-meeting sheet GATES the first RSVP: a caller with no active tickets
//     is routed to the sheet (no server call); acknowledging then performs the
//     RSVP; a returning caller (has a ticket) RSVPs directly with no sheet.
//   • Panic button window: ±2h boundaries around startsAt (inclusive edges;
//     outside is hidden).
//   • Panic URLs are device-local: the emergency `tel://` number and the `sms:`
//     to the contact carrying a maps link — the contact phone is the recipient,
//     the body carries only the (public) venue coords. Nothing server-shaped.
//   • EmergencyContactStore round-trips through the Keychain with the
//     non-negotiable accessibility class (D9), against a scratch service.
//

import XCTest
import Security
@testable import thrdspaces

final class SafetyTests: XCTestCase {

    // MARK: - First-meeting gate (exit condition 1)

    /// Records whether the RSVP write was actually invoked, so a test can prove
    /// the sheet blocks the server call. `@unchecked Sendable` is safe: the
    /// closure and assertions all run on the main actor in these tests.
    private final class RSVPRecorder: @unchecked Sendable {
        private(set) var callCount = 0
        func record() { callCount += 1 }
    }

    @MainActor
    func testFirstRSVPIsGatedByTheSafetySheet() async {
        // No active tickets → this is the caller's first RSVP.
        let recorder = RSVPRecorder()
        let vm = EventDetailViewModel(
            event: makeEvent(), repository: MockDiscoverRepository(),
            performRSVP: { _, _ in recorder.record(); return RSVPResult(status: .going, rsvpCount: 25) })
        await vm.load()
        XCTAssertTrue(vm.isFirstRSVP, "no active tickets → first RSVP")

        await vm.rsvp()

        XCTAssertTrue(vm.showSafetySheet, "the first RSVP presents the safety sheet")
        XCTAssertEqual(recorder.callCount, 0, "no server RSVP happens until acknowledged")
        XCTAssertNil(vm.rsvpStatus, "no optimistic 'going' before acknowledgement")
    }

    @MainActor
    func testAcknowledgingSheetPerformsTheGatedRSVP() async {
        let recorder = RSVPRecorder()
        let vm = EventDetailViewModel(
            event: makeEvent(), repository: MockDiscoverRepository(),
            performRSVP: { _, _ in recorder.record(); return RSVPResult(status: .going, rsvpCount: 25) })
        await vm.load()
        await vm.rsvp()
        XCTAssertTrue(vm.showSafetySheet)

        await vm.acknowledgeSafetyThenRSVP()

        XCTAssertFalse(vm.showSafetySheet, "acknowledgement dismisses the sheet")
        XCTAssertEqual(recorder.callCount, 1, "the RSVP now reaches the server")
        XCTAssertEqual(vm.rsvpStatus, .going)
    }

    @MainActor
    func testReturningUserRSVPsWithoutTheSheet() async {
        // An existing active ticket (for a DIFFERENT event) → not a first-timer.
        var mock = MockDiscoverRepository()
        mock.ownTicketRows = [
            Ticket(id: UUID(), eventId: UUID(), userId: UUID(), type: .rsvp,
                   status: .going, qrCodeToken: nil, purchasedAt: .now, checkedInAt: nil),
        ]
        let recorder = RSVPRecorder()
        let vm = EventDetailViewModel(
            event: makeEvent(), repository: mock,
            performRSVP: { _, _ in recorder.record(); return RSVPResult(status: .going, rsvpCount: 25) })
        await vm.load()
        XCTAssertFalse(vm.isFirstRSVP, "an existing active ticket → not a first RSVP")

        await vm.rsvp()

        XCTAssertFalse(vm.showSafetySheet, "returning user is not gated")
        XCTAssertEqual(recorder.callCount, 1, "the RSVP goes straight through")
        XCTAssertEqual(vm.rsvpStatus, .going)
    }

    @MainActor
    func testDismissSafetySheetDoesNotRSVP() async {
        let recorder = RSVPRecorder()
        let vm = EventDetailViewModel(
            event: makeEvent(), repository: MockDiscoverRepository(),
            performRSVP: { _, _ in recorder.record(); return RSVPResult(status: .going, rsvpCount: 25) })
        await vm.load()
        await vm.rsvp()

        vm.dismissSafetySheet()

        XCTAssertFalse(vm.showSafetySheet)
        XCTAssertEqual(recorder.callCount, 0, "declining the sheet writes nothing")
        XCTAssertNil(vm.rsvpStatus)
    }

    // MARK: - Panic window boundaries (exit condition 2)

    func testPanicWindowBoundaries() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let twoHours: TimeInterval = 2 * 60 * 60

        // Inside: at start, and just inside each edge.
        XCTAssertTrue(PanicButton.isWithinWindow(now: start, startsAt: start))
        XCTAssertTrue(PanicButton.isWithinWindow(now: start.addingTimeInterval(-twoHours), startsAt: start),
                      "the 2h-before edge is inclusive")
        XCTAssertTrue(PanicButton.isWithinWindow(now: start.addingTimeInterval(twoHours), startsAt: start),
                      "the 2h-after edge is inclusive")

        // Outside: just before and just after the window.
        XCTAssertFalse(PanicButton.isWithinWindow(now: start.addingTimeInterval(-twoHours - 1), startsAt: start),
                       "before the window the button is hidden")
        XCTAssertFalse(PanicButton.isWithinWindow(now: start.addingTimeInterval(twoHours + 1), startsAt: start),
                       "after the window the button is hidden")
    }

    // MARK: - Panic URLs are device-local (exit condition 3)

    func testEmergencyURLIsTheLocalDialer() {
        let url = PanicDialer.emergencyURL()
        XCTAssertEqual(url?.scheme, "tel")
        XCTAssertEqual(url?.absoluteString, "tel://112")
    }

    func testPanicSMSAddressesTheContactWithAMapsLink() throws {
        let contact = EmergencyContact(name: "Aisha", phone: "+911234567890")
        let url = try XCTUnwrap(PanicDialer.smsURL(
            contact: contact, venueName: "Third Wave Coffee",
            latitude: 12.9719, longitude: 77.6412))

        XCTAssertEqual(url.scheme, "sms")
        // The phone is the recipient (device-local sms:), never a network target.
        XCTAssertTrue(url.absoluteString.contains("+911234567890"),
                      "the contact phone addresses the local sms: URL")
        let body = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "body" })?.value)
        XCTAssertTrue(body.contains("maps.apple.com"), "the SMS body carries a maps link")
        XCTAssertTrue(body.contains("12.9719,77.6412"), "the maps link carries the venue coords")
    }

    // MARK: - EmergencyContactStore round-trips through the Keychain (D9)

    private let scratchService = "thrd.thrdspaces.safety.tests"

    override func tearDown() {
        try? KeychainTokenStore(service: scratchService).remove(key: EmergencyContactStore.key)
        super.tearDown()
    }

    func testEmergencyContactRoundTripsAndClears() throws {
        let store = EmergencyContactStore(keychain: KeychainTokenStore(service: scratchService))
        XCTAssertNil(store.load(), "precondition: no contact yet")

        try store.save(EmergencyContact(name: "  Mum  ", phone: " +91 12345 67890 "))
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.name, "Mum", "save trims whitespace")
        XCTAssertEqual(loaded.phone, "+91 12345 67890")

        try store.clear()
        XCTAssertNil(store.load(), "cleared contact is gone")
    }

    func testEmergencyContactUsesTheDeviceOnlyAccessibilityClass() throws {
        let store = EmergencyContactStore(keychain: KeychainTokenStore(service: scratchService))
        try store.save(EmergencyContact(name: "Mum", phone: "+911234567890"))

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scratchService,
            kSecAttrAccount as String: EmergencyContactStore.key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attrs = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                       "D9: the contact inherits the device-only, unlock-required class")
    }

    // MARK: - Fixture

    private func makeEvent() -> NearbyEvent {
        NearbyEvent(id: UUID(), communityId: nil, hostId: MockDiscoverRepository.mockHost.id,
                    spaceId: UUID(), title: "Silent Book Club", description: nil, coverUrl: nil,
                    startsAt: .now.addingTimeInterval(3600 * 6), endsAt: .now.addingTimeInterval(3600 * 8),
                    recurrenceRule: nil, capacity: 40, price: 0, status: .published,
                    rsvpCount: 24, createdAt: .now, venueName: "Third Wave Coffee",
                    latitude: 12.9719, longitude: 77.6412, distanceMeters: 5010)
    }
}
