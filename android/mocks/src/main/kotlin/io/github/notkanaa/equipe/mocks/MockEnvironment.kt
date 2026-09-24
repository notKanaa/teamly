package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.NowProvider
import java.time.Instant
import kotlin.time.Duration

/** Predefined states for previews and UI tests (`-mockScenario <rawValue>` launch argument). */
enum class MockScenario(val rawValue: String) {
    /** No session: the login screen is shown. */
    SIGNED_OUT("signedOut"),

    /** Signed in as the demo user with French demo groups, members and tasks. */
    POPULATED("populated"),

    /** Signed in, member of no group (empty states). */
    EMPTY_GROUPS("emptyGroups"),
    ;

    companion object {
        /** The scenario whose raw value is [rawValue], or null. */
        fun fromRawValue(rawValue: String): MockScenario? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/** A ready-to-use mock backend for the app (UI tests, previews) and unit tests (port of Swift `MockEnvironment`). */
class MockEnvironment(
    val scenario: MockScenario,
    val backend: InMemoryBackend,
    /** Services of the app's "device", in the scenario's session state. */
    val services: AppServices,
    /** The signed-in demo user, null for [MockScenario.SIGNED_OUT]. */
    val signedInUser: DemoUser?,
) {
    companion object {
        /**
         * A fresh backend with the demo data of docs/CONTRACTS.md §8 (dates relative to [now]) and the app's device:
         * - [MockScenario.SIGNED_OUT]: demo data (§8), no session.
         * - [MockScenario.POPULATED]: demo data, signed in as Camille (U1).
         * - [MockScenario.EMPTY_GROUPS]: demo data plus [DemoData.newcomer], signed in as that user who belongs to
         *   no group.
         */
        fun make(
            scenario: MockScenario,
            now: NowProvider = { Instant.now() },
            calendar: AppCalendar = DemoData.calendar,
            latency: Duration = Duration.ZERO,
        ): MockEnvironment {
            val backend = InMemoryBackend.demo(now, calendar, latency)
            val user = when (scenario) {
                MockScenario.SIGNED_OUT -> null
                MockScenario.POPULATED -> DemoData.camille
                MockScenario.EMPTY_GROUPS -> {
                    backend.addNewcomerAccount()
                    DemoData.newcomer
                }
            }
            return MockEnvironment(
                scenario = scenario,
                backend = backend,
                services = backend.services(user?.id),
                signedInUser = user,
            )
        }

        /** Reads `-mockScenario <rawValue>` from launch arguments; null when absent or unknown. */
        fun scenario(fromLaunchArguments: List<String>): MockScenario? {
            val index = fromLaunchArguments.indexOf("-mockScenario")
            if (index < 0 || index + 1 >= fromLaunchArguments.size) return null
            return MockScenario.fromRawValue(fromLaunchArguments[index + 1])
        }
    }
}
