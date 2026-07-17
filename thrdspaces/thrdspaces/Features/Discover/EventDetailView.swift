//
//  EventDetailView.swift
//  ThrdSpaces — Features/Discover
//
//  Event Detail (PRD §3): cover placeholder (no image loading, D2), title /
//  time / price, description, the host's public profile with a ⋯ menu mounting
//  the reusable Report + Block flows (subject = host user id; T7a re-mount), a
//  static venue snippet that drills into Space Detail, and the attendee-preview
//  strip (first names + initials only — no handles, no last names, per the
//  attendee-list-privacy guard). The RSVP CTA is a disabled stub until T17.
//

import CoreLocation
import SwiftUI

struct EventDetailView: View {
    @StateObject private var viewModel: EventDetailViewModel

    @State private var showReport = false
    @State private var showBlockConfirm = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(event: NearbyEvent, venueSpace: NearbySpace? = nil, repository: DiscoverRepository? = nil) {
        _viewModel = StateObject(wrappedValue: repository.map {
            EventDetailViewModel(event: event, venueSpace: venueSpace, repository: $0)
        } ?? EventDetailViewModel(event: event, venueSpace: venueSpace))
    }

    private var event: NearbyEvent { viewModel.event }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                coverPlaceholder
                headline
                if let description = event.description, !description.isEmpty {
                    Text(description)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.ink)
                }
                hostSection
                venueSection
                attendeeSection
                rsvpSection
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.cream)
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .sheet(isPresented: $showReport) {
            // Subject is the host user id — available from the event even before
            // the host profile finishes loading, so Report is always reachable.
            ReportSheetView(subjectID: event.hostId,
                            subjectName: viewModel.host.map { "@\($0.handle)" })
        }
        .confirmationDialog("Block this host?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await viewModel.blockHost() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They won't be able to see you or contact you, and you won't see them.")
        }
        .alert("Done", isPresented: Binding(
            get: { viewModel.actionMessage != nil },
            set: { if !$0 { viewModel.actionMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.actionMessage = nil }
        } message: {
            Text(viewModel.actionMessage ?? "")
        }
        .alert("RSVP", isPresented: Binding(
            get: { viewModel.rsvpErrorMessage != nil },
            set: { if !$0 { viewModel.rsvpErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.rsvpErrorMessage = nil }
        } message: {
            Text(viewModel.rsvpErrorMessage ?? "")
        }
    }

    // MARK: Cover (placeholder — no image loading, D2)

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.medium)
            .fill(Theme.terracotta.opacity(0.12))
            .frame(height: 180)
            .overlay {
                Image(systemName: "calendar")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.terracotta.opacity(0.6))
            }
            .accessibilityHidden(true)
    }

    // MARK: Headline (title / time / price)

    private var headline: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(event.title)
                .font(Theme.Typography.largeTitle)
                .foregroundStyle(Theme.ink)

            Label(Self.timeText(start: event.startsAt, end: event.endsAt), systemImage: "clock")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Time: \(Self.timeText(start: event.startsAt, end: event.endsAt))")

            Label(RankedEventCard.priceText(event.price), systemImage: "indianrupeesign.circle")
                .font(Theme.Typography.subheadline.weight(.semibold))
                .foregroundStyle(Theme.forest)
                .accessibilityLabel("Price: \(RankedEventCard.priceText(event.price))")
        }
    }

    // MARK: Host

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionTitle("Hosted by")
            HStack(spacing: Theme.Spacing.sm) {
                if let host = viewModel.host {
                    InitialsAvatar(profile: host.asProfileSummary, diameter: 48)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(host.displayName)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.ink)
                        Text("@\(host.handle)")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Hosted by \(host.displayName), handle @\(host.handle)")
                } else {
                    Circle().fill(Theme.forest.opacity(0.12)).frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    Text(viewModel.isLoading ? "Loading host…" : "Host unavailable")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                hostMenu
            }
        }
    }

    // The ⋯ menu: Report + Block both one tap deep from here (menu = tap 1,
    // action = tap 2), satisfying the ≤2-tap reporting requirement. Subject is
    // the host user id regardless of whether the profile row has loaded.
    private var hostMenu: some View {
        Menu {
            Button { showReport = true } label: { Label("Report", systemImage: "flag") }
            Button(role: .destructive) { showBlockConfirm = true } label: {
                Label("Block", systemImage: "hand.raised")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(Theme.forest)
        }
        .accessibilityLabel("More actions for the host")
    }

    // MARK: Venue

    @ViewBuilder
    private var venueSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionTitle("Where")
            if let space = viewModel.venueSpace {
                // Resolved venue → tappable drill-in with name + address.
                NavigationLink { SpaceDetailView(space: space) } label: {
                    venueSnippet(name: space.name, address: space.address,
                                 latitude: space.latitude, longitude: space.longitude,
                                 showsChevron: true)
                }
                .buttonStyle(.plain)
            } else {
                // ponytail: unresolved venue (not in the loaded nearby set) — show
                // the event's denormalized venue name + map, no drill-in and no
                // address (NearbyEvent carries neither an address nor the full
                // space). Rare in practice: an event's venue is a nearby space.
                // Upgrade with a space(id:) fetch if standalone Event Detail
                // deep-links (e.g. notifications) ever land outside Discover.
                venueSnippet(name: event.venueName, address: nil,
                             latitude: event.latitude, longitude: event.longitude,
                             showsChevron: false)
            }
        }
    }

    private func venueSnippet(name: String, address: String?,
                              latitude: Double, longitude: Double,
                              showsChevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(name)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.ink)
                    if let address {
                        Text(address)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Venue: \(name)\(address.map { ", \($0)" } ?? "")")
            .accessibilityHint(showsChevron ? "Opens venue details" : "")

            VenueMapSnippet(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                            title: name)
        }
    }

    // MARK: Attendees

    @ViewBuilder
    private var attendeeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionTitle("Who's going")
            if viewModel.attendeesError {
                Text(viewModel.attendeesErrorMessage ?? "Couldn't load attendees.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.secondary)
            } else if viewModel.attendeePreviews.isEmpty {
                Text(viewModel.isLoading ? "Loading…" : "Be the first to RSVP")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        // No stable id per attendee by design (the view exposes no
                        // user id — first name + avatar only), so index the strip.
                        ForEach(Array(viewModel.attendeePreviews.enumerated()), id: \.offset) { _, attendee in
                            AttendeeChip(firstName: attendee.firstName)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xxs)
                }
                if viewModel.overflowGoingCount > 0 {
                    Text("and \(viewModel.overflowGoingCount) more going")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.forest)
                }
            }
        }
    }

    // MARK: RSVP CTA (T17)

    // The CTA reflects the caller's own ticket state, reconciled from the server
    // after every action: none → [RSVP]; going → "You're going" + cancel;
    // waitlist → "You're on the waitlist" + cancel. Optimistic updates spring in
    // (reduce-motion falls back to a hard cut), and success/error emit haptics.
    @ViewBuilder
    private var rsvpSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            switch viewModel.rsvpStatus {
            case .going:
                rsvpStatusCard(icon: "checkmark.circle.fill",
                               title: "You're going", tint: Theme.forest)
                cancelRSVPButton
            case .waitlist:
                rsvpStatusCard(icon: "clock.badge.checkmark",
                               title: "You're on the waitlist", tint: Theme.terracotta)
                cancelRSVPButton
            default:
                ThrdButton(title: "RSVP", isLoading: viewModel.isSubmittingRSVP) {
                    Task { await viewModel.rsvp() }
                }
                .disabled(viewModel.isSubmittingRSVP)
                .accessibilityLabel("RSVP to \(event.title)")
                .accessibilityHint("Reserves your spot for this event")
            }
        }
        .padding(.top, Theme.Spacing.sm)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75),
                   value: viewModel.rsvpStatus)
        // Haptics on confirm/failure (motion-independent — safe under reduce-motion).
        .sensoryFeedback(.success, trigger: viewModel.rsvpSuccessPulse)
        .sensoryFeedback(.error, trigger: viewModel.rsvpErrorPulse)
    }

    private func rsvpStatusCard(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private var cancelRSVPButton: some View {
        ThrdButton(title: "Cancel RSVP", style: .secondary, isLoading: viewModel.isSubmittingRSVP) {
            Task { await viewModel.cancelRSVP() }
        }
        .disabled(viewModel.isSubmittingRSVP)
        .accessibilityHint("Cancels your spot for this event")
    }

    // MARK: Shared

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.title)
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }

    /// A friendly time range: the day+time of the start, then the end time.
    static func timeText(start: Date, end: Date) -> String {
        let day = start.formatted(.dateTime.weekday(.wide).month().day().hour().minute())
        let endTime = end.formatted(.dateTime.hour().minute())
        return "\(day) – \(endTime)"
    }
}

