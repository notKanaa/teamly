package io.github.notkanaa.equipe.platform

import android.Manifest
import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.core.net.toUri
import io.github.notkanaa.equipe.MainActivity
import io.github.notkanaa.equipe.R
import io.github.notkanaa.equipe.core.LocalNotification
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.logic.ReminderPlanner
import io.github.notkanaa.equipe.core.viewmodel.DeepLink
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** A local notification as stored for its alarm and handed to [ReminderAlarmReceiver] (JSON). */
@Serializable
internal data class ScheduledNotification(
    val id: String,
    val title: String,
    val body: String,
    /** Delivery date in epoch milliseconds; null: deliver now. */
    val fireAtMillis: Long? = null,
    /** Routing of a tap: `taskId`, `groupId` (UUID strings). */
    val userInfo: Map<String, String> = emptyMap(),
    val threadId: String? = null,
) {
    fun encoded(): String = json.encodeToString(serializer(), this)

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun from(notification: LocalNotification): ScheduledNotification = ScheduledNotification(
            id = notification.id,
            title = notification.title,
            body = notification.body,
            fireAtMillis = notification.fireDate?.toEpochMilli(),
            userInfo = notification.userInfo,
            threadId = notification.threadId,
        )

        fun decode(text: String?): ScheduledNotification? {
            if (text == null) return null
            return try {
                json.decodeFromString(serializer(), text)
            } catch (error: IllegalArgumentException) { // SerializationException included
                null
            }
        }
    }
}

/**
 * The pending reminders (alarm set, not fired yet) in the private SharedPreferences file [FILE_NAME]: Android cannot
 * list the alarms of an app, iOS can list its pending requests. Also remembers whether the notification permission was
 * asked (Android cannot tell « never asked » from « refused »).
 */
internal class PendingNotificationStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    fun all(): List<ScheduledNotification> = preferences.all.mapNotNull { (key, value) ->
        if (key.startsWith(PENDING_PREFIX)) ScheduledNotification.decode(value as? String) else null
    }

    fun save(notification: ScheduledNotification) {
        preferences.edit { putString(PENDING_PREFIX + notification.id, notification.encoded()) }
    }

    fun remove(ids: Collection<String>) {
        if (ids.isEmpty()) return
        preferences.edit {
            for (id in ids) remove(PENDING_PREFIX + id)
        }
    }

    /** True once the system permission dialog was shown (Android 13+). */
    var permissionRequested: Boolean
        get() = preferences.getBoolean(KEY_PERMISSION_REQUESTED, false)
        set(value) = preferences.edit { putBoolean(KEY_PERMISSION_REQUESTED, value) }

    companion object {
        const val FILE_NAME: String = "equipe.notifications"
        private const val PENDING_PREFIX = "pending:"
        private const val KEY_PERMISSION_REQUESTED = "permissionRequested"
    }
}

/**
 * The alarms of the due-date reminders: inexact `setAndAllowWhileIdle` alarms (no exact-alarm permission; the system
 * may deliver them a few minutes late in Doze), one per notification id, firing [ReminderAlarmReceiver].
 */
internal object ReminderAlarms {
    const val ACTION_FIRE: String = "io.github.notkanaa.equipe.action.FIRE_REMINDER"
    private const val EXTRA_NOTIFICATION = "io.github.notkanaa.equipe.extra.NOTIFICATION"
    private const val URI_SCHEME = "equipe-reminder"

    /** Sets (or replaces) the alarm of [notification]. Throws when the system refuses it (e.g. too many alarms). */
    fun schedule(context: Context, notification: ScheduledNotification) {
        val fireAt = requireNotNull(notification.fireAtMillis) { "A reminder needs a fire date." }
        val intent = intent(context, notification.id).putExtra(EXTRA_NOTIFICATION, notification.encoded())
        val operation = PendingIntent.getBroadcast(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        alarmManager(context).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, operation)
    }

    /**
     * True while the alarm of [id] is set. The system forgets every alarm (and its PendingIntent) on reboot and when
     * the app is force-stopped: the stored list alone would claim them pending.
     */
    fun isScheduled(context: Context, id: String): Boolean = existing(context, id) != null

