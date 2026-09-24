import Foundation
import Supabase
import TeamTasksCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Entry point of the Supabase adapters: builds the Core services for one client session.
public enum SupabaseBackend {
    /// The services of the app, backed by the Supabase project of `configuration`. The session is persisted in
    /// the Keychain on Apple platforms (in memory elsewhere, e.g. on Linux): this device only, never in backups
    /// (`KeychainAuthStorage`), and removed on the first launch of a new installation, since iOS keeps Keychain
    /// items when an app is deleted (`SessionStorageSetup`). Call it once per launch.
    public static func makeServices(configuration: SupabaseConfiguration) -> AppServices {
        #if canImport(Security)
        let storage = KeychainAuthStorage(service: KeychainAuthStorage.appService)
        if let marker = InstallationMarker.applicationSupport() {
            SessionStorageSetup.removeSessionsOfAPreviousInstallation(
                marker: marker,
                storages: [storage, KeychainAuthStorage(service: KeychainAuthStorage.legacyService)]
            )
        }
        return makeServices(configuration: configuration, authStorage: storage)
        #else
        return makeServices(configuration: configuration, authStorage: InMemoryAuthStorage())
        #endif
    }

    /// Same, with an explicit session storage (tests use one `InMemoryAuthStorage` per simulated device).
    /// - Parameter realtimeFactory: builds the Realtime client from the Supabase client (default:
    ///   `SupabaseClient.realtimeV2`). The Linux integration tests use it to plug a WebSocket transport, since
    ///   the libcurl of Linux distributions usually has no WebSocket support.
    static func makeServices(
        configuration: SupabaseConfiguration,
        authStorage: any AuthLocalStorage,
        now: @escaping @Sendable () -> Date = { Date() },
        realtimeFactory: (@Sendable (SupabaseClient) -> RealtimeClientV2)? = nil
    ) -> AppServices {
        services(for: SupabaseContext(
            configuration: configuration, authStorage: authStorage, now: now, realtimeFactory: realtimeFactory
        ))
    }

    static func services(for context: SupabaseContext) -> AppServices {
        AppServices(
            auth: SupabaseAuthService(context: context),
            profiles: SupabaseProfileService(context: context),
            groups: SupabaseGroupService(context: context),
            tasks: SupabaseTaskService(context: context),
            realtime: SupabaseRealtimeService(context: context),
            push: SupabasePushService(context: context)
        )
    }
}

/// Everything the services of one client session share: the supabase-swift client (Auth, Realtime) and the
/// PostgREST client of the adapters.
final class SupabaseContext: Sendable {
    let client: SupabaseClient
    let realtime: RealtimeClientV2
    let rest: RestClient
    let publishableKey: String
    let now: @Sendable () -> Date

    /// - Parameters:
    ///   - realtimeFactory: Realtime client for this session (default: `client.realtimeV2`).
    ///   - transport: PostgREST transport (unit tests answer with fixtures).
    ///   - credentials: credentials of the PostgREST requests; defaults to the Auth session of `client`.
    init(
        configuration: SupabaseConfiguration,
        authStorage: any AuthLocalStorage,
        now: @escaping @Sendable () -> Date,
        realtimeFactory: (@Sendable (SupabaseClient) -> RealtimeClientV2)? = nil,
        transport: any HTTPTransport = URLSessionTransport(session: .shared),
        credentials: (any CredentialsProvider)? = nil
    ) {
        let client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.publishableKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: authStorage,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
        self.client = client
        realtime = realtimeFactory?(client) ?? client.realtimeV2
        rest = RestClient(
            projectURL: configuration.url,
            apiKey: configuration.publishableKey,
            transport: transport,
            session: credentials ?? AuthSessionCredentials(auth: client.auth)
        )
        publishableKey = configuration.publishableKey
        self.now = now
    }

    var auth: AuthClient { client.auth }
}

/// Credentials of the Auth session: `.notAuthenticated` without a local session; the access token is refreshed
/// when it is about to expire, or when the server refused it (`refreshedCredentials(after:)`).
struct AuthSessionCredentials: CredentialsProvider {
    let auth: AuthClient

    func credentials() async throws -> Credentials {
        guard auth.currentSession != nil else { throw AppError.notAuthenticated }
        do {
            let session = try await auth.session
            return Credentials(userId: session.user.id, accessToken: session.accessToken)
        } catch {
            throw SupabaseErrorMapping.auth(error)
        }
    }

    /// supabase-swift removes the session and emits `.signedOut` when the refresh token is refused
    /// (`refresh_token_not_found`, `session_not_found`…), e.g. after the account was deleted on another device.
    func refreshedCredentials(after rejected: Credentials) async throws -> Credentials {
        guard let current = auth.currentSession else { throw AppError.notAuthenticated }
        if current.accessToken != rejected.accessToken, !current.isExpired {
            // Another request refreshed the session meanwhile.
            return Credentials(userId: current.user.id, accessToken: current.accessToken)
        }
        do {
            let session = try await auth.refreshSession()
            return Credentials(userId: session.user.id, accessToken: session.accessToken)
        } catch {
            throw SupabaseErrorMapping.auth(error)
        }
    }
}
