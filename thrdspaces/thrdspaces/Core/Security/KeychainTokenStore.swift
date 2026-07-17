//
//  KeychainTokenStore.swift
//  ThrdSpaces — Core/Security
//
//  Generic-password Keychain store for auth tokens and the device
//  fingerprint. EVERY item is written with
//  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — a non-negotiable guard
//  (threat-model Layer 1): tokens are readable only while the device is
//  unlocked and never migrate to a backup or another device.
//
//  Why a custom store instead of the SDK's built-in keychain storage:
//  the Supabase SDK's default `AuthLocalStorage` implementation writes with
//  an accessibility class we don't control. By conforming THIS store to
//  `AuthLocalStorage` and injecting it into the client, every SDK-managed
//  session (access token 1h / refresh token 30d — TTLs are server-defined)
//  lands in our keychain with our accessibility guarantee, not the SDK's.
//

import Foundation
import Security
import Supabase // re-exports Auth, where `AuthLocalStorage` is declared

struct KeychainTokenStore {

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    /// Namespacing service for every generic-password item this store owns.
    private let service: String

    init(service: String = "thrd.thrdspaces.auth") {
        self.service = service
    }

    // MARK: - Generic-password primitives

    /// Upsert. Deletes any existing item first so the accessibility class is
    /// re-asserted on every write — an item can't be silently left with a
    /// weaker `kSecAttrAccessible` from a prior code path.
    func store(key: String, value: Data) throws {
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(matchQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: value,
            // Non-negotiable guard: device-only, unlock-required.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func retrieve(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func remove(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Device fingerprint

    private static let deviceFingerprintKey = "device_fingerprint"

    /// A stable per-install identifier for device binding (threat-model
    /// Layer 2). Generated on first access and persisted in the keychain —
    /// deliberately a random `UUID`, NEVER a hardware identifier
    /// (`identifierForVendor`, IDFA, etc.), so it can't be used to
    /// cross-correlate the user across apps or vendors.
    var deviceFingerprint: String {
        if let data = try? retrieve(key: Self.deviceFingerprintKey),
           let existing = String(data: data, encoding: .utf8) {
            return existing
        }
        let generated = UUID().uuidString
        // ponytail: best-effort persist — if the keychain write fails we
        // return a fresh UUID this launch rather than surfacing an error to
        // callers. Device binding degrades to "unrecognized device" on the
        // next launch, which fails safe (re-auth prompt). Upgrade to a
        // throwing accessor if binding becomes a hard security dependency.
        try? store(key: Self.deviceFingerprintKey, value: Data(generated.utf8))
        return generated
    }
}

// `AuthLocalStorage` requires exactly `store(key:value:)`, `retrieve(key:)`,
// and `remove(key:)` with these signatures — the primitives above satisfy it
// directly, so the SDK persists sessions through our guarded keychain.
extension KeychainTokenStore: AuthLocalStorage {}
