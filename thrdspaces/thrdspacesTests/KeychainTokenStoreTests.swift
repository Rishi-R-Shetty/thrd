//
//  KeychainTokenStoreTests.swift
//  thrdspacesTests
//
//  Proves the T4 exit conditions for the keychain store: round-trip,
//  accessibility class, no UserDefaults/Preferences leak, stable fingerprint.
//

import XCTest
import Security
@testable import thrdspaces

final class KeychainTokenStoreTests: XCTestCase {

    // Dedicated service so tests never collide with the real
    // "thrd.thrdspaces.auth" items and tear down cleanly.
    private let testService = "thrd.thrdspaces.tests"
    private let key = "unit_test_token"
    private let fingerprintKey = "device_fingerprint"
    private var store: KeychainTokenStore!

    override func setUp() {
        super.setUp()
        store = KeychainTokenStore(service: testService)
        try? store.remove(key: key)
        try? store.remove(key: fingerprintKey)
    }

    override func tearDown() {
        try? store.remove(key: key)
        try? store.remove(key: fingerprintKey)
        store = nil
        super.tearDown()
    }

    // (a) store / retrieve / remove round-trip.
    func testStoreRetrieveRemoveRoundTrip() throws {
        XCTAssertNil(try store.retrieve(key: key), "precondition: key should be absent")

        let value = Data("access-token-abc123".utf8)
        try store.store(key: key, value: value)
        XCTAssertEqual(try store.retrieve(key: key), value)

        try store.remove(key: key)
        XCTAssertNil(try store.retrieve(key: key), "value should be gone after remove")
    }

    // (b) the stored item's kSecAttrAccessible is exactly
    // whenUnlockedThisDeviceOnly.
    func testStoredItemAccessibilityIsWhenUnlockedThisDeviceOnly() throws {
        try store.store(key: key, value: Data("tok".utf8))

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess)

        let attrs = try XCTUnwrap(result as? [String: Any])
        let accessible = attrs[kSecAttrAccessible as String] as? String
        XCTAssertEqual(accessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    // (c) after storing a token, it appears nowhere in UserDefaults nor in
    // the app container's Preferences plists.
    func testTokenDoesNotLeakToUserDefaultsOrPreferences() throws {
        let secret = "leak-canary-\(UUID().uuidString)"
        try store.store(key: key, value: Data(secret.utf8))

        UserDefaults.standard.synchronize()
        for (defaultsKey, value) in UserDefaults.standard.dictionaryRepresentation() {
            XCTAssertFalse(defaultsKey.contains(secret), "secret leaked into a UserDefaults key")
            XCTAssertFalse(
                String(describing: value).contains(secret),
                "secret leaked into a UserDefaults value"
            )
        }

        let prefsDir = try XCTUnwrap(
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Preferences")

        if let files = try? FileManager.default.contentsOfDirectory(
            at: prefsDir, includingPropertiesForKeys: nil
        ) {
            let needle = Data(secret.utf8)
            for file in files where file.pathExtension == "plist" {
                if let data = try? Data(contentsOf: file) {
                    XCTAssertNil(
                        data.range(of: needle),
                        "secret found in Preferences file \(file.lastPathComponent)"
                    )
                }
            }
        }
    }

    // (d) deviceFingerprint is stable across two accesses and a valid UUID.
    func testDeviceFingerprintStableAndValidUUID() {
        let first = store.deviceFingerprint
        let second = store.deviceFingerprint
        XCTAssertEqual(first, second, "fingerprint must be stable across accesses")
        XCTAssertNotNil(UUID(uuidString: first), "fingerprint must be a valid UUID")
    }
}
