//
//  DiscoverView.swift
//  ThrdSpaces — Features/Discover
//
//  The Discover screen (PRD §3 Tab 1): a clustered MapKit map (default) with
//  Today · This Week · Free · category pill filters and the "Near you now"
//  bottom sheet, plus a List toggle showing distance-ranked event cards. Fed by
//  the live SupabaseDiscoverRepository through the view model (previews inject
//  the mock). Views never reach Supabase directly — the repository seam is the
//  only backend toucher in this feature.
//

import CoreLocation
import MapKit
import SwiftUI
import UIKit

// MARK: - Discover Screen

enum DiscoverViewMode: Hashable { case map, list }

struct DiscoverView: View {
    @StateObject private var viewModel: DiscoverViewModel
    @State private var viewMode: DiscoverViewMode
    @State private var sheetDetent: PresentationDetent = .fraction(0.35)

    /// Accepts a pre-built view model so previews/tests can seed state (e.g.
    /// a denied authorization status) without depending on live simulator
    /// permission state. `initialViewMode` is likewise a preview/test seam.
    /// Production call sites use the defaults (`nil` deferred to
    /// `DiscoverViewModel()` inside the initializer body, since that init is
    /// MainActor-isolated and default argument expressions are not).
    init(viewModel: DiscoverViewModel? = nil, initialViewMode: DiscoverViewMode = .map) {
        _viewModel = StateObject(wrappedValue: viewModel ?? DiscoverViewModel())
        _viewMode = State(initialValue: initialViewMode)
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLocationDenied {
                    LocationDeniedView()
                } else {
                    VStack(spacing: 0) {
                        filterHeader
                        switch viewMode {
                        case .map: mapContent
                        case .list: listContent
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await viewModel.load() }
            // Map-marker selection pushes Space Detail onto the main stack.
            // `isPresented` avoids requiring Hashable on the NearbySpace model.
            .navigationDestination(isPresented: Binding(
                get: { viewModel.selectedSpace != nil },
                set: { if !$0 { viewModel.selectedSpace = nil } }
            )) {
                if let space = viewModel.selectedSpace {
                    SpaceDetailView(space: space)
                }
            }
        }
    }

    /// Resolves an event's venue to a loaded `NearbySpace` (same nearby query),
    /// so Event Detail can show the venue's name/address and drill into Space
    /// Detail. Nil when the venue isn't in the current set — Event Detail then
    /// falls back to the event's denormalized `venueName`.
    private func venueSpace(for event: NearbyEvent) -> NearbySpace? {
        viewModel.spaces.first { $0.id == event.spaceId }
    }

    // MARK: Filter header (toggle + pills)

    private static let eventFilterItems: [ChipItem] = [
        ChipItem(id: EventFilter.today.id, label: EventFilter.today.label, systemImage: "sun.max"),
        ChipItem(id: EventFilter.thisWeek.id, label: EventFilter.thisWeek.label, systemImage: "calendar"),
        ChipItem(id: EventFilter.free.id, label: EventFilter.free.label, systemImage: "gift"),
    ]

    // The catch-all `.other` is excluded from the filter chips (its label,
    // "Space", reads as "everything"); filteredSpaces still shows `.other`
    // venues whenever no category chip is selected.
    private static let categoryItems: [ChipItem] = SpaceCategory.allCases
        .filter { $0 != .other }
        .map { ChipItem(id: $0.rawValue, label: $0.displayName, systemImage: $0.iconName) }

    private var filterHeader: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Picker("View", selection: $viewMode) {
                Text("Map").tag(DiscoverViewMode.map)
                Text("List").tag(DiscoverViewMode.list)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Discover view mode")

            ChipGroup(items: Self.eventFilterItems, selection: $viewModel.activeEventFilterIDs)

            if viewMode == .map {
                // Category chips gate the map's space markers (category is a
                // Space attribute; events carry none), so they ride with the map.
                ChipGroup(items: Self.categoryItems, selection: $viewModel.selectedCategoryIDs)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.sm)
        .background(Theme.cream)
    }

    // MARK: Map

    private var mapContent: some View {
        ClusteredSpaceMap(spaces: viewModel.filteredSpaces,
                          region: viewModel.region,
                          showsUserLocation: viewModel.showsUserLocation,
                          onSelect: { viewModel.selectedSpace = $0 })
            .ignoresSafeArea(.container, edges: .bottom)
            .overlay { firstLoadOverlay(hasData: !viewModel.spaces.isEmpty) }
            .sheet(isPresented: .constant(true)) {
                NearYouSheet(events: viewModel.rankedEvents, venueSpace: venueSpace,
                             ticketStatus: viewModel.ticketStatus(for:))
                    .presentationDetents([.fraction(0.35), .medium, .large],
                                         selection: $sheetDetent)
                    .presentationBackgroundInteraction(.enabled)
                    .interactiveDismissDisabled()
            }
    }

    // MARK: List

    private var listContent: some View {
        Group {
            if viewModel.rankedEvents.isEmpty {
                firstLoadOverlay(hasData: false, emptyFallback: AnyView(EmptyEventsView()))
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.md) {
                        ForEach(viewModel.rankedEvents) { event in
                            NavigationLink {
                                EventDetailView(event: event, venueSpace: venueSpace(for: event))
                            } label: {
                                RankedEventCard(event: event,
                                                ticketStatus: viewModel.ticketStatus(for: event))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Theme.Spacing.md)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cream)
    }

    /// The shared first-load treatment: a spinner while the initial fetch is in
    /// flight, a retryable error if it failed, otherwise `emptyFallback` (a real
    /// empty state for the list; nothing over the map, whose pins are the state).
    @ViewBuilder
    private func firstLoadOverlay(hasData: Bool, emptyFallback: AnyView? = nil) -> some View {
        if hasData {
            EmptyView()
        } else if viewModel.isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading nearby spaces")
        } else if viewModel.loadError {
            LoadErrorView { Task { await viewModel.load() } }
        } else if let emptyFallback {
            emptyFallback
        } else {
            EmptyView()
        }
    }
}

// MARK: - SpaceCategory UI affordances (D10: features extend model enums)

// The canonical `SpaceCategory` (Models/Space.swift) carries no presentation.
// Discover needs a map-marker glyph and a spoken label per case; this extension
// re-homes the glyph/label the old mock category type used to provide. It is a
// UI affordance on a model enum, so per D10 it lives in the feature layer, not
// on the model — and it is exhaustive over the SQL enum (including `.other`).
extension SpaceCategory {
    var iconName: String {
        switch self {
        case .cafe: "cup.and.saucer.fill"
        case .park: "leaf.fill"
        case .studio: "paintpalette.fill"
        case .venue: "building.columns.fill"
        case .other: "mappin.circle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .cafe: "Cafe"
        case .park: "Park"
        case .studio: "Studio"
        case .venue: "Venue"
        case .other: "Space"
        }
    }
}

// MARK: - Location-denied empty state

struct LocationDeniedView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.forest)
                .accessibilityHidden(true)
            Text("Turn on location to find spaces near you")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(Theme.Typography.button)
            .buttonStyle(.borderedProminent)
            .tint(Theme.forest)
            .accessibilityLabel("Open Settings to turn on location access")
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cream)
    }
}

