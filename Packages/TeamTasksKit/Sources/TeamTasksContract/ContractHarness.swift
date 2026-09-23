import Foundation
import TeamTasksCore

/// A backend under test (in-memory mocks, or the Supabase adapters against a real server).
///
/// Scenarios only use `makeUser` plus the public service API, so they run unchanged against any backend:
/// they create their own fresh users and groups, never rely on seed data and never travel in time.
///
/// Implementing a harness:
/// - `makeUser` signs up a brand-new account (unique e-mail, e-mail confirmation disabled) on a new client
///   session ("device") of its own, and returns it signed in. The display name must be stored as given.
/// - Timestamps must come from the backend: scenarios compare server timestamps with each other only
///   (e.g. `assignments(since: previousEvent.assignedAt)` must exclude that event, so adapters must send
///   `since` with full precision).
/// - Realtime scenarios wait for `.connected`, then for the expected event with a bounded wait
///   (`StreamProbe`, 10 s by default). Rate limiting and password recovery are backend-specific tests.
/// - Where docs/CONTRACTS.md leaves an error precedence open, scenarios accept either error (`Verify.fails(withAnyOf:)`).
public protocol ContractHarness: Sendable {
    /// Creates a brand-new account (unique e-mail) with this display name and returns it signed in.
    func makeUser(displayName: String) async throws -> ContractUser
}

/// A signed-in user and the services of its own client session ("device").
public struct ContractUser: Sendable {
    public let authUser: AuthUser
    /// The display name given at sign-up.
    public let displayName: String
    /// E-mail and password of the account (auth scenarios sign out and back in).
    public let email: String
    public let password: String
    public let services: AppServices

    public init(authUser: AuthUser, displayName: String, email: String, password: String, services: AppServices) {
        self.authUser = authUser
        self.displayName = displayName
        self.email = email
        self.password = password
        self.services = services
    }

    public var id: UUID { authUser.id }
    public var auth: any AuthService { services.auth }
    public var profiles: any ProfileService { services.profiles }
    public var groups: any GroupService { services.groups }
    public var tasks: any TaskService { services.tasks }
    public var realtime: any RealtimeService { services.realtime }
    public var push: any PushService { services.push }
}

/// One backend-agnostic behaviour check derived from docs/CONTRACTS.md.
public struct ContractScenario: Sendable, CustomStringConvertible {
    public let name: String
    public let run: @Sendable (any ContractHarness) async throws -> Void

    public init(_ name: String, run: @escaping @Sendable (any ContractHarness) async throws -> Void) {
        self.name = name
        self.run = run
    }

    public var description: String { name }
}

/// Every contract scenario. Run each one with a fresh harness (or at least fresh users, which they create).
public enum ContractScenarios {
    public static let all: [ContractScenario] =
        authScenarios
        + profileScenarios
        + groupScenarios
        + memberScenarios
        + matrixScenarios
        + taskScenarios
        + readScenarios
        + realtimeScenarios
        + pushScenarios
        + accountScenarios

    public static func named(_ name: String) -> ContractScenario? {
        all.first { $0.name == name }
    }
}
