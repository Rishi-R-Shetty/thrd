//
//  FirstMeetingSafetySheet.swift
//  ThrdSpaces — Features/Safety
//
//  The first-meeting safety sheet (T19, threat-model Layer 7). Shown before the
//  user's FIRST RSVP, it presents the three safety asks and requires an explicit
//  acknowledgement before the RSVP proceeds. Non-dismissable: no swipe-to-dismiss
//  and no background tap — the only way forward is to tick the checkbox and tap
//  Continue (the CTA is disabled until the box is checked). The trigger is
//  derived server-side from the caller's own tickets (see EventDetailViewModel),
//  NOT UserDefaults, so a reinstall can't bypass it.
//

import SwiftUI

struct FirstMeetingSafetySheet: View {

    /// Called once the user checks the box and taps Continue — the host proceeds
    /// with the actual RSVP.
    let onAcknowledge: () -> Void
    /// Called to cancel the RSVP attempt (the "Not now" affordance — the RSVP
    /// simply does not happen; nothing is written).
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var acknowledged = false
    @State private var showContactEditor = false

    private let asks: [(icon: String, title: String, body: String)] = [
        ("building.2.fill", "Meet in a public space",
         "Choose a busy, public place for a first meeting — a café, park, or venue."),
        ("person.2.fill", "Tell a friend",
         "Let someone know where you're going, who you're meeting, and when you'll be back."),
        ("location.fill.viewfinder", "Share your live location",
         "Share your location with a trusted contact from Messages or Find My while you're out."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    header
                    ForEach(Array(asks.enumerated()), id: \.offset) { index, ask in
                        askRow(ask)
                            .opacity(reduceMotion ? 1 : (acknowledged ? 1 : 1))
                            .transition(.opacity)
                    }
                    emergencyContactRow
                    acknowledgeToggle
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.cream)
            .safeAreaInset(edge: .bottom) { continueBar }
            .navigationTitle("Before you go")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A single explicit "Not now" — the ONLY exit besides Continue.
                // Non-dismissable otherwise (interactiveDismissDisabled below).
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { onCancel() }
                        .accessibilityLabel("Not now, cancel RSVP")
                }
            }
        }
        // Non-dismissable: block swipe-down and background-tap dismissal.
        .interactiveDismissDisabled(true)
        .sheet(isPresented: $showContactEditor) {
            EmergencyContactView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Theme.forest)
                .accessibilityHidden(true)
            Text("Meeting someone new")
                .font(Theme.Typography.largeTitle)
                .foregroundStyle(Theme.ink)
            Text("A few quick things to keep your first meet-up safe.")
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func askRow(_ ask: (icon: String, title: String, body: String)) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: ask.icon)
                .font(.title2)
                .foregroundStyle(Theme.terracotta)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(ask.title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.ink)
                Text(ask.body)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ask.title). \(ask.body)")
    }

    private var emergencyContactRow: some View {
        Button { showContactEditor = true } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "phone.badge.plus")
                    .font(.title3)
                    .foregroundStyle(Theme.forest)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Set an emergency contact")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.ink)
                    Text("Kept only on this device. Used by the panic button during events.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(Theme.Spacing.md)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set an emergency contact, kept only on this device")
        .accessibilityHint("Opens the emergency contact editor")
    }

    private var acknowledgeToggle: some View {
        Toggle(isOn: $acknowledged.animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7))) {
            Text("I've read these and I'll meet safely.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.ink)
        }
        .toggleStyle(.switch)
        .tint(Theme.forest)
        .padding(Theme.Spacing.md)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .accessibilityLabel("I've read these and I'll meet safely")
    }

    private var continueBar: some View {
        ThrdButton(title: "Continue to RSVP") { onAcknowledge() }
            .disabled(!acknowledged)
            .padding(Theme.Spacing.md)
            .background(.ultraThinMaterial)
            .accessibilityHint(acknowledged
                ? "Confirms your RSVP"
                : "Check the box above to continue")
    }
}

// MARK: - Preview

#Preview("First-meeting sheet") {
    Color.black.sheet(isPresented: .constant(true)) {
        FirstMeetingSafetySheet(onAcknowledge: {}, onCancel: {})
    }
}
