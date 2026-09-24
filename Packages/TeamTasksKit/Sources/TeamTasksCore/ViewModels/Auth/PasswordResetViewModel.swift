import Foundation
import Observation

/// « Mot de passe oublié » flow: e-mail → 6-digit code received by e-mail → new password.
///
/// Create it with `AppModel.startPasswordReset(email:)`: verifying the code signs the user in (recovery session),
/// and the `AppModel` then shows `.passwordRecovery(self)` instead of the app until the new password is set
/// (`isInPasswordRecovery`).
@MainActor
@Observable
public final class PasswordResetViewModel: ErrorPresenting, Identifiable {
    public enum Step: Sendable, Hashable {
        /// Enter the account's e-mail.
        case email
        /// Enter the 6-digit code received by e-mail (with « Renvoyer le code »).
        case code
        /// Choose the new password (the user is signed in with a recovery session).
        case newPassword
        /// Password changed; the app opens.
        case done
    }

    public static let codeLength = 6
    public static let mismatchMessage = "Les mots de passe ne correspondent pas."
    public static let incompleteCodeMessage = "Saisissez les 6 chiffres du code reçu par e-mail."
    public static let resentMessage = "Un nouveau code vient d’être envoyé."
    public static let doneMessage = "Votre mot de passe a été modifié."
    /// The recovery session ended before the new password was set.
    public static let recoveryEndedMessage =
        "La session de réinitialisation a expiré avant l’enregistrement du nouveau mot de passe. Demandez un nouveau code."

    public nonisolated let id = UUID()
    public private(set) var step: Step = .email
    public var email: String
    /// Digits only, at most 6 (anything else typed or pasted is dropped).
    public var code: String {
        get { codeValue }
        set { codeValue = Self.sanitizedCode(newValue) }
    }

    public var newPassword = ""
    public var passwordConfirmation = ""
    public private(set) var isSubmitting = false
    /// Neutral information (« Si un compte existe… », « Un nouveau code… »).
    public private(set) var infoMessage: String?
    public var error: ErrorState?

    private var codeValue = ""
    private let services: AppServices
    @ObservationIgnored private weak var app: AppModel?

    public init(services: AppServices, email: String = "", app: AppModel? = nil) {
        self.services = services
        self.email = email
        self.app = app
    }

    // MARK: - Titles

    public var title: String {
        switch step {
        case .email, .code: "Mot de passe oublié"
        case .newPassword, .done: "Nouveau mot de passe"
        }
    }

    public var canSendCode: Bool { !InputValidation.trimmed(email).isEmpty && !isSubmitting }
    public var canVerifyCode: Bool { codeValue.count == Self.codeLength && !isSubmitting }
    public var canUpdatePassword: Bool { !newPassword.isEmpty && !passwordConfirmation.isEmpty && !isSubmitting }

    // MARK: - Steps

    /// Sends the code to `email` and moves to the code step. Unknown addresses succeed silently (no account
    /// enumeration), hence the neutral message.
    @discardableResult
    public func sendCode() async -> Bool {
        guard !isSubmitting else { return false }
        error = nil
        let address: String
        do {
            address = try InputValidation.email(email)
        } catch {
            present(error)
            return false
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await services.auth.sendPasswordReset(email: address)
            email = address
            codeValue = ""
            infoMessage = "Si un compte existe pour \(address), un code à 6 chiffres vient d’y être envoyé."
            step = .code
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// Sends a new code (code step).
    @discardableResult
    public func resendCode() async -> Bool {
        guard step == .code, !isSubmitting else { return false }
        error = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await services.auth.sendPasswordReset(email: InputValidation.normalizedEmail(email))
            codeValue = ""
            infoMessage = Self.resentMessage
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// Verifies the code; on success the user is signed in with a recovery session and the flow moves to the
    /// new password step.
    @discardableResult
    public func verifyCode() async -> Bool {
        guard step == .code, !isSubmitting else { return false }
        error = nil
        guard codeValue.count == Self.codeLength else {
            present(message: Self.incompleteCodeMessage, error: .otpInvalid)
            return false
        }
        isSubmitting = true
        defer { isSubmitting = false }
        app?.beginPasswordRecovery(self)
        do {
            try await services.auth.verifyRecoveryCode(email: InputValidation.normalizedEmail(email), code: codeValue)
            infoMessage = nil
            step = .newPassword
            return true
        } catch {
            await app?.cancelPasswordRecovery()
            present(error)
            return false
        }
    }

    /// Sets the new password, then the app opens.
    @discardableResult
    public func updatePassword() async -> Bool {
        guard step == .newPassword, !isSubmitting else { return false }
        error = nil
        if let message = SignUpViewModel.passwordMessage(newPassword) {
            present(message: message, error: .weakPassword)
            return false
        }
        guard newPassword == passwordConfirmation else {
            present(message: Self.mismatchMessage, error: .invalidInput)
            return false
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await services.auth.updatePassword(newPassword)
            newPassword = ""
            passwordConfirmation = ""
            infoMessage = Self.doneMessage
            step = .done
            await app?.finishPasswordRecovery()
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// Code step → e-mail step (to fix the address).
    public func goBack() {
        guard step == .code else { return }
        error = nil
        infoMessage = nil
        codeValue = ""
        step = .email
    }

    /// The recovery session ended before the new password was set (revoked, refresh refused): back to the e-mail
    /// step (address kept) with an explanation, since the code was used up.
    func recoverySessionEnded() {
        guard step == .newPassword else { return }
        newPassword = ""
        passwordConfirmation = ""
        codeValue = ""
        infoMessage = nil
        step = .email
        present(message: Self.recoveryEndedMessage, error: .notAuthenticated)
    }

    /// Leaves the flow. At the new password step the recovery session is closed (local sign-out): the password
    /// was not changed, so the login screen comes back.
    public func cancel() async {
        error = nil
        switch step {
        case .newPassword:
            await app?.abandonPasswordRecovery()
        case .email, .code, .done:
            if app?.passwordReset === self {
                app?.passwordReset = nil
            }
        }
    }

    /// Keeps the ASCII digits, at most `codeLength`.
    public static func sanitizedCode(_ input: String) -> String {
        String(input.unicodeScalars.filter { ("0"..."9").contains($0) }.prefix(codeLength).map(Character.init))
    }
}
