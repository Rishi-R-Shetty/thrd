//
//  AuthTests.swift
//  thrdspacesTests
//
//  T5 unit + integration coverage:
//   • SwA nonce generation (entropy, charset, uniqueness, digest correctness)
//   • placeholder-handle derivation vs. the DB's `^[a-z0-9_]{3,30}$` constraint
//   • E.164 phone normalization (input-validation guard)
//   • a LIVE integration check that `requestOTP` surfaces the backend's real
//     response (provider-not-configured / rate-limit / success) as an
//     `APIError` rather than crashing — and terminates without looping.
//
//  Deliberately does NOT `import Supabase`: the test target links against the
//  host app for those symbols (see SupabaseClientProviderTests). CryptoKit is a
//  system framework and links directly, used here for an independent digest.
//

import XCTest
import CryptoKit
@testable import thrdspaces

final class AuthTests: XCTestCase {

    // MARK: - Nonce

    func testMakeRawNonceIs32BytesHexAndUnique() {
        let a = AuthViewModel.makeRawNonce()
        let b = AuthViewModel.makeRawNonce()

        XCTAssertEqual(a.count, 64, "32 bytes of entropy → 64 lowercase-hex chars")
        XCTAssertEqual(a.count / 2, 32, "hex string decodes to 32 bytes")
        XCTAssertNotEqual(a, b, "a fresh nonce must be generated per call")

        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(a.unicodeScalars.allSatisfy(hex.contains), "nonce is hex-charset only")
    }

    func testMakeRawNonceHonoursByteCount() {
        XCTAssertEqual(AuthViewModel.makeRawNonce(byteCount: 16).count, 32)
    }

    func testSha256HexMatchesManualDigest() {
        let nonce = AuthViewModel.makeRawNonce()
        let manual = SHA256.hash(data: Data(nonce.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(AuthViewModel.sha256Hex(nonce), manual,
                       "hashed nonce must equal an independent SHA-256 digest")
    }

    func testSha256HexKnownVector() {
        // sha256("") — a fixed vector, catches any encoding regression.
        XCTAssertEqual(
            AuthViewModel.sha256Hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    // MARK: - Placeholder handle

    func testPlaceholderHandleMatchesDBConstraint() {
        let id = UUID(uuidString: "1A2B3C4D-E5F6-7788-99AA-BBCCDDEEFF00")!
        XCTAssertEqual(AuthRepository.placeholderHandle(for: id), "user_1a2b3c4d")

        let pattern = "^[a-z0-9_]{3,30}$"
        // Every possible UUID begins with 8 hex digits, so the derived handle
        // must always satisfy the migration's CHECK — sample broadly.
        for _ in 0..<200 {
            let handle = AuthRepository.placeholderHandle(for: UUID())
            XCTAssertNotNil(
                handle.range(of: pattern, options: .regularExpression),
                "\(handle) violates ^[a-z0-9_]{3,30}$"
            )
        }
    }

    // MARK: - E.164 normalization

    func testNormalizeToE164AcceptsFormattedInput() throws {
        XCTAssertEqual(try AuthRepository.normalizeToE164("+1 (555) 123-4567"), "+15551234567")
        XCTAssertEqual(try AuthRepository.normalizeToE164("+44 7911 123.456"), "+447911123456")
    }

    func testNormalizeToE164RejectsInvalidInput() {
        XCTAssertThrowsError(try AuthRepository.normalizeToE164("5551234567"), "no country code")
        XCTAssertThrowsError(try AuthRepository.normalizeToE164("+0123456789"), "leading zero")
        XCTAssertThrowsError(try AuthRepository.normalizeToE164("+123"), "too short")
        XCTAssertThrowsError(try AuthRepository.normalizeToE164("not a phone"))
    }

    // MARK: - Live integration: requestOTP surfaces the backend, never crashes

    /// Hits the real Supabase project. Passes whether the SMS provider is
    /// configured (request accepted) or not (surfaced as `APIError`). A single
    /// awaited call — no retry loop. Skips only on a transport failure so an
    /// offline runner isn't a false negative.
    func testRequestOTPSurfacesBackendResultAsAPIError() async throws {
        let repository = AuthRepository()
        // Twilio "magic" test number — well-formed E.164, never delivers a real
        // SMS even if a live SMS sender is wired.
        let testPhone = "+15005550006"

        do {
            try await repository.requestOTP(phone: testPhone)
            // Provider configured and accepted the request: a valid outcome.
        } catch let apiError as APIError {
            // Provider missing / disabled / rate-limited / rejected: the
            // backend's response was mapped to our error surface, not a crash.
            if case let .network(underlying) = apiError, underlying is URLError {
                throw XCTSkip("backend unreachable from runner: \(underlying)")
            }
            // Any other APIError case is the expected "surfaced" outcome.
        } catch {
            XCTFail("requestOTP surfaced a non-APIError: \(error)")
        }
    }
}
