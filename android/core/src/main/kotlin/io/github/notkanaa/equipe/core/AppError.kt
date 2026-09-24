package io.github.notkanaa.equipe.core

import kotlin.coroutines.cancellation.CancellationException

/**
 * Every error surfaced to the UI. Backends map their errors to these cases (see [BackendErrorMapper]).
 * Port of TeamTasksCore/Errors/AppError.swift: same cases, same French messages ([messageFR], also the exception
 * message).
 *
 * The cases without payload are singletons, so they are created without a stack trace and without suppressed
 * exceptions (a shared instance must not accumulate state). Compare with `==` or `is`.
 */
sealed class AppError(
    /** Message shown to the user (French UI). */
    val messageFR: String,
) : Exception(messageFR, null, false, false) {
    // Auth
    data object NotAuthenticated : AppError("Votre session a expiré. Reconnectez-vous.")
    data object InvalidCredentials : AppError("E-mail ou mot de passe incorrect.")
    data object EmailAlreadyUsed : AppError("Un compte existe déjà avec cet e-mail.")
    data object WeakPassword : AppError("Mot de passe trop faible (8 caractères minimum).")
    data object InvalidEmail : AppError("Adresse e-mail invalide.")
    data object OtpInvalid : AppError("Code invalide ou expiré.")
    data object EmailRateLimited : AppError("Trop d’e-mails envoyés. Réessayez plus tard.")
    data object EmailNotConfirmed : AppError("Confirmez d’abord votre adresse e-mail.")

    // Input validation
    data object InvalidDisplayName : AppError("Le nom doit contenir entre 1 et 50 caractères.")
    data object InvalidName : AppError("Le nom du groupe doit contenir entre 1 et 60 caractères.")
    data object InvalidTitle : AppError("Le titre doit contenir entre 1 et 200 caractères.")
    data object InvalidDetails : AppError("La description ne doit pas dépasser 5000 caractères.")
    data object InvalidInput : AppError("Certaines informations sont invalides.")

    // Groups / membership
    data object InvalidCode : AppError("Code d’invitation invalide.")
    data object RateLimited : AppError("Trop de tentatives. Réessayez dans une heure.")
    data object LastAdmin : AppError("Vous êtes le seul admin : nommez d’abord un autre admin.")
    data object NotMember : AppError("Cette personne ne fait pas partie du groupe.")
    data object CannotRemoveSelf : AppError("Utilisez « Quitter le groupe » pour vous retirer vous-même.")

    // Tasks
    data object AssigneeNotMember : AppError("Une personne assignée ne fait pas partie du groupe.")
    data object TooManyAssignees : AppError("20 personnes assignées au maximum.")

    // Generic
    data object Forbidden : AppError("Action non autorisée.")
    data object ForbiddenFields : AppError("Vous pouvez seulement changer le statut de cette tâche.")
    data object NotFound : AppError("Élément introuvable. Il a peut-être été supprimé.")
    data object Conflict : AppError("Cet élément existe déjà.")
    data object Network : AppError("Connexion impossible. Vérifiez votre réseau.")
    data object Misconfigured : AppError("L’application n’est pas configurée (Supabase).")
    data class Unknown(val detail: String) : AppError("Une erreur est survenue. ($detail)")

    companion object {
        /**
         * Every case without payload, in declaration order (Swift has no `CaseIterable` here; used by tests and
         * wording checks). A getter, not a stored list: nested objects must not be read during class initialization.
         */
        val simpleCases: List<AppError>
            get() = listOf(
                NotAuthenticated, InvalidCredentials, EmailAlreadyUsed, WeakPassword, InvalidEmail, OtpInvalid,
                EmailRateLimited, EmailNotConfirmed, InvalidDisplayName, InvalidName, InvalidTitle, InvalidDetails,
                InvalidInput, InvalidCode, RateLimited, LastAdmin, NotMember, CannotRemoveSelf, AssigneeNotMember,
                TooManyAssignees, Forbidden, ForbiddenFields, NotFound, Conflict, Network, Misconfigured,
            )

        /**
         * Wraps any error into an [AppError] (already-mapped errors pass through). A coroutine cancellation becomes
         * `Unknown("annulé")` like Swift's `CancellationError`: callers that must let cancellation propagate should
         * rethrow [CancellationException] before wrapping.
         */
        fun wrap(error: Throwable): AppError = when (error) {
            is AppError -> error
            is CancellationException -> Unknown("annulé")
            else -> Unknown(error.toString())
        }
    }
}
