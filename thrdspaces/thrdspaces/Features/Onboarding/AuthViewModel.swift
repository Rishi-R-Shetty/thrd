//
//  AuthViewModel.swift
//  ThrdSpaces — Features/Onboarding
//
//  Drives SignInView. Owns the Sign-in-with-Apple nonce and the phone-OTP
//  state machine, and maps every failure to a friendly, non-leaking message.
//  All backend work goes through `AuthRepository` — this type never touches the
//  Supabase client, so it doesn't import Supabase.
//

import Foundation
import Combine
import CryptoKit
import Security
import AuthenticationServices

@MainActor
final class AuthViewModel: ObservableObject {

    /// The phone-OTP flow plus the terminal states shared with Apple sign-in.
    enum Phase: Equatable {
        case idle          // entering phone number / awaiting a method
        case sendingCode   // requestOTP in flight
        case codeSent      // SMS dispatched — showing the code field
        case verifying     // verifyOTP in flight
        case authenticated // session established
        case error(String) // user-facing, non-leaking message
    }

    @Published var phase: Phase = .idle
    @Published var phoneNumber: String = ""
    @Published var code: String = ""

    /// Fired once a session exists so the launch gate can swap in RootTabView.
    var onAuthenticated: (() -> Void)?

    private let repository = AuthRepository()

    /// RAW nonce for the in-flight Apple request. Generated fresh per request,
    /// SHA-256'd into the Apple request, sent RAW to Supabase, then cleared.
    private var currentNonce: String?

    // MARK: - Derived UI state

    var isBusy: Bool { phase == .sendingCode || phase == .verifying }
    var isAwaitingCode: Bool { phase == .codeSent || phase == .verifying }
    var errorMessage: String? {
        if case let .error(message) = phase { return message }
        return nil
    }

    // MARK: - Sign in with Apple

    /// Called from the button's `onRequest`. Generates a fresh nonce, hashes it
    /// into the request, and asks only for name + email (Guideline 4.8 minimal
    /// collection).
    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.makeRawNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256Hex(nonce)
    }

    /// Called from the button's `onCompletion`.
    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        Task { await completeAppleSignIn(result) }
    }

    private func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case let .success(authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = currentNonce
            else {
                phase = .error("Couldn't complete Sign in with Apple. Please try again.")
                return
            }
            do {
                _ = try await repository.signInWithApple(idToken: idToken, nonce: nonce)
                currentNonce = nil
                phase = .authenticated
                onAuthenticated?()
            } catch {
                phase = .error(Self.message(for: error))
            }

        case let .failure(error):
            // A user cancel is not an error state — quietly return to idle.
            if (error as? ASAuthorizationError)?.code == .canceled {
                phase = .idle
            } else {
                phase = .error("Couldn't complete Sign in with Apple. Please try again.")
            }
        }
    }

    // MARK: - Phone OTP

    func sendCode() {
        Task {
            phase = .sendingCode
            do {
                try await repository.requestOTP(phone: phoneNumber)
                phase = .codeSent
            } catch {
                phase = .error(Self.message(for: error))
            }
        }
    }

    func verifyCode() {
        Task {
            phase = .verifying
            do {
                _ = try await repository.verifyOTP(phone: phoneNumber, code: code)
                phase = .authenticated
                onAuthenticated?()
            } catch {
                phase = .error(Self.message(for: error))
            }
        }
    }

    /// Return to the phone-entry step (e.g. wrong number / expired code).
    func editNumber() {
        code = ""
        phase = .idle
    }

    // MARK: - Nonce helpers (nonisolated: pure, unit-tested)

    /// A cryptographically random nonce: `byteCount` bytes of entropy, hex
    /// encoded. 32 bytes → a 64-char lowercase-hex string.
    nonisolated static func makeRawNonce(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase-hex SHA-256 of a UTF-8 string.
    nonisolated static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Error → message

    /// Maps `APIError` to a friendly, non-leaking string. Rate limits get their
    /// own "try again later" copy; everything else stays generic so no backend
    /// detail reaches the UI.
    nonisolated static func message(for error: Error) -> String {
        // Client-side validation fails before any network call — give the
        // specific hint. (A server-side 400 is deliberately kept generic below
        // so no backend detail leaks.)
        if case AuthRepository.ValidationError.invalidPhoneNumber = error {
            return "That doesn't look like a valid phone number. Include your country code, e.g. +1."
        }
        guard let apiError = error as? APIError else {
            return "Something went wrong. Please try again."
        }
        switch apiError {
        case let .server(status) where status == 429:
            return "Too many attempts. Please try again in a little while."
        case .network:
            return "No connection. Check your internet and try again."
        case .auth:
            return "That code didn't work. Please try again."
        default:
            return "Something went wrong. Please try again."
        }
    }
}
