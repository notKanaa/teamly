package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.PlatformServices
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.logic.AssignmentNotifier
import io.github.notkanaa.equipe.core.logic.ChangeFeed
import io.github.notkanaa.equipe.core.logic.RealtimeCoordinator
import io.github.notkanaa.equipe.core.logic.ReminderSynchronizer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration

// Port of TeamTasksCore/ViewModels/App/SessionModel.swift.

/**
 * Everything that lives as long as one user is signed in (docs/CONTRACTS.md §7): the [ChangeFeed] observed by the
 * screens, the [RealtimeCoordinator] feeding it, and the ONE [AssignmentNotifier] and [ReminderSynchronizer] of this
 * user in this process (also used by the background refresh).
 *
 * Created and owned by `AppModel` (one per signed-in user); every signed-in view model takes it as its dependency.
 * [start] begins listening, [stop] tears everything down on sign-out.
 *
 * @param parentScope the session's work runs in [scope], a child of it (main dispatcher: `AppModel` passes its own
 *   scope); [stop] cancels [scope].
 */
class SessionModel(
    user: AuthUser,
    val services: AppServices,
    val platform: PlatformServices,
    parentScope: CoroutineScope,
    configuration: Configuration = Configuration(),
) {
    /** Tunables (tests use a zero debounce). */
    data class Configuration(
        val realtimeDebounce: Duration = RealtimeCoordinator.DEFAULT_DEBOUNCE,
        val realtimeRetryDelay: Duration = RealtimeCoordinator.DEFAULT_RETRY_DELAY,
    )

    /** Unique per session (e.g. a Compose `key(session.id)` so that nothing survives a change of account). */
    val id: UUID = UUID.randomUUID()

    private val userFlow = MutableStateFlow(user)

    /** The signed-in account (its e-mail may change during the session). */
    val userState: StateFlow<AuthUser> = userFlow.asStateFlow()

    /** `userState.value`. */
    val user: AuthUser get() = userFlow.value

    val userId: UUID = user.id

    /** Session-lifetime scope (child of the parent scope, cancelled by [stop]). */
    val scope: CoroutineScope =
        CoroutineScope(parentScope.coroutineContext + SupervisorJob(parentScope.coroutineContext[Job]))

    /** Revisions observed by the screens to know when to reload. */
    val feed: ChangeFeed = ChangeFeed()

    val notifier: AssignmentNotifier

    val reminders: ReminderSynchronizer = ReminderSynchronizer(platform)

    val realtime: RealtimeCoordinator

    /** True between [start] and [stop]. */
    @Volatile
    var isRunning: Boolean = false
        private set

    /** True once [stop] was called: the session no longer schedules anything. */
    @Volatile
    var isStopped: Boolean = false
        private set

    /** Initial catch-up and reminder synchronization started by [start] (tests wait for it). */
    internal var startupJob: Job? = null
        private set

    /**
     * « Mes tâches » of this session, shared by the tab badge ([MyTasksState.newCount]) and `MyTasksScreen` (the iOS
     * `MainTabView` owns one per session and hands it to the screen). Runs in [scope]. Android addition.
     */
    val myTasks: MyTasksViewModel by lazy { MyTasksViewModel(this, scope) }

    init {
        val groups = services.groups
        val notifier = AssignmentNotifier(
            userId = user.id,
            tasks = services.tasks,
            scheduler = platform.notifications,
            store = platform.store,
            now = platform.now,
            // The notifier treats a failure as "no name" and rethrows cancellations.
            groupName = { groupId -> groups.myGroups().firstOrNull { it.id == groupId }?.group?.name },
        )
        this.notifier = notifier
        realtime = RealtimeCoordinator(
            realtime = services.realtime,
            userId = user.id,
            feed = feed,
            scope = scope,
            groupIds = { groups.myGroups().map { it.id } },
            debounce = configuration.realtimeDebounce,
            retryDelay = configuration.realtimeRetryDelay,
            onAssigned = { assignment -> notifier.handleRealtime(assignment) },
        )
    }

    // region Lifecycle

    /**
     * Starts listening to realtime change signals and, in the background, catches up on assignments made while the app
     * was not running and synchronizes the due-date reminders. No-op when running or stopped.
     */
    fun start() {
        if (isRunning || isStopped) return
        isRunning = true
        realtime.start()
        startupJob = scope.launch { refreshNotifications() }
    }

    /**
     * Sign-out / account deletion (docs/CONTRACTS.md §7): stops the realtime coordinator, removes every pending reminder
     * and resets the assignment notifier, then cancels [scope]. Idempotent; the session cannot be restarted. The cleanup
     * is not interrupted by the cancellation of the caller.
     */
    suspend fun stop() {
        if (isStopped) return
        isStopped = true
        isRunning = false
        startupJob?.cancel()
        realtime.stop()
        withContext(NonCancellable) {
            ignoringFailures { reminders.removeAll() }
            ignoringFailures { notifier.reset() }
        }
        scope.cancel()
    }

    /** Updates the account (same user id, e.g. a new e-mail). */
    internal fun update(newUser: AuthUser) {
        if (newUser.id != userId || newUser == user) return
        userFlow.value = newUser
    }

    // endregion

    // region App events

    /**
     * Return to foreground: everything may have changed while in the background (every screen reloads, the realtime
     * group ids are fetched again), then catch-up of new assignments and reminder synchronization.
     */
    suspend fun handleForeground() {
        if (!isRunning) return
        feed.bumpAll()
        realtime.refreshGroupIds()
        refreshNotifications()
    }

    /** Background refresh (WorkManager): catch-up of new assignments and reminder synchronization. */
    suspend fun handleBackgroundRefresh() {
        if (isStopped) return
        refreshNotifications()
    }

    /** Clock or time zone changed: date wording (« Aujourd’hui », « En retard ») and reminders depend on it. */
    suspend fun handleSignificantTimeChange() {
        if (isStopped) return
        feed.bumpAll()
        synchronizeReminders()
    }

    // endregion

    // region Notifications

    /**
     * Catch-up of assignments made by others since the last one (local notifications). Errors are ignored: the cursor is
     * unchanged and the next catch-up retries.
     */
    suspend fun catchUpAssignments() {
        if (isStopped) return
        ignoringFailures { notifier.catchUp() }
    }

    /**
     * Loads « Mes tâches » and synchronizes the reminders with it. Returns false (reminders untouched) when the list
     * could not be loaded: an empty list after a network error would remove every reminder.
     */
    suspend fun synchronizeReminders(): Boolean {
        if (isStopped) return false
        val tasks = try {
            services.tasks.myTasks(includeDone = false)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            return false
        }
        synchronizeReminders(tasks)
        return true
    }

    /** Synchronizes the reminders with a SUCCESSFULLY loaded « Mes tâches » list. */
    suspend fun synchronizeReminders(myTasks: List<TaskItem>) {
        if (isStopped) return
        ignoringFailures { reminders.synchronize(myTasks, userId) }
    }

    /**
     * Asks for the notification permission when it was never asked. Returns the resulting status; when newly granted,
     * catches up and schedules the reminders right away.
     */
    suspend fun requestNotificationAuthorizationIfNeeded(): NotificationAuthorization {
        val status = platform.notifications.authorizationStatus()
        if (status != NotificationAuthorization.NOT_DETERMINED) return status
        val granted = platform.notifications.requestAuthorization()
        if (granted) {
            refreshNotifications()
        }
        return platform.notifications.authorizationStatus()
    }

    internal suspend fun refreshNotifications() {
        catchUpAssignments()
        synchronizeReminders()
    }

    // endregion

    override fun toString(): String = "SessionModel(userId=$userId, id=$id)"

    private companion object {
        /** Runs [block], ignoring its failures (the Swift counterparts cannot throw); cancellations are rethrown. */
        inline fun ignoringFailures(block: () -> Unit) {
            try {
                block()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                // Ignored.
            }
        }
    }
}