    /** Cancels the alarm of [id] (no-op when none). */
    fun cancel(context: Context, id: String) {
        val operation = existing(context, id) ?: return
        alarmManager(context).cancel(operation)
        operation.cancel()
    }

    /** The notification an alarm intent carries. */
    fun notification(intent: Intent): ScheduledNotification? {
        if (intent.action != ACTION_FIRE) return null
        return ScheduledNotification.decode(intent.getStringExtra(EXTRA_NOTIFICATION))
    }

    private fun intent(context: Context, id: String): Intent =
        Intent(context, ReminderAlarmReceiver::class.java)
            .setAction(ACTION_FIRE)
            // The data makes every notification's PendingIntent distinct (extras are not compared).
            .setData(Uri.fromParts(URI_SCHEME, id, null))

    private fun existing(context: Context, id: String): PendingIntent? = PendingIntent.getBroadcast(
        context,
        0,
        intent(context, id),
        PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun alarmManager(context: Context): AlarmManager = context.getSystemService(AlarmManager::class.java)
}

/** The « Tâches » notification channel and the notifications themselves. */
internal object TaskNotifications {
    const val CHANNEL_ID: String = "tasks"

    /** Every notification uses this number; its string id (`due-…`, `assigned-…`, `summary-…`) is the tag. */
    private const val NOTIFICATION_NUMBER = 1

    /** Creates (or updates) the « Tâches » channel: high importance, like the iOS banners with sound. */
    fun createChannel(context: Context) {
        val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_HIGH)
            .setName(context.getString(R.string.notification_channel_tasks))
            .setDescription(context.getString(R.string.notification_channel_tasks_description))
            .build()
        NotificationManagerCompat.from(context).createNotificationChannel(channel)
    }

    /** The POST_NOTIFICATIONS runtime permission (Android 13+; always granted before). */
    fun hasPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    /** Notifications can be shown: permission granted, the app's notifications and the « Tâches » channel enabled. */
    fun areEnabled(context: Context): Boolean {
        if (!hasPermission(context)) return false
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return false
        val channel = manager.getNotificationChannelCompat(CHANNEL_ID)
        return channel == null || channel.importance != NotificationManagerCompat.IMPORTANCE_NONE
    }

    /**
     * Android has no « not determined » state once the dialog was shown: a refusal, a dismissed dialog and a later
     * change in the system settings all read as [NotificationAuthorization.DENIED] (Réglages then offers to open the
     * system settings, like iOS).
     */
    fun authorization(context: Context, permissionRequested: Boolean): NotificationAuthorization = when {
        !hasPermission(context) ->
            if (permissionRequested) NotificationAuthorization.DENIED else NotificationAuthorization.NOT_DETERMINED
        areEnabled(context) -> NotificationAuthorization.AUTHORIZED
        else -> NotificationAuthorization.DENIED
    }

    /** Shows [notification] now (no-op when notifications are not allowed). A tap opens its deep link. */
    @SuppressLint("MissingPermission") // Checked by areEnabled().
    fun post(context: Context, notification: ScheduledNotification) {
        if (!areEnabled(context)) return
        createChannel(context)
        val isReminder = notification.id.startsWith(ReminderPlanner.IDENTIFIER_PREFIX)
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_equipe)
            .setColor(ContextCompat.getColor(context, R.color.notification_accent))
            .setContentTitle(notification.title)
            .setContentText(notification.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(notification.body))
            .setContentIntent(contentIntent(context, notification))
            .setAutoCancel(true)
            .setWhen(notification.fireAtMillis ?: System.currentTimeMillis())
            .setShowWhen(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
        if (isReminder) builder.setCategory(NotificationCompat.CATEGORY_REMINDER)
        try {
            NotificationManagerCompat.from(context).notify(notification.id, NOTIFICATION_NUMBER, builder.build())
        } catch (error: SecurityException) {
            // The permission was revoked in the meantime: nothing to show.
        }
    }

    /**
     * Opens the task (both ids), the group (only `groupId`: a grouped summary) or « Mes tâches » through the activity's
     * `equipe://` deep link handling (docs/CONTRACTS.md §7).
     */
    private fun contentIntent(context: Context, notification: ScheduledNotification): PendingIntent {
        val link = DeepLink.fromNotification(notification.userInfo)
        val intent = Intent(Intent.ACTION_VIEW, link.url.toUri(), context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
