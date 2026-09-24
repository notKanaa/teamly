import Foundation
import Supabase
import TeamTasksContract
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

#if os(Linux)
@testable import RealtimeV2
#endif

/// Every integration test, one at a time (timing-sensitive Realtime waits on a small machine / CI runner).
/// Skipped without `SUPABASE_URL` (set by `scripts/swift-docker.mjs it` and the CI).
@Suite(.serialized, .enabled(if: IntegrationEnvironment.isConfigured, "SUPABASE_URL is not set"))
struct IntegrationTests {}

/// Settings of the integration tests, from the environment set by `scripts/swift-docker.mjs it` (and the CI):
/// `SUPABASE_URL`, `SUPABASE_KEY` (publishable key), `MAILPIT_URL`, `REALTIME_IT` (`0` skips the Realtime tests).
enum IntegrationEnvironment {
    static let configuration: SupabaseConfiguration? = {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["SUPABASE_URL"], !rawURL.isEmpty, let url = URL(string: rawURL),
              let key = environment["SUPABASE_KEY"], !key.isEmpty
        else { return nil }
        return SupabaseConfiguration(url: url, publishableKey: key)
    }()

    static var isConfigured: Bool { configuration != nil }

    static var realtimeEnabled: Bool {
        ProcessInfo.processInfo.environment["REALTIME_IT"] != "0"
    }

    static var mailpitURL: URL? {
        ProcessInfo.processInfo.environment["MAILPIT_URL"].flatMap { URL(string: $0) }
    }

    /// A new client session ("device") with its own in-memory session storage.
    static func makeServices() throws -> AppServices {
        SupabaseBackend.services(for: try makeContext())
    }

    /// Same, keeping the context (Realtime client, Auth client) for white-box checks.
    static func makeContext(sockets: WebSocketRegistry = WebSocketRegistry()) throws -> SupabaseContext {
        let configuration = try unwrapConfiguration()
        #if os(Linux)
        return SupabaseContext(
            configuration: configuration,
            authStorage: InMemoryAuthStorage(),
            now: { Date() },
            realtimeFactory: { client in linuxRealtimeClient(configuration: configuration, client: client, sockets: sockets) }
        )
        #else
        return SupabaseContext(configuration: configuration, authStorage: InMemoryAuthStorage(), now: { Date() })
        #endif
    }

    #if os(Linux)
    /// The Realtime client `SupabaseClient` would build (same URL, headers and access token source), on the
    /// `LinuxWebSocket` transport (the libcurl of the Linux image has no WebSocket support).
    static func linuxRealtimeClient(
        configuration: SupabaseConfiguration,
        client: SupabaseClient,
        sockets: WebSocketRegistry
    ) -> RealtimeClientV2 {
        let url = configuration.url.appendingPathComponent("realtime").appendingPathComponent("v1")
        let auth = client.auth
        let options = RealtimeClientOptions(
            headers: ["apikey": configuration.publishableKey, "Authorization": "Bearer \(configuration.publishableKey)"],
            accessToken: { try? await auth.session.accessToken }
        )
        let template = RealtimeClientV2(url: url, options: options)
        return RealtimeClientV2(
            url: url,
            options: options,
            wsTransport: { url, headers in
                let socket = try await LinuxWebSocket.connect(url: url, headers: headers)
                sockets.add(socket)
                return socket
            },
            http: template.http,
            clock: ContinuousClock()
        )
    }
    #endif

    static func unwrapConfiguration() throws -> SupabaseConfiguration {
        guard let configuration else { throw ContractFailure("SUPABASE_URL / SUPABASE_KEY are not set") }
        return configuration
    }

    /// A fresh, unique e-mail address (the local stack does not check domains).
    static func uniqueEmail(_ prefix: String = "it") -> String {
        "\(prefix)-\(UUID().uuidString.prefix(13).lowercased())@example.com"
    }

    static let password = "motdepasse-it-2026"
}

/// The WebSockets opened by one test client (Linux transport), so a test can simulate a network loss.
final class WebSocketRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [AnyObject] = []

    func add(_ socket: AnyObject) {
        lock.lock()
        sockets.append(socket)
        lock.unlock()
    }

    var all: [AnyObject] {
        lock.lock()
        defer { lock.unlock() }
        return sockets
    }
}

/// Runs the backend-agnostic contract scenarios against the Supabase adapters and a real local stack.
/// `makeUser` signs up a brand-new account through the adapter, on a client session of its own.
struct SupabaseHarness: ContractHarness {
    func makeUser(displayName: String) async throws -> ContractUser {
        try await Self.signUp(displayName: displayName, services: IntegrationEnvironment.makeServices())
    }

    static func signUp(displayName: String, services: AppServices) async throws -> ContractUser {
        let email = IntegrationEnvironment.uniqueEmail()
        let password = IntegrationEnvironment.password
        let outcome = try await services.auth.signUp(email: email, password: password, displayName: displayName)
        guard outcome == .signedIn, let user = await services.auth.currentUser() else {
            throw ContractFailure("sign-up of \(email) did not open a session (\(outcome))")
        }
        return ContractUser(authUser: user, displayName: displayName, email: email, password: password, services: services)
    }
}
