package io.github.notkanaa.equipe.config

import android.content.Context
import android.content.Intent
import io.github.notkanaa.equipe.BuildConfig
import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.InMemoryKeyValueStore
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.PlatformServices
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.mocks.MockEnvironment
import io.github.notkanaa.equipe.mocks.MockScenario
import io.github.notkanaa.equipe.platform.AndroidNotificationScheduler
import io.github.notkanaa.equipe.platform.InAppNotificationScheduler
import io.github.notkanaa.equipe.platform.SharedPreferencesKeyValueStore
import io.github.notkanaa.equipe.platform.SharedPreferencesSessionStorage
import io.github.notkanaa.equipe.supabase.SupabaseBackend
import io.github.notkanaa.equipe.supabase.SupabaseConfiguration
import java.time.Instant
import java.time.ZoneId
import kotlin.time.Duration.Companion.milliseconds

/**
 * A debug launch on the in-memory backend of :mocks (UI tests, demos, screenshots): the launch intent's extras
 * (`adb shell am start -n io.github.notkanaa.equipe/.MainActivity --es mockScenario populated`), or the debug build's
 * permanent scenario (`-Pequipe.mockScenario=populated`). Release builds ignore both.
 *
 * - [EXTRA_SCENARIO] `mockScenario`: `signedOut`, `populated` or `emptyGroups` (iOS `-mockScenario`);
 * - [EXTRA_NOTIFICATIONS] `mockNotifications` (optional): `notDetermined` (default), `denied` or `authorized`, the
 *   initial permission of the in-app notification fake (no system prompt, no real notification);
 * - [EXTRA_LATENCY_MS] `mockLatencyMs` (optional, string or int): artificial latency of every backend call.
 */
data class MockLaunchOptions(
    val scenario: MockScenario,
    val notifications: NotificationAuthorization = NotificationAuthorization.NOT_DETERMINED,
    val latencyMillis: Long = 0,
) {
    companion object {
        const val EXTRA_SCENARIO: String = "mockScenario"
        const val EXTRA_NOTIFICATIONS: String = "mockNotifications"
        const val EXTRA_LATENCY_MS: String = "mockLatencyMs"

        /** The options of a launch intent; null without a valid `mockScenario` extra, and always in release builds. */
        fun fromIntent(intent: Intent?): MockLaunchOptions? {
            if (!BuildConfig.MOCK_BACKEND_AVAILABLE || intent == null) return null
            val scenario = intent.getStringExtra(EXTRA_SCENARIO)?.let(MockScenario::fromRawValue) ?: return null
            val latency = intent.getStringExtra(EXTRA_LATENCY_MS)?.trim()?.toLongOrNull()
                ?: intent.getIntExtra(EXTRA_LATENCY_MS, 0).toLong()
            return MockLaunchOptions(
                scenario = scenario,
                notifications = notificationStatus(intent.getStringExtra(EXTRA_NOTIFICATIONS)),
                latencyMillis = latency.coerceAtLeast(0),
            )
        }

        /** The debug build's permanent scenario (`-Pequipe.mockScenario=…`); null otherwise and in release builds. */
        fun fromBuildConfig(): MockLaunchOptions? {
            if (!BuildConfig.MOCK_BACKEND_AVAILABLE) return null
            val scenario = MockScenario.fromRawValue(BuildConfig.MOCK_SCENARIO) ?: return null
            return MockLaunchOptions(scenario)
        }

        private fun notificationStatus(rawValue: String?): NotificationAuthorization = when (rawValue) {
            "authorized" -> NotificationAuthorization.AUTHORIZED
            "denied" -> NotificationAuthorization.DENIED
            else -> NotificationAuthorization.NOT_DETERMINED
        }
    }
}

/** The backend and platform services chosen once per launch (port of the iOS `AppEnvironment`). */
class AppEnvironment private constructor(
    val backend: Backend,
    val services: AppServices,
    val platform: PlatformServices,
) {
    sealed interface Backend {
        /** In-memory backend of :mocks (debug builds only). */
        data class Mock(val options: MockLaunchOptions) : Backend

        /** The Supabase project at [url]. */
        data class Supabase(val url: String) : Backend
    }

    /** True with the in-memory backend: no background refresh, no system permission prompt, nothing persisted. */
    val isMock: Boolean get() = backend is Backend.Mock

    companion object {
        /**
         * The Supabase backend: the Auth session persisted in SharedPreferences (excluded from backups), local
         * notifications through NotificationManager + AlarmManager, settings in SharedPreferences, the device's time
         * zone. Call it once per process ([SupabaseBackend.makeServices] builds a new client session).
         */
        fun supabase(context: Context, configuration: SupabaseConfiguration): AppEnvironment {
            val appContext = context.applicationContext
            return AppEnvironment(
                backend = Backend.Supabase(configuration.url),
                services = SupabaseBackend.makeServices(configuration, SharedPreferencesSessionStorage(appContext)),
                platform = PlatformServices(
                    notifications = AndroidNotificationScheduler(appContext),
                    store = SharedPreferencesKeyValueStore(appContext),
                    now = { Instant.now() },
                    calendar = AppCalendar.frenchGregorian(ZoneId.systemDefault()),
                ),
            )
        }

        /** The in-memory backend in the state of [options] (fresh demo data every time). */
        fun mock(options: MockLaunchOptions): AppEnvironment {
            val environment = MockEnvironment.make(options.scenario, latency = options.latencyMillis.milliseconds)
            return AppEnvironment(
                backend = Backend.Mock(options),
                services = environment.services,
                platform = PlatformServices(
                    notifications = InAppNotificationScheduler(options.notifications),
                    store = InMemoryKeyValueStore(),
                    now = { Instant.now() },
                    // The demo due dates are wall-clock times in Europe/Paris: shown as such whatever the device's
                    // time zone, so that screenshots are stable (like iOS).
                    calendar = DemoData.calendar,
                ),
            )
        }
    }
}
