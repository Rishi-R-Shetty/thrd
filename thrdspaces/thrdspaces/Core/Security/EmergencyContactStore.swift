//
//  EmergencyContactStore.swift
//  ThrdSpaces — Core/Security
//
//  Device-local store for the user's emergency contact (name + phone), used by
//  the panic flow (T19). Decision D9 — NON-NEGOTIABLE: this contact lives ONLY
//  in the device Keychain. It is never synced, never written to Postgres, and
//  never placed in any network request. The panic flow reads it purely on-device
//  to pre-fill an SMS (`sms:` URL) alongside a dial to the local emergency
//  number. If this value ever appears in a URL query to a server, a request
//  body, or a Supabase call, that is a D9 violation.
//
//  Storage reuses `KeychainTokenStore`'s generic-password primitives verbatim,
//  so the contact inherits the exact same non-negotiable accessibility class
//  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`): device-only, unlock-
//  required, never migrated to a backup or another device. A distinct service
//  namespace keeps it from colliding with auth items.
//

import Foundation

/// The trusted contact reached by the panic flow. Codable only for local JSON
/// (de)serialization into the Keychain — deliberately NOT sent over the wire.
struct EmergencyContact: Codable, Equatable {
    /// Display name (e.g. "Mum", "Aisha"). Local-only, never shown to other users.
    var name: String
    /// A dialable/SMS-able phone string as the user entered it.
    var phone: String
}

/// Keychain-backed store for the single emergency contact. Reuses
/// `KeychainTokenStore` rather than re-issuing `SecItem*` calls, so the
/// accessibility guarantee is defined in exactly one place.
struct EmergencyContactStore {

    /// The generic-password account key. Named as a grep target: the D9 exit
    /// condition greps for `emergency_contact` and must find it only here and in
    /// local UI usage — never in a network path.
    static let key = "emergency_contact"

    private let keychain: KeychainTokenStore

    /// A dedicated service namespace (separate from the auth store) so the
    /// contact item can't collide with a token item on the same account key.
    init(keychain: KeychainTokenStore = KeychainTokenStore(service: "thrd.thrdspaces.safety")) {
        self.keychain = keychain
    }

    /// The stored contact, or nil when none has been set (or on a decode/read
    /// failure — the caller then treats the user as having no contact yet).
    func load() -> EmergencyContact? {
        guard
            let data = (try? keychain.retrieve(key: Self.key)) ?? nil,
            let contact = try? JSONDecoder().decode(EmergencyContact.self, from: data)
        else { return nil }
        return contact
    }

    /// Upserts the contact into the Keychain. Trims whitespace; the caller is
    /// responsible for having validated non-empty fields (see `EmergencyContactView`).
    func save(_ contact: EmergencyContact) throws {
        let trimmed = EmergencyContact(
            name: contact.name.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: contact.phone.trimmingCharacters(in: .whitespacesAndNewlines))
        let data = try JSONEncoder().encode(trimmed)
        try keychain.store(key: Self.key, value: data)
    }

    /// Removes the contact from the Keychain.
    func clear() throws {
        try keychain.remove(key: Self.key)
    }
}
