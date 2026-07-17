//
//  SupabaseClientProviderTests.swift
//  thrdspacesTests
//
//  Proves the T4 client-boot exit condition: the provider constructs from the
//  bundled Configuration.plist, and the auth endpoint answers with the anon
//  key.
//

import XCTest
@testable import thrdspaces

final class SupabaseClientProviderTests: XCTestCase {

    // Client boots from Configuration.plist without tripping the precondition.
    // Accessing `.shared` triggers lazy construction in `makeClient()`; a
    // missing/malformed plist would call `preconditionFailure` and crash the
    // test, so reaching the assertion proves the client booted. (We discard
    // the value rather than name its type — the test target doesn't link the
    // Supabase module, only the app under test does.)
    func testClientBootsFromConfiguration() {
        _ = SupabaseClientProvider.shared
        XCTAssertNotNil(
            Bundle.main.url(forResource: "Configuration", withExtension: "plist"),
            "Configuration.plist must be bundled for the client to boot"
        )
    }

    // Auth endpoint reachable with the anon key. Skips (rather than fails)
    // when the simulator has no network so an offline run isn't a false
    // negative — the task's shell curl covers the online assertion too.
    func testAuthHealthEndpointReturns200() async throws {
        let config = try XCTUnwrap(
            Bundle.main.url(forResource: "Configuration", withExtension: "plist")
                .flatMap { NSDictionary(contentsOf: $0) }
        )
        let urlString = try XCTUnwrap(config["SupabaseURL"] as? String)
        let anonKey = try XCTUnwrap(config["SupabaseAnonKey"] as? String)
        let healthURL = try XCTUnwrap(URL(string: urlString + "/auth/v1/health"))

        var request = URLRequest(url: healthURL)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200)
        } catch {
            throw XCTSkip("auth health endpoint unreachable from simulator: \(error)")
        }
    }
}
