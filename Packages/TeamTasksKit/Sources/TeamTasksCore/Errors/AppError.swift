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

    // v3 (docs/CONTRACTS-V3.md §10)
    /// `task_done`: nudging a task that is already done.
    case taskDone
    /// `nudge_no_recipient`: nobody but the caller is assigned to the task.
    case nudgeNoRecipient
    /// `nudge_rate_limited`: the caller already nudged this task in the last 20 hours.
    case nudgeRateLimited
    /// `invalid_away`: the away dates (order, end in the past, longer than 366 days).
    case invalidAway
    /// `not_your_turn`: proposing the turn of an occurrence the caller does not hold.
    case notYourTurn
    /// `swap_pending`: a proposal is already waiting for this task.
    case swapPending
    /// `swap_not_pending`: answering or cancelling a proposal that is no longer pending.
    case swapNotPending
    /// `invalid_reaction`: an emoji outside the « Bravo » set.
    case invalidReaction
    /// `invalid_comment`: a comment of 0 or more than 1000 characters.
    case invalidComment
    /// `invalid_mentions`: a mention that is not a member of the group (or duplicated, or more than 20).
    case invalidMentions
    /// `invalid_photo`: a photo refused (size, format, path, object missing).
    case invalidPhoto
    /// `photo_limit`: a sixth photo on a task.
    case photoLimit

    // Generic
    case forbidden
    case forbiddenFields
    case notFound
    case conflict
    case network
    case misconfigured
    case unknown(String)

    /// Message shown to the user (French UI, addressing the user with « tu », docs/CONTRACTS-V2.md §13).
    public var messageFR: String {
        switch self {
        case .notAuthenticated: "Ta session a expiré. Reconnecte-toi."
        case .invalidCredentials: "E-mail ou mot de passe incorrect."
        case .emailAlreadyUsed: "Un compte existe déjà avec cet e-mail."
        case .weakPassword: "Mot de passe trop faible (8 caractères minimum)."
        case .invalidEmail: "Adresse e-mail invalide."
        case .otpInvalid: "Code invalide ou expiré."
        case .emailRateLimited: "Trop d’e-mails envoyés. Réessaie plus tard."
        case .emailNotConfirmed: "Confirme d’abord ton adresse e-mail."
        case .invalidDisplayName: "Le nom doit contenir entre 1 et 50 caractères."
        case .invalidName: "Le nom du groupe doit contenir entre 1 et 60 caractères."
        case .invalidTitle: "Le titre doit contenir entre 1 et 200 caractères."
        case .invalidDetails: "La description ne doit pas dépasser 5000 caractères."
        case .invalidInput: "Certaines informations sont invalides."
        case .invalidCode: "Code d’invitation invalide."
        case .rateLimited: "Trop de tentatives. Réessaie dans une heure."
        case .lastAdmin: "Tu es l’unique admin\u{00A0}: nomme d’abord un autre admin."
        case .notMember: "Cette personne ne fait pas partie du groupe."
        case .cannotRemoveSelf: "Pour te retirer du groupe, utilise «\u{00A0}Quitter le groupe\u{00A0}»."
        case .assigneeNotMember: "Une personne assignée ne fait pas partie du groupe."
        case .tooManyAssignees: "20 personnes assignées au maximum."
        case .invalidAppearance: "Couleur ou emoji invalide."
        case .invalidRecurrence: "Répétition invalide."
        case .recurrenceNeedsDueDate: "Choisis une échéance pour répéter la tâche."
        case .invalidRotation: "Le tour de rôle demande de 2 à 20 membres du groupe."
        case .invalidChecklistItem: "Un élément doit contenir entre 1 et 200 caractères."
        case .tooManyChecklistItems: "30 éléments au maximum."
        case .taskDone: "Cette tâche est déjà terminée."
        case .nudgeNoRecipient: "Personne d’autre n’est assigné à cette tâche."
        case .nudgeRateLimited: "Tu as déjà relancé cette tâche aujourd’hui."
        case .invalidAway: "Dates d’absence invalides."
        case .notYourTurn: "Ce n’est pas ton tour."
        case .swapPending: "Une proposition est déjà en attente pour cette tâche."
        case .swapNotPending: "Cette proposition n’est plus en attente."
        case .invalidReaction: "Réaction invalide."
        case .invalidComment: "Un commentaire doit contenir entre 1 et 1000 caractères."
        case .invalidMentions: "Une personne mentionnée ne fait pas partie du groupe."
        case .invalidPhoto: "Photo invalide."
        case .photoLimit: "5 photos au maximum par tâche."
        case .forbidden: "Action non autorisée."
        case .forbiddenFields: "Tu peux seulement changer le statut de cette tâche."
        case .notFound: "Élément introuvable. Il a peut-être été supprimé."
        case .conflict: "Cet élément existe déjà."
        case .network: "Connexion impossible. Vérifie ton réseau."
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
