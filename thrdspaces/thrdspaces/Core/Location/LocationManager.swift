//
//  LocationManager.swift
//  ThrdSpaces — Core/Location
//
//  When-In-Use authorization only, reduced accuracy by default. This class
//  never persists a coordinate to disk or sends one over the network — it
//  only publishes state for views to read. Callers must invoke
//  `requestPermission()` explicitly after the onboarding primer has shown
//  the user why we're asking; the system prompt never appears on init.
//
//  Threat model Layer 7 (location minimization): home geohash is capped at
//  precision 5 (~2.4km) everywhere in this app. See `geohash(...)` below.
//

import Combine
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    /// Current system authorization state for When-In-Use location.
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    /// Latest coarse coordinate, nil until authorized and a fix arrives.
    /// Never written to UserDefaults, disk, or a network call by this class.
    @Published private(set) var coarseCoordinate: CLLocationCoordinate2D?

    private let manager: CLLocationManager

    override init() {
        manager = CLLocationManager()
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Reduced accuracy by default — we only ever need a geohash-5
        // neighborhood, never a precise fix. No full-accuracy request exists
        // anywhere in this class.
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    /// Shows the system When-In-Use permission prompt. The onboarding value
    /// primer (T6) must be shown before this is called — never call this
    /// automatically.
    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coarseCoordinate = locations.last?.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // ponytail: errors surface only as "no coordinate available" — T9's
        // Discover empty state already handles denied/missing location
        // uniformly, so a distinct error state isn't worth the complexity
        // yet. Upgrade if product wants a "location temporarily unavailable"
        // message distinct from "permission denied".
    }

    /// Standard base-32 geohash encoding, capped at precision 5 (~2.4km) —
    /// the privacy guard for `users.home_geohash`. Any caller requesting a
    /// finer precision is silently clamped; there is no path in this app
    /// that should ever produce a more precise geohash client-side.
    static func geohash(latitude: Double, longitude: Double, precision: Int) -> String {
        let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")
        let clampedPrecision = min(max(precision, 1), 5)

        var latRange = (min: -90.0, max: 90.0)
        var lonRange = (min: -180.0, max: 180.0)
        var isEvenBit = true
        var bitIndex = 0
        var charValue = 0
        var hash = ""

        while hash.count < clampedPrecision {
            if isEvenBit {
                let mid = (lonRange.min + lonRange.max) / 2
                if longitude >= mid {
                    charValue = (charValue << 1) | 1
                    lonRange.min = mid
                } else {
                    charValue = charValue << 1
                    lonRange.max = mid
                }
            } else {
                let mid = (latRange.min + latRange.max) / 2
                if latitude >= mid {
                    charValue = (charValue << 1) | 1
                    latRange.min = mid
                } else {
                    charValue = charValue << 1
                    latRange.max = mid
                }
            }
            isEvenBit.toggle()
            bitIndex += 1

            if bitIndex == 5 {
                hash.append(base32[charValue])
                bitIndex = 0
                charValue = 0
            }
        }

        return hash
    }
}
