import Foundation
import Observation

/// « Connexion » screen. On success `AuthService.authStates()` emits the new session and `AppModel` switches to
/// the signed-in app: the view has nothing else to do.
@MainActor
@Observable
public final class LoginViewModel: ErrorPresenting {
    public var email: String
    public var password = ""
    public private(set) var isSubmitting = false
    public var error: ErrorState?

    private let services: AppServices

    public init(services: AppServices, email: String = "") {
        self.services = services
        self.email = email
    }

    /// Both fields filled and no request in progress.
    public var canSubmit: Bool {
        !InputValidation.trimmed(email).isEmpty && !password.isEmpty && !isSubmitting
    }

    /// Signs in. Returns true on success (the password field is then cleared).
    @discardableResult
    public func signIn() async -> Bool {
        guard !isSubmitting else { return false }
        error = nil
        guard !password.isEmpty else {
            present(message: "Saisis ton mot de passe.")
            return false
        }
        let normalizedEmail: String
        do {
            normalizedEmail = try InputValidation.email(email)
        } catch {
            present(error)
            return false
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await services.auth.signIn(email: normalizedEmail, password: password)
            password = ""
            return true
        } catch {
            present(error)
            return false
        }
    }
}
