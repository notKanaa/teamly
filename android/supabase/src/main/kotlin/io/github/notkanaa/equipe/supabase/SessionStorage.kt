package io.github.notkanaa.equipe.supabase

import io.github.jan.supabase.auth.SessionManager
import io.github.jan.supabase.auth.exception.NoSessionFoundException
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/**
 * Where the Auth session of a client is persisted between launches: one serialized session (an opaque string: store
 * it as is), or nothing.
 *
 * The Android app provides an implementation on SharedPreferences (private to the app; exclude it from backups, like
 * the iOS Keychain item that is « this device only »). The calls are made from a background thread
 * (`Dispatchers.IO`) and must not throw for an ordinary absence: [load] returns null.
 */
interface SessionStorage {
    /** The stored session, or null when there is none. */
    fun load(): String?

    /** Stores [session], replacing any previous one. */
    fun save(session: String)

    /** Removes the stored session (sign-out, dead session, deleted account). */
    fun clear()

    /**
     * Nothing is persisted: the session only lives in the memory of the client built by
     * [SupabaseBackend.makeServices], so every client (a test « device », a preview) starts signed out and clients never
     * share a session.
     */
    object InMemory : SessionStorage {
        override fun load(): String? = null

        override fun save(session: String) = Unit

        override fun clear() = Unit
    }
}

/**
 * supabase-kt's [SessionManager] on a [SessionStorage]: the session is serialized as JSON (the format of supabase-kt's
 * own settings storage). [latest] keeps the last saved or loaded session in memory, so that the adapters still know
 * the user while supabase-kt holds no current session (an expired token whose refresh failed offline).
 *
 * A storage failure never fails the Auth call that saves the session: the session then only lives in memory.
 */
internal class StorageSessionManager(private val storage: SessionStorage) : SessionManager {
    @Volatile
    var latest: UserSession? = null
        private set

    override suspend fun saveSession(session: UserSession) {
        latest = session
        val text = json.encodeToString(UserSession.serializer(), session)
        io { storage.save(text) }
    }

    override suspend fun loadSession(): UserSession {
        val text = io { storage.load() } ?: throw NoSessionFoundException()
        val session = decode(text) ?: run {
            // Unreadable (e.g. written by an incompatible version): as if signed out.
            io { storage.clear() }
            throw NoSessionFoundException()
        }
        latest = session
        return session
    }

    override suspend fun deleteSession() {
        latest = null
        io { storage.clear() }
    }

    private suspend fun <T> io(block: () -> T): T? = try {
        withContext(Dispatchers.IO) { block() }
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        null
    }

    companion object {
        /** Like supabase-kt's settings storage: defaults are encoded (`expiresAt` must be kept). */
        val json: Json = Json {
            encodeDefaults = true
            ignoreUnknownKeys = true
        }

        fun decode(text: String): UserSession? = try {
            json.decodeFromString(UserSession.serializer(), text)
        } catch (error: IllegalArgumentException) { // SerializationException included
            null
        }
    }
}
