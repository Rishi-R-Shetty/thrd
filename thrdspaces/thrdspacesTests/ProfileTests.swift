//
//  ProfileTests.swift
//  thrdspacesTests
//
//  T7a unit coverage (pure logic — no live backend):
//   • ProfileValidation bounds: handle regex, display_name 1–50, bio ≤280
//   • Avatar initials + deterministic color-index from a fixed UUID
//   • ReportReason contract + ReportSheet detail/reason constraints
//   • EdgeFunctionClient error-shape decoding: rate_limited → 429 + "try again"
//     copy; not_found → 404 + "reach the server" copy; already_reported →
//     success-with-notice; deletion purge_after parsing
//   • ProfileViewModel 23505 → "handle taken" mapping
//   • AccountDeletion state logic: sign out ONLY on a confirmed 200
//   • SupportEmail resolves from the bundle plist (A3), not a hardcoded literal
//
//  Deliberately does NOT `import Supabase`: only the app under test links it.
//

import XCTest
@testable import thrdspaces

final class ProfileTests: XCTestCase {

    // MARK: - Handle / display_name / bio bounds

    func testHandleValidationMatchesRegex() {
        XCTAssertTrue(ProfileValidation.isValidHandle("ada_l"))
        XCTAssertTrue(ProfileValidation.isValidHandle("abc"), "3 chars is the minimum")
        XCTAssertTrue(ProfileValidation.isValidHandle(String(repeating: "a", count: 30)), "30 is the max")
        XCTAssertFalse(ProfileValidation.isValidHandle("ab"), "too short")
        XCTAssertFalse(ProfileValidation.isValidHandle(String(repeating: "a", count: 31)), "too long")
        XCTAssertFalse(ProfileValidation.isValidHandle("Ada"), "uppercase not allowed")
        XCTAssertFalse(ProfileValidation.isValidHandle("has space"))
        XCTAssertFalse(ProfileValidation.isValidHandle("dash-no"))
        XCTAssertFalse(ProfileValidation.isValidHandle(""))
    }

    func testHandleNormalizationLowercasesAndTrims() {
        XCTAssertEqual(ProfileValidation.normalizeHandle("  Ada_L  "), "ada_l")
        XCTAssertTrue(ProfileValidation.isValidHandle(ProfileValidation.normalizeHandle("Ada_L")))
    }

    func testDisplayNameBounds() {
        XCTAssertFalse(ProfileValidation.isValidDisplayName(""), "empty rejected")
        XCTAssertFalse(ProfileValidation.isValidDisplayName("   "), "whitespace-only rejected")
        XCTAssertTrue(ProfileValidation.isValidDisplayName("A"), "1 char ok")
        XCTAssertTrue(ProfileValidation.isValidDisplayName(String(repeating: "x", count: 50)))
        XCTAssertFalse(ProfileValidation.isValidDisplayName(String(repeating: "x", count: 51)), "over 50 rejected")
        XCTAssertEqual(ProfileValidation.displayNameLimit, 50)
    }

    func testBioBounds() {
        XCTAssertTrue(ProfileValidation.isValidBio(""), "empty bio is allowed")
        XCTAssertTrue(ProfileValidation.isValidBio(String(repeating: "x", count: 280)))
        XCTAssertFalse(ProfileValidation.isValidBio(String(repeating: "x", count: 281)), "over 280 rejected")
        XCTAssertEqual(ProfileValidation.bioLimit, 280)
    }

    // MARK: - Avatar (D2): initials + deterministic color

    func testAvatarInitials() {
        XCTAssertEqual(Avatar.initials(displayName: "Ada Lovelace", handle: "ada_l"), "AL")
        XCTAssertEqual(Avatar.initials(displayName: "", handle: "madhu"), "M", "falls back to handle")
        XCTAssertEqual(Avatar.initials(displayName: "   ", handle: "bob"), "B")
        XCTAssertEqual(Avatar.initials(displayName: "SingleName", handle: "x"), "S")
        XCTAssertEqual(Avatar.initials(displayName: "user_1a2b3c4d", handle: "user_1a2b3c4d"), "U1",
                       "underscore splits the placeholder handle")
    }

    func testAvatarColorIndexIsDeterministic() {
        let id = UUID(uuidString: "1E1C0DED-0000-4000-8000-000000000001")!
        // Same id → same index, every call.
        XCTAssertEqual(Avatar.paletteIndex(for: id), Avatar.paletteIndex(for: id))
        // Concrete expected value locks the mapping (sum of bytes % palette count).
        XCTAssertEqual(Avatar.paletteIndex(for: id), 3)
        // Always in range.
        XCTAssertTrue((0..<Avatar.palette.count).contains(Avatar.paletteIndex(for: id)))
        let other = UUID(uuidString: "1E1C0DED-0000-4000-8000-000000000002")!
        XCTAssertEqual(Avatar.paletteIndex(for: other), Avatar.paletteIndex(for: other))
    }

    // MARK: - Interest labels

    func testInterestLabelsMapContractSlugsInOrder() {
        let summary = ProfileSummary(id: UUID(), handle: "x", displayName: "X", bio: nil,
                                     interests: ["tech", "coffee", "not_a_tag"])
        // Order follows InterestTag.all (coffee before tech); unknown slug dropped.
        XCTAssertEqual(summary.interestLabels, ["Coffee", "Tech"])
    }

