import Foundation
import Observation

/// « Mot de passe » of « Réglages »: sets a new password while signed in (`AuthService.updatePassword(_:)`), with the
/// checks of the « Nouveau mot de passe » step of the reset flow: the password rule (`SignUpViewModel.passwordMessage`),
/// then the confirmation (`PasswordResetViewModel.mismatchMessage`). The session stays open.
@MainActor
@Observable
public final class ChangePasswordViewModel: ErrorPresenting, Identifiable {
    public static let title = "Mot de passe"
    public static let hint = "Choisis un nouveau mot de passe (8 caractères minimum). Tu resteras connecté sur cet iPhone."
    public static let doneMessage = PasswordResetViewModel.doneMessage

    public nonisolated let id = UUID()
    public var newPassword = ""
    public var passwordConfirmation = ""
    public private(set) var isSaving = false
    /// True once the password was changed.
    public private(set) var isDone = false
    public var error: ErrorState?

    public let session: SessionModel

    public init(session: SessionModel) {
        self.session = session
    }

    /// Both fields filled, nothing in progress.
    public var canSave: Bool { !newPassword.isEmpty && !passwordConfirmation.isEmpty && !isSaving && !isDone }

    /// Checks the fields, then changes the password. Returns true on success (the fields are cleared).
    @discardableResult
    public func save() async -> Bool {
        guard !isSaving, !isDone else { return false }
        error = nil
        if let message = SignUpViewModel.passwordMessage(newPassword) {
            present(message: message, error: .weakPassword)
            return false
        }
        guard newPassword == passwordConfirmation else {
            present(message: PasswordResetViewModel.mismatchMessage, error: .invalidInput)
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await session.services.auth.updatePassword(newPassword)
            newPassword = ""
            passwordConfirmation = ""
            isDone = true
            return true
        } catch {
            present(error)
            return false
        }
    }
}
