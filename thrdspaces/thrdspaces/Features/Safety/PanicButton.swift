//
//  PanicButton.swift
//  ThrdSpaces — Features/Safety
//
//  The panic button (T19, threat-model Layer 7). Mounts on Event Detail ONLY
//  within a ±2h window around `event.startsAt`. One tap:
//   1. dials the local emergency number (`tel://`), and
//   2. opens a pre-filled SMS (`sms:`) to the Keychain-resident emergency
//      contact, containing a maps link to the venue coordinates.
//
//  Decision D9 — NON-NEGOTIABLE: the emergency contact is read from the device
//  Keychain (`EmergencyContactStore`) and used only to address a local `sms:`
//  URL. The phone never enters a network request, a URL sent to any server, or a
//  table write. The maps link carries only the (already-public) venue coords.
//

import SwiftUI
import UIKit

// MARK: - Pure window + URL logic (unit-tested independently of the view)

extension PanicButton {

    /// Half-width of the visibility window (2 hours before → 2 hours after start).
    static let windowHalfWidth: TimeInterval = 2 * 60 * 60

    /// True when `now` is inside the ±2h window around `startsAt`. The button is
    /// hidden entirely outside this window (Layer 7: panic is an at-event action).
    static func isWithinWindow(now: Date, startsAt: Date) -> Bool {
        now >= startsAt.addingTimeInterval(-windowHalfWidth)
            && now <= startsAt.addingTimeInterval(windowHalfWidth)
    }
}

/// Builds the two device-local URLs the panic tap opens. Pure and side-effect
/// free so the exact wire-free shape is unit-testable.
enum PanicDialer {

    // ponytail: single hardcoded emergency number — 112 is the pan-regional
    // emergency number (works across India and the EU, forwards to local
    // services). Good enough for the launch cities (Bengaluru + one EU city).
    // Upgrade to locale resolution (911 US / 999 UK / 000 AU …) off the SIM
    // region or `Locale.current.region` when we launch outside 112 coverage.
    static let defaultEmergencyNumber = "112"

    /// The dialer URL for the local emergency number.
    static func emergencyURL(number: String = defaultEmergencyNumber) -> URL? {
        URL(string: "tel://\(number)")
    }

    /// A pre-filled SMS to the emergency contact with a maps link to the venue.
    /// The contact phone is the `sms:` recipient (device-local); the body carries
    /// only the venue name + public coordinates. Never sent to any server (D9).
    static func smsURL(contact: EmergencyContact,
                       venueName: String,
                       latitude: Double,
                       longitude: Double) -> URL? {
        let maps = "https://maps.apple.com/?ll=\(latitude),\(longitude)"
        let body = "I need help. I'm at \(venueName). My location: \(maps)"
        var components = URLComponents()
        components.scheme = "sms"
        // Recipient in the path; body as a query item (percent-encoded by URLComponents).
        components.path = contact.phone
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url
    }
}

// MARK: - View

/// The at-event panic control. The caller (Event Detail) gates *mounting* on
/// `PanicButton.isWithinWindow`; this view assumes it is already inside the
/// window and renders unconditionally.
struct PanicButton: View {

    let venueName: String
    let latitude: Double
    let longitude: Double

    /// Injectable opener so a test can drive the tap without launching Messages
    /// or the dialer. Production opens via `UIApplication`.
    var open: (URL) -> Void = { UIApplication.shared.open($0) }
    /// Injectable contact lookup (defaults to the real Keychain store).
    var loadContact: () -> EmergencyContact? = { EmergencyContactStore().load() }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    @State private var activationPulse = 0
    @State private var showNoContactNotice = false

    var body: some View {
        Button {
            activate()
        } label: {
            Label("Emergency help", systemImage: "exclamationmark.shield.fill")
                .font(Theme.Typography.button)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.red, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                )
                .scaleEffect(isPressed ? 0.97 : 1)
                .opacity(isPressed ? 0.9 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7),
                           value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        // Confirmation haptic on activation — one impact per tap, never spammed.
        .sensoryFeedback(.impact(weight: .heavy), trigger: activationPulse)
        .accessibilityLabel("Emergency help")
        .accessibilityHint("Calls the local emergency number and texts your emergency contact your location")
        .accessibilityAddTraits(.isButton)
        .alert("No emergency contact set", isPresented: $showNoContactNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("We dialed emergency services. Add a trusted contact in Settings so we can also text them your location next time.")
        }
    }

    private func activate() {
        activationPulse += 1
        // 1. Always dial the local emergency number first (the primary action).
        if let tel = PanicDialer.emergencyURL() { open(tel) }
        // 2. Then text the emergency contact a maps link, if one is set.
        // ponytail: the dialer and Messages are opened back-to-back; iOS may
        // foreground only the first on some OS versions. Dialing is prioritized
        // (life-safety first); the SMS is best-effort. A staged "call, then on
        // return offer to text" flow is the fuller UX if field-testing shows the
        // second open being dropped.
        if let contact = loadContact(),
           let sms = PanicDialer.smsURL(contact: contact, venueName: venueName,
                                        latitude: latitude, longitude: longitude) {
            open(sms)
        } else {
            showNoContactNotice = true
        }
    }
}

// MARK: - Preview

#Preview("Panic button") {
    PanicButton(venueName: "Third Wave Coffee, Indiranagar",
                latitude: 12.9719, longitude: 77.6412,
                open: { _ in }, loadContact: { EmergencyContact(name: "Mum", phone: "+911234567890") })
        .padding()
        .background(Theme.cream)
}
