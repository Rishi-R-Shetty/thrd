//
//  SpaceDetailView.swift
//  ThrdSpaces — Features/Discover
//
//  Space Detail (PRD §3): a venue's photos (placeholder blocks — no image
//  loading this phase, D2), name/category/address, a static map snippet on the
//  venue's EXACT coordinates (D8 sanctions exact venue pins — coarsening is a
//  user-side concern), hours, amenities, the public communities that meet here,
//  and its upcoming events (each pushing Event Detail). Fed by the mock in
//  previews/tests and the live repository in production — this view never
//  touches Supabase directly.
//

import CoreLocation
import MapKit
import SwiftUI

struct SpaceDetailView: View {
    @StateObject private var viewModel: SpaceDetailViewModel

    init(space: NearbySpace, repository: DiscoverRepository? = nil) {
        _viewModel = StateObject(wrappedValue: repository.map { SpaceDetailViewModel(space: space, repository: $0) }
            ?? SpaceDetailViewModel(space: space))
    }

    private var space: NearbySpace { viewModel.space }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                photoStrip
                header
                VenueMapSnippet(coordinate: CLLocationCoordinate2D(latitude: space.latitude,
                                                                   longitude: space.longitude),
                                title: space.name)
                if !space.amenities.isEmpty { amenities }
                hours
                communitiesSection
                eventsSection
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.cream)
        .navigationTitle(space.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    // MARK: Photos (placeholder blocks — no image loading, D2)

    private var photoStrip: some View {
        // One neutral block per listed photo (at least one), standing in for the
        // cover imagery until the CSAM-gated image path lands (D2). Decorative.
        let count = max(space.photos.count, 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .fill(Theme.forest.opacity(0.12))
                        .frame(width: 240, height: 150)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(Theme.forest.opacity(0.5))
                        }
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(space.category.displayName, systemImage: space.category.iconName)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.forest)
                .accessibilityLabel("Category: \(space.category.displayName)")

            Text(space.name)
                .font(Theme.Typography.largeTitle)
                .foregroundStyle(Theme.ink)

            Label(space.address, systemImage: "mappin.and.ellipse")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Address: \(space.address)")
        }
    }

    // MARK: Amenities

    private var amenities: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionTitle("Amenities")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.xs)],
                      alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(space.amenities, id: \.self) { amenity in
                    Text(amenity.capitalized)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, Theme.Spacing.md)
                        .frame(minHeight: 36)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.15), lineWidth: 1))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Amenities: \(space.amenities.map { $0.capitalized }.joined(separator: ", "))")
        }
    }

    // MARK: Hours

    @ViewBuilder
    private var hours: some View {
        let lines = Self.hoursLines(space.hours)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionTitle("Hours")
            if lines.isEmpty {
                Text("Hours not listed")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }

    // MARK: Communities

    @ViewBuilder
    private var communitiesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionTitle("Communities that meet here")
            if viewModel.isLoading && viewModel.communities.isEmpty {
                loadingRow(label: "Loading communities")
            } else if viewModel.communitiesError {
                retryRow
            } else if viewModel.communities.isEmpty {
                emptyRow("No communities meet here yet")
            } else {
                ForEach(viewModel.communities) { community in
                    CommunityRow(community: community)
                }
            }
        }
    }

    // MARK: Upcoming events

    @ViewBuilder
    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionTitle("Upcoming events")
            if viewModel.isLoading && viewModel.upcomingEvents.isEmpty {
                loadingRow(label: "Loading events")
            } else if viewModel.eventsError {
                retryRow
            } else if viewModel.upcomingEvents.isEmpty {
                emptyRow("No upcoming events")
            } else {
                ForEach(viewModel.upcomingEvents) { event in
                    NavigationLink {
                        EventDetailView(event: viewModel.nearbyEvent(for: event), venueSpace: space)
                    } label: {
                        SpaceEventRow(event: event)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Shared bits

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.title)
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func loadingRow(label: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            ProgressView()
            Text(label).font(Theme.Typography.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.subheadline)
            .foregroundStyle(.secondary)
    }

    private var retryRow: some View {
        Button("Couldn't load. Try again.") { Task { await viewModel.load() } }
            .font(Theme.Typography.button)
            .buttonStyle(.bordered)
            .tint(Theme.forest)
            .accessibilityLabel("Couldn't load this section. Try again.")
    }

    /// Flattens a `spaces.hours` jsonb (an object of day → text) into display
    /// lines. Only string values are rendered; anything else is skipped — the
    /// column has no fixed shape pinned by the schema, so this stays defensive.
    static func hoursLines(_ hours: JSONValue?) -> [String] {
        guard case let .object(dict)? = hours else { return [] }
        return dict.sorted { $0.key < $1.key }.compactMap { key, value in
            if case let .string(text) = value { return "\(key.capitalized): \(text)" }
            return nil
        }
    }
}

// MARK: - Static venue map snippet (reused by Event Detail)

/// A small non-interactive map centred on a venue's EXACT coordinates. Venue
/// pins are public places, so exactness is sanctioned (D8) — the coarsening
/// guard applies to USER location, never to venues. Hit-testing is disabled so
/// it reads as a snippet, not a pannable map.
struct VenueMapSnippet: View {
    let coordinate: CLLocationCoordinate2D
    let title: String

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)))) {
            Marker(title, coordinate: coordinate)
                .tint(Theme.terracotta)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Map showing the location of \(title)")
    }
}

// MARK: - Rows

private struct CommunityRow: View {
    let community: Community

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.terracotta)
                .frame(width: 44, height: 44)
                .background(Theme.terracotta.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(community.name)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.ink)
                Text("\(community.memberCount) members")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.forest)
            }
            Spacer()
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(community.name), \(community.memberCount) members")
    }
}

private struct SpaceEventRow: View {
    let event: Event

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(Theme.forest.opacity(0.12))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "calendar")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.forest.opacity(0.6))
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(event.title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text("\(event.startsAt.formatted(.relative(presentation: .named))) · \(RankedEventCard.priceText(event.price))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.forest)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(event.startsAt.formatted(.relative(presentation: .named))), \(RankedEventCard.priceText(event.price))")
        .accessibilityHint("Opens event details")
    }
}

// MARK: - Previews

#Preview("Space Detail") {
    NavigationStack {
        SpaceDetailView(
            space: NearbySpace(
                id: UUID(), ownerUserId: nil, name: "Third Wave Coffee, Indiranagar",
                category: .cafe, latitude: 12.9719, longitude: 77.6412,
                address: "100 Feet Rd, Indiranagar, Bengaluru", photos: ["a", "b"],
                amenities: ["wifi", "outdoor", "books"], hours: nil, capacity: 40,
                isPartner: true, ratingAgg: nil, createdAt: .now,
                distanceMeters: 5010, upcomingEventCount: 2),
            repository: MockDiscoverRepository())
    }
}
