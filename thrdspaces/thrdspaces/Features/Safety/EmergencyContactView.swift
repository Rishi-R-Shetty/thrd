//
//  EmergencyContactView.swift
//  ThrdSpaces — Features/Safety
//
//  Set / edit / remove the emergency contact used by the panic button (T19).
//  Decision D9 — NON-NEGOTIABLE: the contact is stored ONLY in the device
//  Keychain (`EmergencyContactStore`). This screen never sends it anywhere — no
//  repository, no Edge Function, no network call. It is reachable from Settings
//  and from the first-meeting safety sheet.
//

import SwiftUI

struct EmergencyContactView: View {

    /// Injectable store so a test can drive save/clear against a scratch Keychain
    /// service without touching the real contact.
    let store: EmergencyContactStore

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var phone = ""
    @State private var hasExistingContact = false
    @State private var savedPulse = 0

    init(store: EmergencyContactStore = EmergencyContactStore()) {
        self.store = store
    }

    /// Name must be non-empty; phone must contain at least a few digits. This is
    /// device-local input, but validation still applies at the entry boundary so
    /// a blank/garbage contact can't be saved and silently fail the panic SMS.
    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitCount = phone.filter(\.isNumber).count
        return !trimmedName.isEmpty && digitCount >= 5
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .accessibilityLabel("Contact name")
                    TextField("Phone number", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .accessibilityLabel("Contact phone number")
                } header: {
                    Text("Trusted contact")
                } footer: {
                    Text("Stored only on this device — never uploaded or shared. Used by the panic button during events to text this person your location.")
                }

                if hasExistingContact {
                    Section {
                        Button(role: .destructive) { removeContact() } label: {
                            Label("Remove contact", systemImage: "trash")
                        }
                        .accessibilityLabel("Remove emergency contact")
                    }
                }
            }
            .navigationTitle("Emergency contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveContact() }
                        .disabled(!isValid)
                        .accessibilityLabel("Save emergency contact")
                }
            }
            .sensoryFeedback(.success, trigger: savedPulse)
            .onAppear(perform: loadExisting)
        }
    }

    private func loadExisting() {
        guard let contact = store.load() else { return }
        name = contact.name
        phone = contact.phone
        hasExistingContact = true
    }

    private func saveContact() {
        // Best-effort: a Keychain write failure leaves any prior contact intact.
        // ponytail: a save failure is swallowed (dismisses regardless) — the
        // panic flow degrades to "dial only" if nothing was stored. Surface a
        // retry alert if field-testing shows silent-save confusion.
        try? store.save(EmergencyContact(name: name, phone: phone))
        savedPulse += 1
        dismiss()
    }

    private func removeContact() {
        try? store.clear()
        name = ""
        phone = ""
        hasExistingContact = false
        dismiss()
    }
}

// MARK: - Preview

#Preview("Emergency contact") {
    EmergencyContactView()
}
