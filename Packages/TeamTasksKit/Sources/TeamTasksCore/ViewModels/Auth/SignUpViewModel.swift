import Foundation
import Observation

/// « Créer un compte » screen. Fields are validated on the client with the rules of `InputValidation.signUp`
/// (docs/CONTRACTS.md §1) before calling the server; each field shows its own message. After a first failed
/// submission, a field's message updates live while it is corrected.
@MainActor
@Observable
public final class SignUpViewModel: ErrorPresenting {
    public static let passwordTooLongMessage = "Mot de passe trop long (72 caractères maximum)."
    public static let confirmationRequiredMessage =
        "Compte créé. Confirme ton adresse e-mail grâce au lien reçu, puis connecte-toi."

    public var displayName: String {
        get { displayNameValue }
        set {
            displayNameValue = newValue
            if displayNameError != nil { displayNameError = Self.displayNameMessage(newValue) }
        }
    }

    public var email: String {
        get { emailValue }
        set {
            emailValue = newValue
            if emailError != nil { emailError = Self.emailMessage(newValue) }
        }
    }

    public var password: String {
        get { passwordValue }
        set {
            passwordValue = newValue
            if passwordError != nil { passwordError = Self.passwordMessage(newValue) }
        }
    }

    public private(set) var displayNameError: String?
    public private(set) var emailError: String?
    public private(set) var passwordError: String?
    public private(set) var isSubmitting = false
    /// Set when the project requires e-mail confirmation (`SignUpOutcome.confirmationRequired`): show
    /// `confirmationRequiredMessage` and go back to the login screen.
    public private(set) var needsEmailConfirmation = false
    public var error: ErrorState?

    private var displayNameValue = ""
    private var emailValue = ""
    private var passwordValue = ""
    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    /// Every field filled and no request in progress (the rules themselves are checked on submit).
    public var canSubmit: Bool {
        !InputValidation.trimmed(displayNameValue).isEmpty
            && !InputValidation.trimmed(emailValue).isEmpty
            && !passwordValue.isEmpty
            && !isSubmitting
    }

    /// Checks every field and sets its message. Returns true when all are valid.
    @discardableResult
    public func validate() -> Bool {
        emailError = Self.emailMessage(emailValue)
        passwordError = Self.passwordMessage(passwordValue)
        displayNameError = Self.displayNameMessage(displayNameValue)
        return emailError == nil && passwordError == nil && displayNameError == nil
    }

    /// Creates the account. Returns true on success: the session opens (`AppModel` switches to the app) or
    /// `needsEmailConfirmation` becomes true.
    @discardableResult
    public func signUp() async -> Bool {
        guard !isSubmitting else { return false }
        error = nil
        guard validate() else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let outcome = try await services.auth.signUp(
                email: emailValue,
                password: passwordValue,
                displayName: displayNameValue
            )
            passwordValue = ""
            needsEmailConfirmation = outcome == .confirmationRequired
            return true
        } catch {
            guard let appError = ErrorState(from: error)?.error else { return false }
            switch appError {
            case .invalidEmail, .emailAlreadyUsed:
                emailError = appError.messageFR
            case .weakPassword:
                passwordError = appError.messageFR
            case .invalidDisplayName:
                displayNameError = appError.messageFR
            default:
                present(appError)
            }
            return false
        }
    }

    // MARK: - Field rules (InputValidation, docs/CONTRACTS.md §1)

    public static func emailMessage(_ email: String) -> String? {
        do {
            _ = try InputValidation.email(email)
            return nil
        } catch {
            return AppError.invalidEmail.messageFR
        }
    }

    public static func passwordMessage(_ password: String) -> String? {
        do {
            try InputValidation.password(password)
            return nil
        } catch AppError.weakPassword {
            return AppError.weakPassword.messageFR
        } catch {
            return passwordTooLongMessage
        }
    }

    public static func displayNameMessage(_ name: String) -> String? {
        do {
            _ = try InputValidation.displayName(name)
            return nil
        } catch {
            return AppError.invalidDisplayName.messageFR
        }
    }
}
