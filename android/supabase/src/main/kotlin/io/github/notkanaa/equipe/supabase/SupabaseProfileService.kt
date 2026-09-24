package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.ProfileService
import io.github.notkanaa.equipe.core.PushService
import io.github.notkanaa.equipe.core.UserProfile

/** [ProfileService] on PostgREST (docs/CONTRACTS.md §4.3). Port of SupabaseProfileService.swift. */
internal class SupabaseProfileService(private val context: SupabaseContext) : ProfileService {
    /** No visible profile for the session user means the account no longer exists → [AppError.NotAuthenticated]. */
    override suspend fun myProfile(): UserProfile {
        val rows = context.rest.fetchAll(ProfileRow::decode) { RestQuery.myProfile(it.userId) }
        return rows.firstOrNull()?.profile ?: throw AppError.NotAuthenticated
    }

    /** `PATCH profiles?id=eq.<me>` with the trimmed name; 0 rows updated → [AppError.Forbidden]. */
    override suspend fun updateDisplayName(name: String): UserProfile {
        val validName = InputValidation.displayName(name)
        val rows = context.rest.fetchAll(ProfileRow::decode) { RestQuery.updateDisplayName(it.userId, validName) }
        return rows.firstOrNull()?.profile ?: throw AppError.Forbidden
    }
}

/** [PushService] on the `enable_push` / `disable_push` RPCs and `push_subscriptions` (docs/CONTRACTS.md §4, §7). */
internal class SupabasePushService(private val context: SupabaseContext) : PushService {
    override suspend fun currentTopic(): String? {
        val rows = context.rest.fetchAll(PushTopicRow::decode) { RestQuery.pushTopic(it.userId) }
        return rows.firstOrNull()?.topic
    }

    override suspend fun enable(): String =
        context.rest.fetch({ it.stringValue() ?: throw MalformedAnswer("expected a string") }) { RestQuery.rpc("enable_push") }

    override suspend fun disable() {
        context.rest.send { RestQuery.rpc("disable_push") }
    }
}
