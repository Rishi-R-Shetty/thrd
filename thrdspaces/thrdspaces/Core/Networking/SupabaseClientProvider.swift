//
//  SupabaseClientProvider.swift
//  ThrdSpaces — Core/Networking
//
//  Builds the single shared `SupabaseClient` from `Configuration.plist`.
//
//  Only the anon/publishable key ships in the bundle (public by design). The
//  service-role key never appears in this repo or binary — all privileged
//  actions go through Edge Functions (threat-model Layer 1 / Layer 5).
//
//  Sessions are persisted through `KeychainTokenStore`, so every token the
//  SDK writes inherits `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
//

import Foundation
import Supabase

enum SupabaseClientProvider {

    /// The single shared Supabase client. `nonisolated` so both main-actor
    /// views and background repository calls can reach it — `SupabaseClient`
    /// is `Sendable`. Lazily constructed on first access.
    nonisolated static let shared: SupabaseClient = makeClient()

    nonisolated private static func makeClient() -> SupabaseClient {
        guard
            let plistURL = Bundle.main.url(forResource: "Configuration", withExtension: "plist"),
            let config = NSDictionary(contentsOf: plistURL),
            let urlString = config["SupabaseURL"] as? String,
            let supabaseURL = URL(string: urlString),
            let anonKey = config["SupabaseAnonKey"] as? String,
            !anonKey.isEmpty
        else {
            // Fail fast: a missing or malformed Configuration.plist is a
            // build/packaging defect, not a recoverable runtime state.
            preconditionFailure(
                "Configuration.plist is missing or malformed — SupabaseURL and SupabaseAnonKey are required."
            )
        }

        return SupabaseClient(
            supabaseURL: supabaseURL,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: KeychainTokenStore()
                )
            )
        )
    }
}
