import Foundation
import TeamTasksCore

/// A ready-to-use mock backend for the app (UI tests, previews) and unit tests.
public struct MockEnvironment: Sendable {
    public let scenario: MockScenario
    public let backend: InMemoryBackend
    /// Services of the app's "device", in the scenario's session state.
    public let services: AppServices
    /// The signed-in demo user, nil for `.signedOut`.
    public let signedInUser: DemoUser?

    /// - `.signedOut`: demo data (§8), no session.
    /// - `.populated`: demo data, signed in as Camille (U1).
    /// - `.emptyGroups`: demo data plus `DemoData.newcomer`, signed in as that user who belongs to no group.
    /// - `.showcase`: demo data plus the v2 content of `DemoData.Showcase`, signed in as Camille.
    public static func make(
        scenario: MockScenario,
        now: @escaping NowProvider = { Date() },
        calendar: Calendar = DemoData.calendar,
        latency: Duration = .zero
    ) -> MockEnvironment {
        let backend: InMemoryBackend
        let user: DemoUser?
        switch scenario {
        case .signedOut:
            backend = InMemoryBackend.demo(now: now, calendar: calendar, latency: latency)
            user = nil
        case .populated:
            backend = InMemoryBackend.demo(now: now, calendar: calendar, latency: latency)
            user = DemoData.camille
        case .emptyGroups:
            backend = InMemoryBackend.demo(now: now, calendar: calendar, latency: latency)
            backend.addNewcomerAccount()
            user = DemoData.newcomer
        case .showcase:
            backend = InMemoryBackend.showcase(now: now, calendar: calendar, latency: latency)
            user = DemoData.camille
        }
        return MockEnvironment(
            scenario: scenario,
            backend: backend,
            services: backend.services(for: user?.id),
            signedInUser: user
        )
    }

    /// Reads `-mockScenario <rawValue>` from launch arguments.
    public static func scenario(fromLaunchArguments arguments: [String]) -> MockScenario? {
        guard let index = arguments.firstIndex(of: "-mockScenario"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return MockScenario(rawValue: arguments[index + 1])
    }
}
