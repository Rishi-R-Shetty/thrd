//
//  Geohash5.swift
//  ThrdSpaces — Core/Location
//
//  The single spelling of a geohash-5 cell for the discovery read path (D8).
//  The discover repository accepts a `Geohash5`, never a `String` cell or a raw
//  coordinate, so an unsnapped user coordinate cannot reach the transport by
//  construction — the location-coarsening boundary is enforced at compile time,
//  not just by a server-side re-snap.
//
//  Two inits, and only two:
//   • `init?(cell:)` validates a 5-char geohash-alphabet string (mirrors the
//     server's `assert_geohash5` regex in migration 0003 — a value that passes
//     here passes there).
//   • `init(latitude:longitude:)` snaps a raw coordinate on-device via
//     `LocationManager.geohash`, which clamps precision to 5, so it can only
//     ever yield a valid cell.
//

import Foundation

struct Geohash5: Equatable, Sendable {

    /// A validated 5-character base-32 geohash cell id.
    let cell: String

    /// Validates an already-formed cell string. Fails (returns nil) for any
    /// input that is not exactly five characters of the geohash alphabet
    /// (`0123456789bcdefghjkmnpqrstuvwxyz`) — the same rejection the server
    /// enforces with SQLSTATE 22023, applied here first so a bad cell never
    /// leaves the device. `nonisolated`: pure string validation, no actor state.
    nonisolated init?(cell: String) {
        // Kept as a local literal (not a static) so this init stays free of any
        // actor-isolated stored state and is callable from any context.
        let geohash5Pattern = "^[0123456789bcdefghjkmnpqrstuvwxyz]{5}$"
        guard cell.range(of: geohash5Pattern, options: .regularExpression) != nil else {
            return nil
        }
        self.cell = cell
    }

    /// Snaps a raw coordinate to its geohash-5 cell on-device. Delegates to
    /// `LocationManager.geohash`, the app's single geohash implementation, which
    /// clamps precision to 5 (the location-minimization cap, threat-model Layer
    /// 7) — so the result is always a valid cell and never finer than a cell.
    init(latitude: Double, longitude: Double) {
        cell = LocationManager.geohash(latitude: latitude, longitude: longitude, precision: 5)
    }
}
