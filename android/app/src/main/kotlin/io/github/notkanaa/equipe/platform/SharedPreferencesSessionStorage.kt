package io.github.notkanaa.equipe.platform

import android.content.Context
import androidx.core.content.edit
import io.github.notkanaa.equipe.supabase.SessionStorage

/**
 * The Supabase Auth session, in the app's private SharedPreferences file [FILE_NAME]: without it users would be signed
 * out at every launch. Like the iOS Keychain item « this device only », it is excluded from cloud backups and device
 * transfers (android:allowBackup="false" and res/xml/data_extraction_rules.xml).
 *
 * supabase-kt calls it from Dispatchers.IO: writes are committed synchronously.
 */
class SharedPreferencesSessionStorage(context: Context) : SessionStorage {
    private val preferences = context.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    override fun load(): String? = preferences.getString(KEY_SESSION, null)

    override fun save(session: String) {
        preferences.edit(commit = true) { putString(KEY_SESSION, session) }
    }

    override fun clear() {
        preferences.edit(commit = true) { remove(KEY_SESSION) }
    }

    companion object {
        const val FILE_NAME: String = "equipe.session"
        private const val KEY_SESSION = "session"
    }
}
