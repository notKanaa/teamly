import Foundation

/// Every error surfaced to the UI. Backends map their errors to these cases (see `BackendErrorMapper`).
public enum AppError: Error, Sendable, Hashable {
    // Auth
    case notAuthenticated
    case invalidCredentials
    case emailAlreadyUsed
    case weakPassword
    case invalidEmail
    case otpInvalid
    case emailRateLimited
    case emailNotConfirmed

    // Input validation
    case invalidDisplayName
    case invalidName
    case invalidTitle
    case invalidDetails
    case invalidInput

    // Groups / membership
    case invalidCode
    case rateLimited
    case lastAdmin
    case notMember
    case cannotRemoveSelf

    // Tasks
    case assigneeNotMember
    case tooManyAssignees

    // v2 (docs/CONTRACTS-V2.md §3)
    /// `invalid_color`, `invalid_emoji`: a group or avatar color / emoji.
    case invalidAppearance
    /// `invalid_recurrence`: the rule's shape (interval, weekdays, time zone).
    case invalidRecurrence
    /// `recurrence_requires_due_date`: a recurring task without due date.
    case recurrenceNeedsDueDate
    /// `invalid_rotation`: 2–20 distinct members, on a recurring task (also `set_task_assignees` on a rotating task).
    case invalidRotation
    /// `invalid_item_title`: a checklist item title.
    case invalidChecklistItem
    /// `too_many_items`: more than 30 checklist items.
    case tooManyChecklistItems

    // Generic
    case forbidden
    case forbiddenFields
    case notFound
    case conflict
    case network
    case misconfigured
    case unknown(String)

    /// Message shown to the user (French UI).
    public var messageFR: String {
        switch self {
        case .notAuthenticated: "Votre session a expiré. Reconnectez-vous."
        case .invalidCredentials: "E-mail ou mot de passe incorrect."
        case .emailAlreadyUsed: "Un compte existe déjà avec cet e-mail."
        case .weakPassword: "Mot de passe trop faible (8 caractères minimum)."
        case .invalidEmail: "Adresse e-mail invalide."
        case .otpInvalid: "Code invalide ou expiré."
        case .emailRateLimited: "Trop d’e-mails envoyés. Réessayez plus tard."
        case .emailNotConfirmed: "Confirmez d’abord votre adresse e-mail."
        case .invalidDisplayName: "Le nom doit contenir entre 1 et 50 caractères."
        case .invalidName: "Le nom du groupe doit contenir entre 1 et 60 caractères."
        case .invalidTitle: "Le titre doit contenir entre 1 et 200 caractères."
        case .invalidDetails: "La description ne doit pas dépasser 5000 caractères."
        case .invalidInput: "Certaines informations sont invalides."
        case .invalidCode: "Code d’invitation invalide."
        case .rateLimited: "Trop de tentatives. Réessayez dans une heure."
        case .lastAdmin: "Vous êtes le seul admin\u{00A0}: nommez d’abord un autre admin."
        case .notMember: "Cette personne ne fait pas partie du groupe."
        case .cannotRemoveSelf: "Utilisez «\u{00A0}Quitter le groupe\u{00A0}» pour vous retirer vous-même."
        case .assigneeNotMember: "Une personne assignée ne fait pas partie du groupe."
        case .tooManyAssignees: "20 personnes assignées au maximum."
        case .invalidAppearance: "Couleur ou emoji invalide."
        case .invalidRecurrence: "Répétition invalide."
        case .recurrenceNeedsDueDate: "Choisissez une échéance pour répéter la tâche."
        case .invalidRotation: "Le tour de rôle demande de 2 à 20 membres du groupe."
        case .invalidChecklistItem: "Un élément doit contenir entre 1 et 200 caractères."
        case .tooManyChecklistItems: "30 éléments au maximum."
        case .forbidden: "Action non autorisée."
        case .forbiddenFields: "Vous pouvez seulement changer le statut de cette tâche."
        case .notFound: "Élément introuvable. Il a peut-être été supprimé."
        case .conflict: "Cet élément existe déjà."
        case .network: "Connexion impossible. Vérifiez votre réseau."
        case .misconfigured: "L’application n’est pas configurée (Supabase)."
        case let .unknown(detail): "Une erreur est survenue. (\(detail))"
        }
    }
}

extension AppError: LocalizedError {
    public var errorDescription: String? { messageFR }
}

extension AppError {
    /// Wraps any error into an `AppError` (already-mapped errors pass through).
    public static func wrap(_ error: any Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if error is CancellationError { return .unknown("annulé") }
        return .unknown(String(describing: error))
    }
}
