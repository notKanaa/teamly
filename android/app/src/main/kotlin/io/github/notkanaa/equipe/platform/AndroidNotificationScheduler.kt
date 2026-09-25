package io.github.notkanaa.equipe.platform

import android.Manifest
import android.content.Context
import android.os.Build
import io.github.notkanaa.equipe.core.LocalNotification
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.NotificationScheduler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * [NotificationScheduler] on NotificationManager + AlarmManager (iOS `UserNotificationScheduler`; docs/CONTRACTS.md
 * §7).
 *
 * - Immediate notifications (« Nouvelle tâche », summaries) are posted right away in the « Tâches » channel.
 * - Reminders (a fire date) become inexact `setAndAllowWhileIdle` alarms fired by [ReminderAlarmReceiver]; a fire date
 *   already past is skipped, like iOS. Android cannot list alarms: the pending ones are kept in SharedPreferences and
 *   cross-checked with the system (an alarm lost to a reboot or a force-stop is no longer reported pending, so the next
 *   synchronization schedules it again); [NotificationRescheduleReceiver] sets them again after a reboot.
 * - The POST_NOTIFICATIONS permission (Android 13+) is asked through the activity ([NotificationPermissionBridge]).
 *   Taps open the task through its `equipe://` deep link.
 *
 * Stateless apart from SharedPreferences: safe to call from any thread.
 */
class AndroidNotificationScheduler(context: Context) : NotificationScheduler {
    private val context: Context = context.applicationContext
    private val store = PendingNotificationStore(this.context)

    override suspend fun authorizationStatus(): NotificationAuthorization = withContext(Dispatchers.IO) {
        TaskNotifications.authorization(context, store.permissionRequested)
    }

    /**
     * Shows the system dialog on Android 13+ when the permission is not granted (the core only asks when the status is
     * « not determined »). Returns false without asking when no activity is on screen.
     */
    override suspend fun requestAuthorization(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !TaskNotifications.hasPermission(context)) {
            val granted = NotificationPermissionBridge.request(Manifest.permission.POST_NOTIFICATIONS) ?: return false
            store.permissionRequested = true
            if (!granted) return false
        }
        return authorizationStatus() == NotificationAuthorization.AUTHORIZED
    }

    override suspend fun pendingIdentifiers(prefix: String): List<String> = withContext(Dispatchers.IO) {
        val (alive, lost) = store.all()
            .filter { it.id.startsWith(prefix) }
            .partition { ReminderAlarms.isScheduled(context, it.id) }
        store.remove(lost.map { it.id })
        alive.map { it.id }
    }

    override suspend fun add(notification: LocalNotification) {
        withContext(Dispatchers.IO) {
            val scheduled = ScheduledNotification.from(notification)
            val fireAt = scheduled.fireAtMillis
            when {
                fireAt == null -> TaskNotifications.post(context, scheduled)
                // The fire date passed between planning and now: a reminder in the past is useless.
                fireAt <= System.currentTimeMillis() -> Unit
                else -> {
                    ReminderAlarms.schedule(context, scheduled)
                    store.save(scheduled)
                }
            }
        }
    }

    override suspend fun removePending(ids: List<String>) {
        if (ids.isEmpty()) return
        withContext(Dispatchers.IO) {
            for (id in ids) ReminderAlarms.cancel(context, id)
            store.remove(ids)
        }
    }

    /** No app badge count on Android: launchers show a dot for the app's notifications. */
    override suspend fun setBadge(count: Int) = Unit
}