// MARK: - PublicProfile → ProfileSummary bridge (reuses Profile's avatar)

private extension PublicProfile {
    /// Adapts the view row to `ProfileSummary` so `InitialsAvatar` (Features/
    /// Profile) renders the host avatar — no second initials/color path (D2).
    var asProfileSummary: ProfileSummary {
        ProfileSummary(id: id, handle: handle, displayName: displayName,
                       bio: nil, interests: interests)
    }
}

// MARK: - Attendee chip (first name + initials avatar; no user id, no handle)

private struct AttendeeChip: View {
    let firstName: String

    var body: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Circle()
                .fill(Self.color(for: firstName))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(String(firstName.prefix(1)).uppercased())
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                )
                .accessibilityHidden(true)
            Text(firstName)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .frame(width: 56)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(firstName), going")
    }

    /// Deterministic palette color from the first name — attendees carry no user
    /// id (privacy), so color keys off the name rather than `Avatar.color(for:)`.
    /// Reuses `Avatar.palette` (no second palette). Byte-sum keeps it stable.
    static func color(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Avatar.palette[sum % Avatar.palette.count]
    }
}

// MARK: - Previews

#Preview("Event Detail") {
    NavigationStack {
        EventDetailView(
            event: NearbyEvent(
                id: UUID(uuidString: "E5E10000-0000-4000-8000-000000000001")!,
                communityId: nil, hostId: MockDiscoverRepository.mockHost.id,
                spaceId: UUID(), title: "Silent Book Club",
                description: "Bring a book, read together for an hour, then swap recommendations over coffee.",
                coverUrl: nil, startsAt: .now.addingTimeInterval(3600 * 6),
                endsAt: .now.addingTimeInterval(3600 * 8), recurrenceRule: nil,
                capacity: 40, price: 0, status: .published, rsvpCount: 24,
                createdAt: .now, venueName: "Third Wave Coffee, Indiranagar",
                latitude: 12.9719, longitude: 77.6412, distanceMeters: 5010),
            venueSpace: NearbySpace(
                id: UUID(), ownerUserId: nil, name: "Third Wave Coffee, Indiranagar",
                category: .cafe, latitude: 12.9719, longitude: 77.6412,
                address: "100 Feet Rd, Indiranagar, Bengaluru", photos: [],
                amenities: ["wifi"], hours: nil, capacity: 40, isPartner: true,
                ratingAgg: nil, createdAt: .now, distanceMeters: 5010, upcomingEventCount: 1),
            repository: MockDiscoverRepository())
    }
}

#Preview("Event Detail · Going") {
    // The mock returns an own `going` ticket for this event id, so the CTA loads
    // into the "You're going" + cancel state (no network in the preview).
    let eventID = UUID(uuidString: "E5E10000-0000-4000-8000-000000000001")!
    var mock = MockDiscoverRepository()
    mock.ownTicketRows = [
        Ticket(id: UUID(), eventId: eventID, userId: UUID(), type: .rsvp,
               status: .going, qrCodeToken: nil, purchasedAt: .now, checkedInAt: nil),
    ]
    return NavigationStack {
        EventDetailView(
            event: NearbyEvent(
                id: eventID, communityId: nil, hostId: MockDiscoverRepository.mockHost.id,
                spaceId: UUID(), title: "Silent Book Club", description: nil, coverUrl: nil,
                startsAt: .now.addingTimeInterval(3600 * 6), endsAt: .now.addingTimeInterval(3600 * 8),
                recurrenceRule: nil, capacity: 40, price: 0, status: .published, rsvpCount: 24,
                createdAt: .now, venueName: "Third Wave Coffee, Indiranagar",
                latitude: 12.9719, longitude: 77.6412, distanceMeters: 5010),
            repository: mock)
    }
}
