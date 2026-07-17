//
//  ProfileEditView.swift
//  ThrdSpaces — Features/Profile
//
//  Edits the four client-writable fields: handle, display_name, bio, interests.
//  Client-side validation mirrors the DB CHECKs (`^[a-z0-9_]{3,30}$`, name 1–50,
//  bio ≤280, interests ≥3). Handle uniqueness isn't pre-checked — the save
//  attempts the update and surfaces the DB unique-violation as "That handle is
//  taken" (no existence oracle, no extra round-trip). Saving goes through
//  `ProfileViewModel`; interests reuse the onboarding picker's ≥3 rule and the
//  shared `ChipGroup`.
//

import SwiftUI

struct ProfileEditView: View {
    @ObservedObject var viewModel: ProfileViewModel
    let current: ProfileSummary

    @Environment(\.dismiss) private var dismiss

    @State private var handle: String
    @State private var displayName: String
    @State private var bio: String
    @State private var interests: Set<String>

    @State private var isSaving = false
    @State private var handleError: String?
    @State private var generalError: String?

    init(viewModel: ProfileViewModel, current: ProfileSummary) {
        self.viewModel = viewModel
        self.current = current
        _handle = State(initialValue: current.handle)
        _displayName = State(initialValue: current.displayName)
        _bio = State(initialValue: current.bio ?? "")
        _interests = State(initialValue: Set(current.interests))
    }

    private var minimumInterests: Int { InterestPickerViewModel.minimumSelection }

    private var isValid: Bool {
        ProfileValidation.isValidHandle(ProfileValidation.normalizeHandle(handle))
            && ProfileValidation.isValidDisplayName(displayName)
            && ProfileValidation.isValidBio(bio)
            && interests.count >= minimumInterests
    }

    private var chipItems: [ChipItem] {
        InterestTag.all.map { ChipItem(id: $0.id, label: $0.label, systemImage: $0.sfSymbol) }
    }

    var body: some View {
        NavigationStack {
            Form {
                handleSection
                displayNameSection
                bioSection
                interestsSection
                if let generalError {
                    Section {
                        Text(generalError)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.terracotta)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!isValid || isSaving)
                        .accessibilityLabel("Save profile")
                }
            }
        }
    }

    // MARK: Sections

    private var handleSection: some View {
        Section {
            TextField("handle", text: $handle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: handle) { handleError = nil }
                .accessibilityLabel("Handle")
        } header: {
            Text("Handle")
        } footer: {
            Text(handleError ?? "Lowercase letters, numbers, and underscores. 3–30 characters.")
                .foregroundStyle(handleError == nil ? .secondary : Theme.terracotta)
        }
    }

    private var displayNameSection: some View {
        Section {
            TextField("Your name", text: $displayName)
                .accessibilityLabel("Display name")
        } header: {
            Text("Display name")
        } footer: {
            Text("1–\(ProfileValidation.displayNameLimit) characters.")
        }
    }

    private var bioSection: some View {
        Section {
            TextEditor(text: $bio)
                .frame(minHeight: 100)
                .accessibilityLabel("Bio")
        } header: {
            Text("Bio")
        } footer: {
            Text("\(bio.count)/\(ProfileValidation.bioLimit)")
                .foregroundStyle(bio.count > ProfileValidation.bioLimit ? Theme.terracotta : .secondary)
                .accessibilityLabel("\(bio.count) of \(ProfileValidation.bioLimit) characters used")
        }
    }

    private var interestsSection: some View {
        Section {
            ChipGroup(items: chipItems, selection: $interests)
                .listRowInsets(EdgeInsets(top: Theme.Spacing.sm, leading: Theme.Spacing.md,
                                          bottom: Theme.Spacing.sm, trailing: Theme.Spacing.md))
        } header: {
            Text("Interests")
        } footer: {
            Text(interests.count >= minimumInterests
                 ? "\(interests.count) selected"
                 : "Pick at least \(minimumInterests) (\(interests.count) selected).")
                .foregroundStyle(interests.count >= minimumInterests ? .secondary : Theme.terracotta)
        }
    }

    // MARK: Save

    private func save() async {
        guard isValid, !isSaving else { return }
        isSaving = true
        handleError = nil
        generalError = nil
        defer { isSaving = false }

        let outcome = await viewModel.saveProfile(
            handle: handle, displayName: displayName, bio: bio, interests: interests
        )
        switch outcome {
        case .saved:
            dismiss()
        case .handleTaken:
            handleError = "That handle is taken."
        case let .failed(message):
            generalError = message
        }
    }
}

// MARK: - Preview

#Preview("Edit") {
    ProfileEditView(
        viewModel: ProfileViewModel(),
        current: ProfileSummary(
            id: UUID(), handle: "ada_l", displayName: "Ada Lovelace",
            bio: "Mathematician.", interests: ["books", "coffee", "tech"]
        )
    )
}
