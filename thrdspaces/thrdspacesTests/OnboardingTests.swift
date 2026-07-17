//
//  OnboardingTests.swift
//  thrdspacesTests
//
//  T6 unit coverage (pure logic — no live backend):
//   • OnboardingCoordinator state-machine transitions
//   • InterestPickerViewModel ≥3 gating
//   • EULAViewModel accept gating (checkbox OR scrolled-to-bottom)
//   • AgeGateViewModel.evaluate range→adult/minor mapping (incl. under-18)
//   • AgeAttestationMetadata (A1) shape: device_id present, method ∈ {api,
//     attestation}, api_result nil for attestation
//   • InterestTag list integrity (12 unique contract slugs)
//   • updateInterests rejects non-contract slugs before any network call
//
//  Deliberately does NOT `import Supabase`: only the app under test links it.
//

import XCTest
@testable import thrdspaces

final class OnboardingTests: XCTestCase {

    // MARK: - Coordinator state machine

    @MainActor
    func testCoordinatorWalksTheFullFlow() {
        let c = OnboardingCoordinator()
        XCTAssertEqual(c.step, .loading, "starts in loading until bootstrap resolves")

        c.completeWelcome();   XCTAssertEqual(c.step, .signIn)
        c.completeSignIn();    XCTAssertEqual(c.step, .ageGate)
        c.completeAgeGate();   XCTAssertEqual(c.step, .eula)
        c.completeEULA();      XCTAssertEqual(c.step, .interests)
        c.completeInterests(); XCTAssertEqual(c.step, .location)
        c.completeLocation();  XCTAssertEqual(c.step, .done)
    }

    @MainActor
    func testCoordinatorBlockResetReturnsToWelcome() {
        let c = OnboardingCoordinator()
        c.completeWelcome()
        c.completeSignIn()
        XCTAssertEqual(c.step, .ageGate)
        // Under-18 sign-out path resets the flow.
        c.resetToWelcome()
        XCTAssertEqual(c.step, .welcome)
    }

    // MARK: - Interest ≥3 gating

    @MainActor
    func testInterestPickerRequiresAtLeastThree() {
        let vm = InterestPickerViewModel()
        XCTAssertFalse(vm.canContinue, "no selection → disabled")

        vm.selection = ["books"]
        XCTAssertFalse(vm.canContinue)

        vm.selection = ["books", "chess"]
        XCTAssertFalse(vm.canContinue, "two selected → still disabled")

        vm.selection = ["books", "chess", "coffee"]
        XCTAssertTrue(vm.canContinue, "three selected → enabled")

        XCTAssertEqual(InterestPickerViewModel.minimumSelection, 3)
    }

    @MainActor
    func testInterestPickerChipItemsMirrorTheTagList() {
        let vm = InterestPickerViewModel()
        XCTAssertEqual(vm.chipItems.map(\.id), InterestTag.all.map(\.id))
    }

    // MARK: - EULA accept gating

    @MainActor
    func testEULAAcceptUnlocksViaCheckboxOrScroll() {
        let vm = EULAViewModel()
        XCTAssertFalse(vm.canAccept, "locked until read or checked")

        vm.acceptedCheckbox = true
        XCTAssertTrue(vm.canAccept, "checkbox unlocks")

        vm.acceptedCheckbox = false
        XCTAssertFalse(vm.canAccept)

        vm.markScrolledToBottom()
        XCTAssertTrue(vm.canAccept, "scrolling to the end unlocks")

        XCTAssertFalse(EULAViewModel.termsVersion.isEmpty, "acceptance must be versioned")
        XCTAssertFalse(EULAViewModel.sections.isEmpty, "placeholder terms copy present")
    }

    // MARK: - Age-gate decision mapping

    func testAgeGateEvaluateMapsRangesToAdultOrMinor() {
        typealias VM = AgeGateViewModel
        // 18+ ranges (open upper bound) → adult (pass).
        XCTAssertEqual(VM.evaluate(lowerBound: 18, upperBound: nil), .adult)
        XCTAssertEqual(VM.evaluate(lowerBound: 21, upperBound: nil), .adult)
        // Under-18 API results → minor (blocked).
        XCTAssertEqual(VM.evaluate(lowerBound: nil, upperBound: 18), .minor)
        XCTAssertEqual(VM.evaluate(lowerBound: 13, upperBound: 17), .minor)
        XCTAssertEqual(VM.evaluate(lowerBound: 16, upperBound: 18), .minor)
        // Fail-closed: an empty/malformed range never grants an adult pass.
        XCTAssertEqual(VM.evaluate(lowerBound: nil, upperBound: nil), .minor)
        // Threshold is 18 per D3.
        XCTAssertEqual(VM.threshold, 18)
    }

    // MARK: - Audit metadata shape (A1)

    func testAgeAttestationMetadataMatchesA1Shape() {
        let api = AgeAttestationMetadata(deviceID: "device-abc",
                                         method: .api,
                                         apiResult: AgeGateViewModel.adultCategory)
        XCTAssertEqual(api.deviceID, "device-abc", "device_id present")
        XCTAssertEqual(api.method, .api)
        XCTAssertEqual(api.apiResult, "18_or_over", "api_result carries the category when method == api")

        let attestation = AgeAttestationMetadata(deviceID: "device-abc",
                                                 method: .attestation,
                                                 apiResult: nil)
        XCTAssertEqual(attestation.method, .attestation)
        XCTAssertNil(attestation.apiResult, "api_result is nil for the attestation method")

        // Raw values must be exactly the A1 contract strings.
        XCTAssertEqual(AgeAttestationMetadata.Method.api.rawValue, "api")
        XCTAssertEqual(AgeAttestationMetadata.Method.attestation.rawValue, "attestation")
    }

    // MARK: - InterestTag list integrity

    func testInterestTagListMatchesContract() {
        let expected: Set<String> = [
            "books", "running", "chess", "coffee", "music", "wellness",
            "art", "food", "sport", "tech", "language", "board_games",
        ]
        let ids = InterestTag.all.map(\.id)

        XCTAssertEqual(ids.count, 12, "exactly 12 tags")
        XCTAssertEqual(Set(ids).count, 12, "slugs are unique")
        XCTAssertEqual(Set(ids), expected, "slugs match the data-shape contract exactly")

        // Every tag has a label and symbol, and each slug is [a-z0-9_].
        XCTAssertTrue(InterestTag.all.allSatisfy { !$0.label.isEmpty && !$0.sfSymbol.isEmpty })
        let slugPattern = "^[a-z0-9_]+$"
        XCTAssertTrue(ids.allSatisfy { $0.range(of: slugPattern, options: .regularExpression) != nil },
                      "slugs must be lowercase [a-z0-9_]")
    }

    // MARK: - updateInterests slug validation (trust boundary)

    func testUpdateInterestsRejectsNonContractSlugsBeforeNetwork() async {
        let repository = AuthRepository()
        do {
            // A slug outside InterestTag.all must be rejected at the validation
            // guard, before any session/network call.
            try await repository.updateInterests(["books", "definitely_not_a_tag", "chess"])
            XCTFail("non-contract slug should have been rejected")
        } catch AuthRepository.ValidationError.invalidInterestSlug {
            // expected
        } catch {
            XCTFail("expected invalidInterestSlug, got \(error)")
        }
    }
}