// MARK: - Load error / empty states

struct LoadErrorView: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.forest)
                .accessibilityHidden(true)
            Text("Couldn't load nearby spaces")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .font(Theme.Typography.button)
                .buttonStyle(.borderedProminent)
                .tint(Theme.forest)
                .accessibilityLabel("Try loading nearby spaces again")
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cream)
    }
}

struct EmptyEventsView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.forest)
                .accessibilityHidden(true)
            Text("No events match your filters")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cream)
    }
}

// MARK: - Bottom Sheet ("Near you now")

struct NearYouSheet: View {
    let events: [NearbyEvent]
    /// Resolves an event's venue to a loaded space for the pushed Event Detail.
    let venueSpace: (NearbyEvent) -> NearbySpace?
    /// The caller's own ticket status for an event, if any (drives "your spot").
    let ticketStatus: (NearbyEvent) -> TicketStatus?

    var body: some View {
        // Own NavigationStack so a tapped card pushes Event Detail within the
        // sheet (Apple-Maps-style place drill-in), independent of the main stack.
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Near you now")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 8)

                    if events.isEmpty {
                        Text("No events match your filters")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    } else {
                        ForEach(events) { event in
                            NavigationLink {
                                EventDetailView(event: event, venueSpace: venueSpace(event))
                            } label: {
                                EventCard(event: event, ticketStatus: ticketStatus(event))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .background(Theme.cream)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// The compact card in the "Near you now" sheet — informational; tapping it
/// pushes Event Detail (which owns RSVP from T17). No inline RSVP control, so the
/// whole card is a single navigation target with no nested-button tap conflict.
struct EventCard: View {
    let event: NearbyEvent
    /// The caller's own ticket status for this event, if any — nil hides the
    /// "your spot" badge.
    var ticketStatus: TicketStatus? = nil

    var body: some View {
        HStack(spacing: 14) {
            // ponytail: a single generic glyph — NearbyEvent carries no
            // category/interest tag, so there is nothing to derive a per-event
            // icon from yet. Upgrade to a tag-derived glyph when Events adopt an
            // interest tag.
            Image(systemName: "calendar")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.terracotta)
                .frame(width: 52, height: 52)
                .background(Theme.terracotta.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(event.title)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    if let ticketStatus { YourSpotBadge(status: ticketStatus) }
                }
                Text("\(event.venueName) · \(event.startsAt.formatted(.relative(presentation: .named)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(event.rsvpCount) going\(event.price == 0 ? " · Free" : "")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.forest)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title)\(YourSpotBadge.accessibilitySuffix(ticketStatus)), at \(event.venueName), \(event.startsAt.formatted(.relative(presentation: .named))), \(event.rsvpCount) going")
        .accessibilityHint("Opens event details")
    }
}

// MARK: - Ranked list card

/// The List-view card: a photo placeholder block, title, venue + distance, time,
/// and price/free. Informational — tapping pushes Event Detail (which owns RSVP
/// from T17), so there is no inline RSVP control to conflict with the tap.
struct RankedEventCard: View {
    let event: NearbyEvent
    /// The caller's own ticket status for this event, if any — nil hides the
    /// "your spot" badge.
    var ticketStatus: TicketStatus? = nil

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Photo placeholder — cover images are a later concern (no image
            // loading this task), so a neutral block stands in for the cover.
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(Theme.forest.opacity(0.12))
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.forest.opacity(0.5))
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(event.title)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    if let ticketStatus { YourSpotBadge(status: ticketStatus) }
                }
                Text("\(event.venueName) · \(Self.distanceText(event.distanceMeters))")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(event.startsAt.formatted(.relative(presentation: .named))) · \(Self.priceText(event.price))")
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
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title)\(YourSpotBadge.accessibilitySuffix(ticketStatus)), at \(event.venueName), \(Self.distanceText(event.distanceMeters)) away, \(event.startsAt.formatted(.relative(presentation: .named))), \(Self.priceText(event.price))")
        .accessibilityHint("Opens event details")
    }

    /// Locale-aware distance ("850 m" / "1.2 km") via Foundation's
    /// `MeasurementFormatter` — `.naturalScale` promotes metres to kilometres on
    /// its own, so there is no hand-rolled km/m helper.
    private static let distanceFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter
    }()

    static func distanceText(_ meters: Int) -> String {
        distanceFormatter.string(from: Measurement(value: Double(meters), unit: UnitLength.meters))
    }

    /// "Free" for a zero price, else the formatted amount.
    static func priceText(_ minorUnits: Int) -> String {
        guard minorUnits > 0 else { return "Free" }
        // ponytail: INR hardcoded — both launch cities are Indian (D6) and Event
        // has no currency column. Upgrade when a non-INR market launches or the
        // schema gains a per-event currency.
        return (Double(minorUnits) / 100.0).formatted(.currency(code: "INR"))
    }
}

// MARK: - "Your spot" badge (T17)

/// A compact pill shown on an event card when the caller holds an active ticket
/// — read-only social proof of the RSVP made on Event Detail. Visually hidden
/// from VoiceOver (the parent card folds it into its combined label via
/// `accessibilitySuffix`) so the badge is announced once, in context.
struct YourSpotBadge: View {
    let status: TicketStatus

