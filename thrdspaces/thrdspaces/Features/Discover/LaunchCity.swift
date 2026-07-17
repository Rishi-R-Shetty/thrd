//
//  LaunchCity.swift
//  ThrdSpaces — Features/Discover
//
//  The two launch cities (D6). Discover defaults its map/data region to the
//  nearest of these to the user's last coarse location, then falls back down a
//  chain: coordinate → device locale → Bengaluru (the original launch city and
//  terminal fallback). This replaces T9's single `DiscoverViewModel.defaultCity`
//  constant (TD2) — the launch-city coordinates now live in exactly one place.
//
//  Pure value logic, no actor state — unit-testable without CoreLocation
//  permissions (great-circle distance is a stdlib computation, not a live fix).
//

import CoreLocation

enum LaunchCity: CaseIterable {
    case bengaluru, mumbai

    /// Exact city-center coordinate. Modeled as `CLLocationCoordinate2D` rather
    /// than a bare `(lat, lng)` tuple because every consumer already speaks
    /// CoreLocation — the map camera reads a coordinate and `nearest(to:)`'s
    /// distance math needs a `CLLocation` — so a tuple would only get unpacked.
    var center: CLLocationCoordinate2D {
        switch self {
        case .bengaluru: CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        case .mumbai:    CLLocationCoordinate2D(latitude: 19.0760, longitude: 72.8777)
        }
    }

    var displayName: String {
        switch self {
        case .bengaluru: "Bengaluru"
        case .mumbai:    "Mumbai"
        }
    }

    /// The geohash-5 cell of the city center — the query cell used when no
    /// on-device coordinate is available yet. Derived through the app's single
    /// geohash spelling (`Geohash5`), so a city-fallback query is snapped
    /// identically to a real user-location query (D8).
    var geohash5: Geohash5 {
        Geohash5(latitude: center.latitude, longitude: center.longitude)
    }

    /// Nearest launch city to `coordinate` by great-circle distance. `nil`
    /// (location indeterminate) resolves to the terminal fallback.
    static func nearest(to coordinate: CLLocationCoordinate2D?) -> LaunchCity {
        guard let coordinate else {
            // ponytail: D6's "fall back to device locale" tier is a deliberate
            // no-op while both launch cities sit in the same country —
            // `Locale.current.region` is country-level (both resolve to "IN")
            // and cannot discriminate Bengaluru from Mumbai, so the chain
            // collapses to the terminal fallback. Wire a real locale check here
            // only when a launch city in another region is added.
            return .bengaluru
        }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        func distance(_ city: LaunchCity) -> CLLocationDistance {
            CLLocation(latitude: city.center.latitude, longitude: city.center.longitude)
                .distance(from: target)
        }
        // `min(by:)` over a non-empty CaseIterable; the `?? .bengaluru` is an
        // unreachable safety net for the empty case the compiler can't prove away.
        return allCases.min { distance($0) < distance($1) } ?? .bengaluru
    }
}
