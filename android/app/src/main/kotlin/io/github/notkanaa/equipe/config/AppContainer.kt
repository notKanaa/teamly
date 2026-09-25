package io.github.notkanaa.equipe.config

import android.content.Context
import androidx.annotation.MainThread
import io.github.notkanaa.equipe.BuildConfig
import io.github.notkanaa.equipe.core.viewmodel.AppModel
import io.github.notkanaa.equipe.platform.BackgroundRefresh
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Process-wide owner of the root [AppModel] (iOS `AppContainer.shared`), created on first use. Several entry points
 * need the same model: the activity, the notification taps (deep links) and the background refresh worker, which can
 * run in a process started without any activity.
 *
 * Main thread only.
 */
class AppContainer internal constructor(context: Context) {
    private val context: Context = context.applicationContext

    /** What the app runs with. */
    sealed interface Launch {
        /** The backend is configured: the app runs with this model. */
        class Ready internal constructor(
            val appModel: AppModel,
            val environment: AppEnvironment,
            /**
             * Main-thread scope of [appModel] (`SupervisorJob() + Dispatchers.Main.immediate`). Also runs the actions
             * that must complete even if their screen goes away (sign-in, password reset, sign-out, account deletion).
             */
            val scope: CoroutineScope,
        ) : Launch

        /** No usable Supabase settings: the « Configuration manquante » screen is shown. */
        class Misconfigured internal constructor(val issue: ConfigurationIssue) : Launch
    }

    private val current = MutableStateFlow<Launch?>(null)

    /** The current launch (null until [launch] is first called). Changes only when a debug mock launch starts. */
    val launches: StateFlow<Launch?> = current.asStateFlow()

    /** The root model, null when misconfigured or not launched yet. */
    val appModel: AppModel? get() = (current.value as? Launch.Ready)?.appModel

    /**
     * The current launch, created on first use: the debug build's mock scenario if any, else the Supabase project of
     * BuildConfig (or « Configuration manquante »).
     */
    @MainThread
    fun launch(): Launch {
        current.value?.let { return it }
        val created = createDefault()
        current.value = created
        return created
    }

    /**
     * Debug builds: replaces the current launch with a fresh in-memory backend (every UI test launch starts from the
     * demo data, even when the process is reused). No-op in release builds.
     */
    @MainThread
    fun startMock(options: MockLaunchOptions) {
        if (!BuildConfig.MOCK_BACKEND_AVAILABLE) return
        (current.value as? Launch.Ready)?.scope?.cancel()
        current.value = ready(AppEnvironment.mock(options))
    }

    private fun createDefault(): Launch {
        if (BuildConfig.MOCK_BACKEND_AVAILABLE) {
            MockLaunchOptions.fromBuildConfig()?.let { return ready(AppEnvironment.mock(it)) }
        }
        return when (val resolution = SupabaseSettings.resolve()) {
            is SupabaseSettings.Resolution.Configured ->
                ready(AppEnvironment.supabase(context, resolution.configuration))
            is SupabaseSettings.Resolution.Misconfigured -> Launch.Misconfigured(resolution.issue)
        }
    }

    private fun ready(environment: AppEnvironment): Launch.Ready {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val appModel = AppModel(environment.services, environment.platform, scope)
        appModel.start()
        if (!environment.isMock) {
            BackgroundRefresh.followSession(context, appModel, scope)
        }
        return Launch.Ready(appModel, environment, scope)
    }

    // region App events

    private var hasBeenInBackground = false

    /** The app left the screen (activity stopped, not for a configuration change). */
    @MainThread
    fun onAppBackground() {
        hasBeenInBackground = true
    }

    /**
     * The app is on screen again: only a real return from the background reloads (the first start is covered by the
     * session's own start), like iOS.
     */
    @MainThread
    fun onAppForeground() {
        if (!hasBeenInBackground) return
        hasBeenInBackground = false
        val ready = current.value as? Launch.Ready ?: return
        ready.scope.launch { ready.appModel.handleForeground() }
    }

    /** Clock, date (midnight) or time zone changed. Ignored until the app is launched. */
    @MainThread
    fun onSignificantTimeChange() {
        val ready = current.value as? Launch.Ready ?: return
        ready.scope.launch { ready.appModel.handleSignificantTimeChange() }
    }

    /**
     * Opens an `equipe://` URL (applied when a session is active, kept for the next one otherwise). Returns false when
     * the URL is not ours or the app is misconfigured.
     */
    @MainThread
    fun open(url: String): Boolean {
        val appModel = (launch() as? Launch.Ready)?.appModel ?: return false
        return appModel.open(url)
    }

    // endregion
}
