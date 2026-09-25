package io.github.notkanaa.equipe.platform

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Fires a due-date reminder: shows it and forgets it (it is no longer pending). */
class ReminderAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val notification = ReminderAlarms.notification(intent) ?: return
        PendingNotificationStore(context).remove(listOf(notification.id))
        ReminderAlarms.cancel(context, notification.id)
        TaskNotifications.post(context, notification)
    }
}

/**
 * The system clears every alarm on reboot: the stored pending reminders are set again (those whose time passed while
 * the phone was off are dropped, like the reminders whose fire date passed before they were scheduled).
 */
class NotificationRescheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val store = PendingNotificationStore(context)
        val now = System.currentTimeMillis()
        val dropped = ArrayList<String>()
        for (notification in store.all()) {
            val fireAt = notification.fireAtMillis
            if (fireAt == null || fireAt <= now) {
                dropped.add(notification.id)
                continue
            }
            try {
                ReminderAlarms.schedule(context, notification)
            } catch (error: RuntimeException) {
                // Refused by the system: the next synchronization of the app schedules it again.
                dropped.add(notification.id)
            }
        }
        store.remove(dropped)
    }
}
