//
//  ReportSheetView.swift
//  ThrdSpaces — Features/Profile
//
//  Reusable report sheet (App Store Guideline 1.2 reporting path). Mounted from a
//  profile's ⋯ menu. Phase 1 only reports `subject_type = user`, but the sheet
//  takes any subject so later phases can report events/communities without a
//  rewrite. Submission goes through `EdgeFunctionClient`; `reporter_id` is
//  derived server-side from the JWT — the client never supplies it.
//

import SwiftUI
import Combine

struct ReportSheetView: View {
    let subjectID: UUID
    var subjectType: ReportSubject = .user
    /// Optional context for the header, e.g. "@handle".
    var subjectName: String?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ReportSheetViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $viewModel.reason) {
                        ForEach(ReportReason.allCases) { reason in
                            Text(reason.label).tag(reason)
                        }
                    }
                    .accessibilityLabel("Reason for reporting")
                } header: {
                    Text("Why are you reporting\(subjectName.map { " \($0)" } ?? "")?")
                }

                Section {
                    TextEditor(text: $viewModel.detail)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Additional detail, optional")
                } header: {
                    Text("Add detail (optional)")
                } footer: {
                    Text(viewModel.counterText)
                        .foregroundStyle(viewModel.isDetailOverLimit ? Theme.terracotta : .secondary)
                        .accessibilityLabel(viewModel.counterAccessibilityLabel)
                }

                if let message = viewModel.errorMessage {
                    Section {
                        Text(message)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.terracotta)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }

                Section {
                    ThrdButton(title: "Submit report", isLoading: viewModel.isSubmitting) {
                        Task {
                            if await viewModel.submit(subjectType: subjectType, subjectID: subjectID) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!viewModel.canSubmit)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel reporting")
                }
            }
        }
    }
}

// MARK: - View model

@MainActor
final class ReportSheetViewModel: ObservableObject {
    @Published var reason: ReportReason = .safety
    @Published var detail: String = ""
    @Published private(set) var isSubmitting = false
    @Published private(set) var errorMessage: String?

    private let functions = EdgeFunctionClient()

    var isDetailOverLimit: Bool { detail.count > EdgeFunctionClient.detailLimit }
    var canSubmit: Bool { !isSubmitting && !isDetailOverLimit }

    var counterText: String { "\(detail.count)/\(EdgeFunctionClient.detailLimit)" }
    var counterAccessibilityLabel: String {
        "\(detail.count) of \(EdgeFunctionClient.detailLimit) characters used"
    }

    /// Submits the report. Returns `true` when the sheet should close — both a
    /// fresh submission and an `already_reported` dedupe are successes; the
    /// caller dismisses on either. Only a real failure keeps the sheet open with
    /// an error.
    func submit(subjectType: ReportSubject, subjectID: UUID) async -> Bool {
        guard canSubmit else { return false }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            _ = try await functions.submitReport(
                subjectType: subjectType, subjectID: subjectID,
                reason: reason, detail: detail
            )
            // Success (submitted) and the dedupe notice (alreadyReported) both
            // mean "we have your report" — close either way, no distinction
            // leaked to the reporter about the subject's prior report state.
            return true
        } catch {
            errorMessage = ProfileErrorCopy.message(for: error)
            return false
        }
    }
}

// MARK: - Preview

#Preview("ReportSheet") {
    ReportSheetView(subjectID: UUID(), subjectName: "@ada")
}
