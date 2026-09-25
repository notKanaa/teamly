package io.github.notkanaa.equipe.testing

import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.InMemoryKeyValueStore
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.PlatformServices
import io.github.notkanaa.equipe.core.viewmodel.AppModel
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.mocks.InMemoryBackend
import io.github.notkanaa.equipe.mocks.MockClock
import io.github.notkanaa.equipe.mocks.MockEnvironment
import io.github.notkanaa.equipe.mocks.MockScenario
import io.github.notkanaa.equipe.navigation.EquipeAppFrame
import io.github.notkanaa.equipe.navigation.EquipeRoot
import io.github.notkanaa.equipe.platform.InAppNotificationScheduler
import io.github.notkanaa.equipe.ui.shell.LocalMockBackend
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import java.time.Instant
import java.time.ZonedDateTime
import kotlin.math.roundToInt

/** The fixed date of the UI tests. */
object DemoTime {
    /**
     * Thursday 24 September 2026 at 21:08 in Paris: the time of the iOS reference screenshots, so that both platforms
     * show the same due texts (« Hier à 18:00 », « Aujourd’hui à 20:00 » overdue, « Demain à 18:00 »…).
     */
    val now: Instant = ZonedDateTime.of(2026, 9, 24, 21, 8, 0, 0, AppCalendar.PARIS).toInstant()
}

/**
 * The whole app on a fresh in-memory backend of :mocks: what a debug `mockScenario` launch of the activity runs
 * (`config.AppEnvironment.mock`: in-app notification fake, in-memory settings, demo calendar in Europe/Paris), with a
 * controllable [clock] instead of the device's. [Content] composes [EquipeRoot] in the activity's [EquipeAppFrame]:
 * the authentication screens, then the signed-in tabs of `MainShell`.
 *
 * Main thread (the Robolectric test thread). The iOS UI tests launch the app the same way (`-mockScenario`).
 *
 * @param notifications initial permission of the notification fake (`-mockNotifications`).
 * @param clock the backend's and the app's clock; fixed by default (screenshots), or advancing on every read so that
 *   successive changes get distinct dates (flows).
 */
class MockApp(
    val scenario: MockScenario,
    notifications: NotificationAuthorization = NotificationAuthorization.AUTHORIZED,
    val clock: MockClock = MockClock(DemoTime.now),
) {
    val environment: MockEnvironment = MockEnvironment.make(scenario, now = clock.provider)

    /** The server side: accounts, groups and tasks as every user sees them. */
    val backend: InMemoryBackend get() = environment.backend

    /** The app's main-thread scope (the activity's `AppContainer` creates the same). */
    val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val appModel: AppModel = AppModel(
        services = environment.services,
        platform = PlatformServices(
            notifications = InAppNotificationScheduler(notifications, now = clock.provider),
            store = InMemoryKeyValueStore(),
            now = clock.provider,
            calendar = DemoData.calendar,
        ),
        scope = scope,
    )

    /**
     * Like `MainActivity.onCreate`: edge-to-edge window (with the system bars of a phone, see [simulateSystemBars]),
     * then starts the app model (restores the scenario's session) and composes the activity's content.
     */
    fun launch(rule: AndroidComposeTestRule<*, out ComponentActivity>, systemBars: Boolean = true) {
        rule.activity.enableEdgeToEdge()
        if (systemBars) rule.activity.simulateSystemBars()
        appModel.start()
        rule.setContent { Content() }
    }

    /** The activity's content on the mock backend. */
    @Composable
    fun Content() {
        EquipeAppFrame {
            CompositionLocalProvider(LocalMockBackend provides true) {
                EquipeRoot(appModel = appModel, actionScope = scope)
            }
        }
    }

    /** Stops every coroutine of the app (end of the test). */
    fun close() {
        scope.cancel()
    }
}

/**
 * A signed-in session of [scenario]'s user on a fresh in-memory backend, for the tests of a single screen (no shell).
 * The notification fake refuses the permission: nothing is scheduled. [transform] may wrap the services (failures).
 */
fun mockSession(
    scenario: MockScenario = MockScenario.POPULATED,
    now: Instant = DemoTime.now,
    transform: (AppServices) -> AppServices = { it },
): SessionModel {
    val environment = MockEnvironment.make(scenario, now = { now })
    val user = checkNotNull(environment.signedInUser) { "$scenario has no signed-in user" }
    val platform = PlatformServices(
        notifications = InAppNotificationScheduler(NotificationAuthorization.DENIED, now = { now }),
        store = InMemoryKeyValueStore(),
        now = { now },
        calendar = DemoData.calendar,
    )
    return SessionModel(
        AuthUser(user.id, user.email),
        transform(environment.services),
        platform,
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    )
}

/**
 * Robolectric reports no system bars: gives the activity's window the insets of a phone with gesture navigation (a
 * 32 dp status bar, a 24 dp navigation bar), so that the edge-to-edge screens place their content as on a device and a
 * missing or doubled inset shows on the screenshots. Separate windows (dialogs, bottom sheets) keep no insets.
 */
fun ComponentActivity.simulateSystemBars(statusBarDp: Int = 32, navigationBarDp: Int = 24) {
    val density = resources.displayMetrics.density
    val statusBar = (statusBarDp * density).roundToInt()
    val navigationBar = (navigationBarDp * density).roundToInt()
    val insets = WindowInsetsCompat.Builder()
        .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, statusBar, 0, 0))
        .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, navigationBar))
        .build()
    val decorView = window.decorView
    // Every dispatch of the window (Compose requests one when it starts reading the insets) gets the phone's insets.
    ViewCompat.setOnApplyWindowInsetsListener(decorView) { view, _ -> ViewCompat.onApplyWindowInsets(view, insets) }
    decorView.requestApplyInsets()
}