    // MARK: - Report reason + detail constraints

    func testReportReasonMatchesContract() {
        XCTAssertEqual(ReportReason.allCases.map(\.rawValue), ["safety", "harassment", "spam", "other"])
    }

    @MainActor
    func testReportDetailConstraints() {
        let vm = ReportSheetViewModel()
        XCTAssertEqual(vm.reason, .safety, "default reason")
        XCTAssertEqual(EdgeFunctionClient.detailLimit, 500)

        vm.detail = String(repeating: "x", count: 500)
        XCTAssertFalse(vm.isDetailOverLimit)
        XCTAssertTrue(vm.canSubmit)

        vm.detail = String(repeating: "x", count: 501)
        XCTAssertTrue(vm.isDetailOverLimit)
        XCTAssertFalse(vm.canSubmit, "over the limit blocks submit")
    }

    // MARK: - EdgeFunctionClient error-shape decoding

    func testFunctionErrorMapsStatusToAPIErrorAndCopy() {
        let rate = EdgeFunctionClient.mapFunctionError(status: 429, data: Data(#"{"error":"rate_limited"}"#.utf8))
        guard case .server(429) = rate else { return XCTFail("rate_limited should map to server 429") }
        XCTAssertTrue(ProfileErrorCopy.message(for: rate).lowercased().contains("try again"),
                      "429 copy invites a retry later")

        let notFound = EdgeFunctionClient.mapFunctionError(status: 404, data: Data(#"{"error":"not_found"}"#.utf8))
        guard case .server(404) = notFound else { return XCTFail("404 should map to server 404") }
        XCTAssertTrue(ProfileErrorCopy.message(for: notFound).lowercased().contains("reach the server"),
                      "a not-deployed/unreachable function reads as a server reachability issue")

        let unauthorized = EdgeFunctionClient.mapFunctionError(status: 401, data: Data(#"{"error":"unauthorized"}"#.utf8))
        guard case .auth = unauthorized else { return XCTFail("401 should map to .auth") }
    }

    func testReportOutcomeDecoding() {
        XCTAssertEqual(EdgeFunctionClient.reportOutcome(from: Data(#"{"status":"already_reported"}"#.utf8)),
                       .alreadyReported, "dedupe notice is a success-with-notice, not an error")
        XCTAssertEqual(EdgeFunctionClient.reportOutcome(from: Data(#"{"status":"submitted"}"#.utf8)), .submitted)
        XCTAssertEqual(EdgeFunctionClient.reportOutcome(from: Data("{}".utf8)), .submitted,
                       "a 200 without the dedupe marker is a fresh submission")
    }

    func testDeletionResultParsesPurgeAfter() {
        let data = Data(#"{"status":"pending_deletion","purge_after":"2026-08-11T12:00:00.000Z"}"#.utf8)
        XCTAssertNotNil(EdgeFunctionClient.deletionResult(from: data).purgeAfter)
        XCTAssertNil(EdgeFunctionClient.deletionResult(from: Data("{}".utf8)).purgeAfter,
                     "missing purge_after is non-fatal")
    }

    // MARK: - Handle-taken (23505) mapping

    func testHandleTakenMapsUniqueViolationCode() {
        XCTAssertTrue(ProfileViewModel.handleTaken(fromPostgrestCode: "23505"), "unique violation → taken")
        XCTAssertFalse(ProfileViewModel.handleTaken(fromPostgrestCode: "23503"), "FK violation is not a taken handle")
        XCTAssertFalse(ProfileViewModel.handleTaken(fromPostgrestCode: nil))
    }

    // MARK: - Account deletion state logic

    @MainActor
    func testDeletionSignsOutOnlyOnConfirmedSuccess() {
        let vm = AccountDeletionViewModel()

        // Unavailable function (404) → failed phase, and DO NOT sign out.
        let signOutAfterFailure = vm.applyDeletionResult(.failure(APIError.server(status: 404)))
        XCTAssertFalse(signOutAfterFailure, "an error must never trigger sign-out")
        if case let .failed(message) = vm.phase {
            XCTAssertTrue(message.lowercased().contains("reach the server"))
        } else {
            XCTFail("expected .failed phase, got \(vm.phase)")
        }

        // Confirmed 200 → deleted phase, and sign out.
        let signOutAfterSuccess = vm.applyDeletionResult(.success(()))
        XCTAssertTrue(signOutAfterSuccess, "a confirmed 200 signs out locally")
        XCTAssertEqual(vm.phase, .deleted)
    }

    // MARK: - Support email (A3): from the plist, not hardcoded

    func testSupportEmailResolvesFromBundlePlist() {
        let email = AppSupport.supportEmail
        XCTAssertNotNil(email, "SupportEmail must be present in Configuration.plist")
        // Cross-check against the plist directly — proves resolution from config,
        // without embedding the address literal in Swift source.
        let plistValue = Bundle.main.url(forResource: "Configuration", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) }?["SupportEmail"] as? String
        XCTAssertEqual(email, plistValue)
        XCTAssertTrue(email?.contains("@") == true, "a contact email should look like an email")
    }
}
