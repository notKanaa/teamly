package io.github.notkanaa.equipe.ui.settings

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PersistableBundle
import android.provider.Settings
import androidx.core.net.toUri
import io.github.notkanaa.equipe.core.viewmodel.SettingsViewModel

/** The system and third-party screens the « Réglages » tab opens. */
internal object SettingsActions {
    /** The app's notification settings (to allow notifications refused earlier), else its app info screen. */
    fun openNotificationSettings(context: Context) {
        val notifications = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        if (start(context, notifications)) return
        val appDetails = Uri.fromParts("package", context.packageName, null)
        start(context, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, appDetails))
    }

    /** Opens (subscribes to) the topic in the ntfy app through its `ntfy://` link, or its store page when missing. */
    fun openNtfy(context: Context, appUrl: String) {
        if (start(context, Intent(Intent.ACTION_VIEW, appUrl.toUri()))) return
        openNtfyStorePage(context)
    }

    /** The Play Store page of the free ntfy app (the web page when there is no Play Store). */
    fun openNtfyStorePage(context: Context) {
        val webPage = SettingsViewModel.NTFY_PLAY_STORE_URL.toUri()
        val packageId = webPage.getQueryParameter("id")
        if (packageId != null && start(context, Intent(Intent.ACTION_VIEW, "market://details?id=$packageId".toUri()))) {
            return
        }
        start(context, Intent(Intent.ACTION_VIEW, webPage))
    }

    /**
     * Copies the ntfy topic, flagged as sensitive: whoever knows it can read this user's pushes, so Android 13+ hides
     * it from the clipboard preview and keyboard suggestions.
     */
    fun copySensitive(context: Context, label: String, text: String) {
        val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return
        val clip = ClipData.newPlainText(label, text)
        clip.description.extras = PersistableBundle().apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            } else {
                putBoolean("android.content.extra.IS_SENSITIVE", true)
            }
        }
        clipboard.setPrimaryClip(clip)
    }

    private fun start(context: Context, intent: Intent): Boolean = try {
        context.startActivity(intent)
        true
    } catch (error: ActivityNotFoundException) {
        false
    }
}
