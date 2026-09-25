package io.github.notkanaa.equipe.platform

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.github.notkanaa.equipe.EquipeApplication
import io.github.notkanaa.equipe.config.AppContainer
import io.github.notkanaa.equipe.core.viewmodel.AppModel
import io.github.notkanaa.equipe.core.viewmodel.AppPhase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/**
 * Background refresh (iOS Background App Refresh): every 15 minutes at best, with a network connection, catches up on
 * the assignments made while the app was not running (local « Nouvelle tâche » notifications) and synchronizes the
 * due-date reminders. Works in a process started for it: the stored session is restored first.
 */
class BackgroundRefreshWorker(
    context: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val application = applicationContext as? EquipeApplication ?: return Result.success()
        // AppModel and its services are main-thread confined.
        withContext(Dispatchers.Main.immediate) {
            val launch = application.container.launch() as? AppContainer.Launch.Ready ?: return@withContext
            if (!launch.environment.isMock) launch.appModel.handleBackgroundRefresh()
        }
        return Result.success()
    }
}

/** Schedules [BackgroundRefreshWorker] while a user is signed in. */
object BackgroundRefresh {
    /** Unique periodic work name. */
    const val WORK_NAME: String = "equipe.backgroundRefresh"

    /** The shortest period WorkManager allows. */
    private const val INTERVAL_MINUTES = 15L

    /**
     * Keeps the periodic work in step with the session of [appModel]: enqueued (kept if already there) when a user is
     * signed in, cancelled once signed out. Runs in [scope] (the model's scope).
     */
    fun followSession(context: Context, appModel: AppModel, scope: CoroutineScope) {
        val appContext = context.applicationContext
        scope.launch {
            appModel.state
                .map { state ->
                    when (state.phase) {
                        is AppPhase.SignedIn -> true
                        AppPhase.SignedOut -> false
                        // Launching, password recovery: unchanged.
                        else -> null
                    }
                }
                .distinctUntilChanged()
                .collect { signedIn ->
                    when (signedIn) {
                        true -> schedule(appContext)
                        false -> cancel(appContext)
                        null -> Unit
                    }
                }
        }
    }

    private fun schedule(context: Context) {
        val request = PeriodicWorkRequestBuilder<BackgroundRefreshWorker>(INTERVAL_MINUTES, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        workManager(context)?.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    private fun cancel(context: Context) {
        workManager(context)?.cancelUniqueWork(WORK_NAME)
    }

    private fun workManager(context: Context): WorkManager? = try {
        WorkManager.getInstance(context)
    } catch (error: IllegalStateException) { // Not initialized (e.g. a test process without App Startup).
        null
    }
}

/**
 * Clock set, time zone changed, or the date changed (midnight): the date wording (« Aujourd’hui », « En retard ») and
 * the reminders depend on it (iOS `significantTimeChangeNotification`). Registered for the whole process.
 */
object SignificantTimeChanges {
    fun register(context: Context, onChange: () -> Unit) {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
            addAction(Intent.ACTION_DATE_CHANGED)
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                onChange()
            }
        }
        // System broadcasts only: nothing from other apps.
        ContextCompat.registerReceiver(
            context.applicationContext,
            receiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }
}
