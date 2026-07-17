//
//  SpaceClusterAnnotation.swift
//  ThrdSpaces — Features/Discover
//
//  The Discover map, with MapKit annotation clustering (PRD §3 Tab 1: "clustering
//  at low zoom"). This is a UIViewRepresentable over MKMapView on purpose:
//  SwiftUI's `Map` (iOS 18 SDK) has NO clustering API for its Annotation/Marker
//  content — clustering lives only on `MKMapView`, driven by an annotation view's
//  `clusteringIdentifier`. So rather than hand-roll a zoom-aware grouping
//  algorithm in SwiftUI (reinventing what MapKit already does), this screen's map
//  is a thin representable that lets MapKit do the clustering natively.
//
//  It imports MapKit/UIKit, never Supabase — it consumes the `NearbySpace` DTOs
//  the view model already loaded through the repository seam.
//

import MapKit
import SwiftUI
import UIKit

// MARK: - Annotation model

/// A single space pin. Subclassing `MKPointAnnotation` (rather than a bespoke
/// annotation) is what lets MapKit's built-in clustering group these — the pins
/// only need a coordinate plus the `NearbySpace` to render and to report taps.
final class SpaceAnnotation: MKPointAnnotation {
    let space: NearbySpace

    init(space: NearbySpace) {
        self.space = space
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: space.latitude, longitude: space.longitude)
        title = space.name
    }
}

// MARK: - Representable

struct ClusteredSpaceMap: UIViewRepresentable {
    let spaces: [NearbySpace]
    let region: MKCoordinateRegion
    /// Gated to authorized state by the caller — the blue user dot must never
    /// coax the system permission prompt from Discover (the onboarding primer
    /// owns that ask).
    let showsUserLocation: Bool
    let onSelect: (NearbySpace) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll   // our pins are the only POIs
        map.showsUserLocation = showsUserLocation
        map.register(SpaceMarkerView.self,
                     forAnnotationViewWithReuseIdentifier: SpaceMarkerView.reuseID)
        map.register(SpaceClusterView.self,
                     forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        map.setRegion(region, animated: false)
        context.coordinator.appliedCenter = region.center
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.showsUserLocation = showsUserLocation
        // Recenter only when the resolved center actually moved (a new city /
        // first coordinate). Without this guard every SwiftUI re-render would
        // snap the map back and fight the user's own panning between loads.
        if context.coordinator.appliedCenter.map({ !$0.isApproximatelyEqual(to: region.center) }) ?? true {
            map.setRegion(region, animated: true)
            context.coordinator.appliedCenter = region.center
        }
        context.coordinator.sync(spaces: spaces, on: map)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let onSelect: (NearbySpace) -> Void
        var appliedCenter: CLLocationCoordinate2D?

        init(onSelect: @escaping (NearbySpace) -> Void) {
            self.onSelect = onSelect
        }

        /// Diffs the annotation set by space id so pins aren't torn down and
        /// rebuilt (which would drop clusters and flicker) on every reload.
        func sync(spaces: [NearbySpace], on map: MKMapView) {
            let existing = map.annotations.compactMap { $0 as? SpaceAnnotation }
            let existingIDs = Set(existing.map(\.space.id))
            let incomingIDs = Set(spaces.map(\.id))

            let stale = existing.filter { !incomingIDs.contains($0.space.id) }
            map.removeAnnotations(stale)

            let added = spaces
                .filter { !existingIDs.contains($0.id) }
                .map(SpaceAnnotation.init)
            map.addAnnotations(added)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is MKUserLocation:
                return nil // keep MapKit's default blue dot
            case let cluster as MKClusterAnnotation:
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                    for: cluster) as? SpaceClusterView
                view?.configure(with: cluster)
                return view
            case let space as SpaceAnnotation:
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: SpaceMarkerView.reuseID, for: space) as? SpaceMarkerView
                view?.configure(with: space)
                return view
            default:
                return nil
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            switch view.annotation {
            case let space as SpaceAnnotation:
                onSelect(space.space)
                mapView.deselectAnnotation(view.annotation, animated: false)
            case let cluster as MKClusterAnnotation:
                // Tapping a cluster zooms to reveal its members.
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
                mapView.deselectAnnotation(cluster, animated: false)
            default:
                break
            }
        }
    }
}

// MARK: - Marker views

/// A single space marker. Setting `clusteringIdentifier` is what opts these into
/// MapKit's clustering. Carries TD1's accessibility identity — VoiceOver must be
/// able to discover and name each pin, and read it as a button.
final class SpaceMarkerView: MKMarkerAnnotationView {
    static let reuseID = "SpaceMarker"

    override var annotation: MKAnnotation? {
        didSet { applyAppearance() }
    }

    func configure(with annotation: SpaceAnnotation) {
        self.annotation = annotation
    }

    private func applyAppearance() {
        guard let space = (annotation as? SpaceAnnotation)?.space else { return }
        clusteringIdentifier = "space"
        // A marker view defaults to `.required`, which opts OUT of clustering
        // (required pins are always shown individually). Lowering it lets MapKit
        // group overlapping pins into a cluster at low zoom.
        displayPriority = .defaultHigh
        canShowCallout = false
        markerTintColor = UIColor(Theme.terracotta)
        glyphImage = UIImage(systemName: space.category.iconName)
        // TD1: onTapGesture on the old SwiftUI marker conferred no label/trait;
        // the pin now names itself and reads as a button.
        isAccessibilityElement = true
        accessibilityLabel = "\(space.name), \(space.category.displayName)"
        accessibilityTraits = .button
    }
}

/// The cluster bubble. Shows the member count and, per the accessibility guard,
/// announces "N spaces" so VoiceOver conveys the group, not just a number.
final class SpaceClusterView: MKMarkerAnnotationView {
    override var annotation: MKAnnotation? {
        didSet { applyAppearance() }
    }

    func configure(with cluster: MKClusterAnnotation) {
        self.annotation = cluster
    }

    private func applyAppearance() {
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        let count = cluster.memberAnnotations.count
        canShowCallout = false
        markerTintColor = UIColor(Theme.forest)
        glyphText = "\(count)"
        isAccessibilityElement = true
        accessibilityLabel = count == 1 ? "1 space" : "\(count) spaces"
        accessibilityTraits = .button
    }
}

// MARK: - Coordinate compare

private extension CLLocationCoordinate2D {
    /// Cheap equality within ~11 m (5 decimal places) — enough to tell "the
    /// resolved city moved" from "SwiftUI re-rendered with the same center".
    func isApproximatelyEqual(to other: CLLocationCoordinate2D) -> Bool {
        abs(latitude - other.latitude) < 0.0001 && abs(longitude - other.longitude) < 0.0001
    }
}
