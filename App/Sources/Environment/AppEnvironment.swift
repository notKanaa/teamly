import Foundation
import TeamTasksCore
import TeamTasksMocks
import TeamTasksSupabase

/// The backend and platform services chosen once at launch.
///
/// - `-uiTestMockBackend` (UI tests, demos): in-memory backend of TeamTasksMocks with the French demo data,
///   in the state given by `-mockScenario <signedOut|populated|emptyGroups>` (default `signedOut`). Optional:
///   `-mockLatencyMs <n>` (artificial latency of every call) and
///   `-mockNotifications <notDetermined|denied|authorized>` (initial permission of the in-app notification fake).
///   Nothing is persisted and no system prompt is ever shown.
/// - Otherwise: the Supabase project of Info.plist (`SupabaseScheme`, `SupabaseHost`, `SupabasePublishableKey`),
///   local notifications through `UNUserNotificationCenter`, settings in `UserDefaults`.
struct AppEnvironment: Sendable {
    enum Backend: Sendable, Equatable {
        case mock(MockScenario)
        case supabase(URL)
    }

    static let mockBackendArgument = "-uiTestMockBackend"
    static let mockLatencyArgument = "-mockLatencyMs"
    static let mockNotificationsArgument = "-mockNotifications"

    let backend: Backend
    let services: AppServices
    let platform: PlatformServices

    /// True with the in-memory backend (UI tests): no background refresh, no system permission prompt.
    var isMock: Bool {
        if case .mock = backend { return true }
        return false
    }

    /// The environment for these launch arguments and this bundle's Info.plist.
    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bundle: Bundle = .main
    ) -> Result<AppEnvironment, ConfigurationIssue> {
        if arguments.contains(mockBackendArgument) {
            return .success(mock(arguments: arguments))
        }
        return SupabaseSettings.configuration(from: bundle).map { configuration in
            AppEnvironment(
                backend: .supabase(configuration.url),
                services: SupabaseBackend.makeServices(configuration: configuration),
                platform: devicePlatform()
            )
        }
    }

    // MARK: - Mock backend

    static func mock(arguments: [String]) -> AppEnvironment {
        let scenario = MockEnvironment.scenario(fromLaunchArguments: arguments) ?? .signedOut
        let latencyMilliseconds = integer(after: mockLatencyArgument, in: arguments) ?? 0
        let mock = MockEnvironment.make(scenario: scenario, latency: .milliseconds(max(0, latencyMilliseconds)))
        let platform = PlatformServices(
            notifications: InAppNotificationScheduler(status: notificationStatus(in: arguments)),
            store: InMemoryKeyValueStore(),
            now: { Date() },
            // The demo due dates are wall-clock times in Europe/Paris: show them as such whatever the
            // simulator's time zone, so screenshots are stable.
            calendar: DemoData.calendar
        )
        return AppEnvironment(backend: .mock(scenario), services: mock.services, platform: platform)
    }

    private static func notificationStatus(in arguments: [String]) -> NotificationAuthorization {
        switch string(after: mockNotificationsArgument, in: arguments) {
        case "authorized": .authorized
        case "denied": .denied
        default: .notDetermined
        }
    }

    private static func string(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func integer(after flag: String, in arguments: [String]) -> Int? {
        string(after: flag, in: arguments).flatMap { Int($0) }
    }

    // MARK: - Device

    /// Platform services of a real device (docs/CONTRACTS.md §7).
    static func devicePlatform() -> PlatformServices {
        PlatformServices(
            notifications: UserNotificationScheduler(),
            store: UserDefaultsKeyValueStore(),
            now: { Date() },
            calendar: AppCalendar.french
        )
    }
}
