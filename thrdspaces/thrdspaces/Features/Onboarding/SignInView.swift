//
//  SignInView.swift
//  ThrdSpaces — Features/Onboarding
//
//  First screen a signed-out user sees. Sign in with Apple is the primary,
//  equally-prominent method (Guideline 4.8); phone OTP is the fallback below
//  it. All logic lives in AuthViewModel; this file is layout + accessibility.
//

import SwiftUI
import AuthenticationServices

struct SignInView: View {
    /// Called once a session exists. The launch gate swaps in RootTabView.
    var onAuthenticated: () -> Void

    @StateObject private var viewModel = AuthViewModel()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                header
                appleSection
                orDivider
                phoneSection
                if let message = viewModel.errorMessage {
                    errorBanner(message)
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.cream.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .onAppear { viewModel.onAuthenticated = onAuthenticated }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.terracotta)
                .accessibilityHidden(true)
            Text("Thrd Spaces")
                .font(Theme.Typography.largeTitle)
                .foregroundStyle(Theme.ink)
            Text("Find your people in the places nearby.")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Theme.Spacing.xxl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thrd Spaces. Find your people in the places nearby.")
    }

    // MARK: - Sign in with Apple (primary)

    private var appleSection: some View {
        SignInWithAppleButton(.signIn) { request in
            viewModel.configureAppleRequest(request)
        } onCompletion: { result in
            viewModel.handleAppleCompletion(result)
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .accessibilityLabel("Sign in with Apple")
        .accessibilityHint("Signs you in using your Apple Account. Your email stays private.")
    }

    private var orDivider: some View {
        HStack(spacing: Theme.Spacing.sm) {
            line
            Text("or")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            line
        }
        .accessibilityHidden(true)
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.ink.opacity(0.15))
            .frame(height: 1)
    }

    // MARK: - Phone OTP (fallback)

    @ViewBuilder
    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if viewModel.isAwaitingCode {
                codeEntry
            } else {
                phoneEntry
            }
        }
    }

    private var phoneEntry: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Continue with phone")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.ink)

            TextField("+1 555 123 4567", text: $viewModel.phoneNumber)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .font(Theme.Typography.body)
                .padding(Theme.Spacing.md)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .strokeBorder(Theme.ink.opacity(0.12))
                )
                .accessibilityLabel("Phone number")
                .accessibilityHint("Enter your phone number with country code")

            ThrdButton(title: "Send code", isLoading: viewModel.phase == .sendingCode) {
                viewModel.sendCode()
            }
            .disabled(viewModel.phoneNumber.isEmpty || viewModel.isBusy)
        }
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Enter the 6-digit code")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.ink)
            Text("We sent it to your phone.")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)

            TextField("123456", text: $viewModel.code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(Theme.Typography.title)
                .padding(Theme.Spacing.md)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .strokeBorder(Theme.ink.opacity(0.12))
                )
                .accessibilityLabel("Verification code")
                .accessibilityHint("Enter the six-digit code from the text message")

            ThrdButton(title: "Verify", isLoading: viewModel.phase == .verifying) {
                viewModel.verifyCode()
            }
            .disabled(viewModel.code.isEmpty || viewModel.isBusy)

            Button("Use a different number") { viewModel.editNumber() }
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.terracotta)
                .disabled(viewModel.isBusy)
                .accessibilityLabel("Use a different phone number")
        }
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(Theme.Typography.subheadline)
            .foregroundStyle(Theme.terracotta)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.md)
            .background(Theme.terracotta.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            // VoiceOver announces the message when it appears.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Error")
            .accessibilityValue(message)
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Preview

#Preview("SignIn · Light") {
    SignInView(onAuthenticated: {})
        .preferredColorScheme(.light)
}

#Preview("SignIn · Dark") {
    SignInView(onAuthenticated: {})
        .preferredColorScheme(.dark)
}
