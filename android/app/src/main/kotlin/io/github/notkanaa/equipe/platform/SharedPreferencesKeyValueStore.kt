package io.github.notkanaa.equipe.platform

import android.content.Context
import android.util.Base64
import androidx.core.content.edit
import io.github.notkanaa.equipe.core.KeyValueStore

/**
 * [KeyValueStore] on the app's private SharedPreferences file [FILE_NAME] (iOS `UserDefaultsKeyValueStore`): reminder
 * lead time, « Mes tâches » last-seen dates, assignment notification cursors, reminder fingerprints. Values are stored
 * as Base64 strings. Thread-safe (SharedPreferences is); writes are applied asynchronously.
 */
class SharedPreferencesKeyValueStore(context: Context) : KeyValueStore {
    private val preferences = context.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    override fun data(key: String): ByteArray? {
        val encoded = preferences.getString(key, null) ?: return null
        return try {
            Base64.decode(encoded, Base64.NO_WRAP)
        } catch (error: IllegalArgumentException) {
            null
        }
    }

    override fun set(key: String, data: ByteArray?) {
        preferences.edit {
            if (data == null) remove(key) else putString(key, Base64.encodeToString(data, Base64.NO_WRAP))
        }
    }

    companion object {
        const val FILE_NAME: String = "equipe.store"
    }
}
