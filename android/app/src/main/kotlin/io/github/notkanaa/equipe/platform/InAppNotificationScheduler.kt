package io.github.notkanaa.equipe.platform

import io.github.notkanaa.equipe.core.LocalNotification
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.NotificationScheduler
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant

/**
 * In-memory [NotificationScheduler] of the mock backend (UI tests, demos; iOS `InAppNotificationScheduler`): never
 * shows the system permission dialog and never posts a real notification, so nothing covers the screens under test.
 *
 * [requestAuthorization] behaves like a user who accepts: « not determined » becomes « authorized ».
 */
class InAppNotificationScheduler(
    status: NotificationAuthorization = NotificationAuthorization.NOT_DETERMINED,
    private val now: () -> Instant = { Instant.now() },
) : NotificationScheduler {
    private val mutex = Mutex()
    private var status: NotificationAuthorization = status
    private val pending = LinkedHashMap<String, LocalNotification>()

    override suspend fun authorizationStatus(): NotificationAuthorization = mutex.withLock { status }

    override suspend fun requestAuthorization(): Boolean = mutex.withLock {
        if (status == NotificationAuthorization.NOT_DETERMINED) {
            status = NotificationAuthorization.AUTHORIZED
        }
        status == NotificationAuthorization.AUTHORIZED
    }

    override suspend fun pendingIdentifiers(prefix: String): List<String> = mutex.withLock {
        pending.keys.filter { it.startsWith(prefix) }.sorted()
    }

    override suspend fun add(notification: LocalNotification) {
        mutex.withLock {
            // Like the real scheduler: immediate notifications are « delivered », past fire dates are skipped.
            val fireDate = notification.fireDate ?: return@withLock
            if (fireDate > now()) pending[notification.id] = notification
        }
    }

    override suspend fun removePending(ids: List<String>) {
        mutex.withLock {
            for (id in ids) pending.remove(id)
        }
    }

    /** No badge in the fake (nothing is shown). */
    override suspend fun setBadge(count: Int) = Unit
}
