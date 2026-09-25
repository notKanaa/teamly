package io.github.notkanaa.equipe

import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.os.SystemClock
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import io.github.notkanaa.equipe.config.AppContainer
import io.github.notkanaa.equipe.config.MockLaunchOptions
import io.github.notkanaa.equipe.core.viewmodel.AppPhase
import io.github.notkanaa.equipe.navigation.EquipeApp
import io.github.notkanaa.equipe.platform.NotificationPermissionBridge

/**
 * The only activity (portrait, edge-to-edge, not recreated by configuration changes). Shows the system splash screen
 * while the stored session is restored, then [EquipeApp]; forwards `equipe://` links (deep links, notification taps)
 * and the foreground/background transitions to the process-wide [AppContainer].
 *
 * Debug builds: a launch intent with the `mockScenario` extra runs on a fresh in-memory backend ([MockLaunchOptions]).
 */
class MainActivity : ComponentActivity() {
    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            NotificationPermissionBridge.onResult(granted)
        }

    private val container: AppContainer
        get() = (application as EquipeApplication).container

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        NotificationPermissionBridge.attach(notificationPermission)

        // A recreated activity (the system reclaimed it in the background) keeps the running launch and must not open
        // the link of its original intent again.
        val isNewLaunch = savedInstanceState == null
        if (isNewLaunch) {
            MockLaunchOptions.fromIntent(intent)?.let(container::startMock)
        }
        container.launch()

        // The system splash covers the (usually instant) session restore; past a second, the Compose splash with its
        // progress indicator takes over.
        val splashStart = SystemClock.uptimeMillis()
        splashScreen.setKeepOnScreenCondition {
            container.appModel?.phase == AppPhase.Launching &&
                SystemClock.uptimeMillis() - splashStart < SPLASH_SCREEN_MAX_MILLIS
        }

        if (isNewLaunch) openDeepLink(intent)

        setContent {
            EquipeApp(container)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        openDeepLink(intent)
    }

    override fun onStart() {
        super.onStart()
        container.onAppForeground()
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) container.onAppBackground()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Dark mode changes do not recreate the activity: the system bar icons must follow the new theme.
        enableEdgeToEdge()
    }

    override fun onDestroy() {
        NotificationPermissionBridge.detach(notificationPermission)
        super.onDestroy()
    }

    /** `equipe://task/<groupId>/<taskId>` (and group, mytasks): shown now, or once a session starts. */
    private fun openDeepLink(intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return
        // Reopened from the recent apps: its link was already handled.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        val url = intent.dataString ?: return
        container.open(url)
    }

    private companion object {
        const val SPLASH_SCREEN_MAX_MILLIS = 1_000L
    }
}