    var body: some View {
        Text(Self.label(for: status))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Self.tint(for: status).opacity(0.15), in: Capsule())
            .foregroundStyle(Self.tint(for: status))
            .accessibilityHidden(true)
    }

    /// "Going" for a going ticket, "Waitlisted" for a waitlist ticket. Any other
    /// status never reaches here (`ownActiveTickets` returns only those two).
    static func label(for status: TicketStatus) -> String {
        status == .waitlist ? "Waitlisted" : "Going"
    }

    static func tint(for status: TicketStatus) -> Color {
        status == .waitlist ? Theme.terracotta : Theme.forest
    }

    /// The clause the card appends to its combined accessibility label, e.g.
    /// ", your spot: Going". Empty when the caller holds no ticket.
    static func accessibilitySuffix(_ status: TicketStatus?) -> String {
        status.map { ", your spot: \(label(for: $0))" } ?? ""
    }
}

// MARK: - Previews

#Preview("Discover · Map") {
    DiscoverView(viewModel: DiscoverViewModel(repository: MockDiscoverRepository(),
                                              initialAuthorizationStatus: .authorizedWhenInUse))
}

#Preview("Discover · List") {
    DiscoverView(viewModel: DiscoverViewModel(repository: MockDiscoverRepository(),
                                              initialAuthorizationStatus: .authorizedWhenInUse),
                 initialViewMode: .list)
}

#Preview("Discover · List — Free filter") {
    let vm = DiscoverViewModel(repository: MockDiscoverRepository(),
                               initialAuthorizationStatus: .authorizedWhenInUse)
    vm.activeEventFilterIDs = ["free"]
    return DiscoverView(viewModel: vm, initialViewMode: .list)
}

#Preview("Location denied") {
    DiscoverView(viewModel: DiscoverViewModel(initialAuthorizationStatus: .denied))
}
