import Foundation
import Supabase
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

/// Credentials whose refresh is scripted: tokens `jeton-1`, `jeton-2`… (tests only).
final class ScriptedCredentials: CredentialsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var token = 1
    private var refreshes = 0
    private let refreshError: AppError?
    let userId: UUID

    /// - Parameter refreshError: thrown by every refresh (a dead session: `.notAuthenticated`); nil: refreshes work.
    init(userId: UUID = Seed.camille, refreshError: AppError? = nil) {
        self.userId = userId
        self.refreshError = refreshError
    }

    var refreshCount: Int { lock.withLock { refreshes } }

    func credentials() async throws -> Credentials {
        lock.withLock { Credentials(userId: userId, accessToken: "jeton-\(token)") }
    }

    func refreshedCredentials(after rejected: Credentials) async throws -> Credentials {
        try lock.withLock {
            refreshes += 1
            if let refreshError { throw refreshError }
            token += 1
            return Credentials(userId: userId, accessToken: "jeton-\(token)")
        }
    }
}

extension UnitBackend {
    static func services(_ transport: FakeTransport, credentials: any CredentialsProvider) -> AppServices {
        SupabaseBackend.services(for: SupabaseContext(
            configuration: configuration,
            authStorage: InMemoryAuthStorage(),
            now: { Date() },
            transport: transport,
            credentials: credentials
        ))
    }
}

/// A request whose session the server refuses is sent again once after a refresh; a dead session is not
/// (review ADP-3). Account deletion treats « account already gone » as done (review VM-2).
@Suite struct SessionRefusalTests {
    static let jwtRefused = #"{"code":"PGRST301","details":null,"hint":null,"message":"JWT cryptographic operation failed"}"#
    static let accountGone = #"{"code":"P0001","details":null,"hint":null,"message":"not_authenticated"}"#

    // MARK: - RestClient

    /// A token refused before its local expiry (signing key rotated, clock behind): refreshed, and the request is
    /// sent again with the new token.
    @Test func refusedTokenIsRefreshedAndTheRequestSentAgain() async throws {
        let credentials = ScriptedCredentials()
        let transport = FakeTransport([.json(401, Self.jwtRefused), .fixture(200, "my_groups")])
        let groups = try await UnitBackend.services(transport, credentials: credentials).groups.myGroups()
        #expect(groups.map(\.id) == [Seed.lilas, Seed.sport])
        #expect(credentials.refreshCount == 1)
        #expect(transport.sent.map { $0.headers["authorization"] } == ["Bearer jeton-1", "Bearer jeton-2"])
        #expect(transport.sent[0].target == transport.sent[1].target)
    }

    @Test func rpcIsSentAgainWithTheSameBody() async throws {
        let credentials = ScriptedCredentials()
        let transport = FakeTransport([.json(401, Self.jwtRefused), .json(204, "")])
        try await UnitBackend.services(transport, credentials: credentials).groups.leave(groupId: Seed.lilas)
        #expect(transport.sent.count == 2)
        #expect(transport.sent[1].body == transport.sent[0].body)
        #expect(transport.sent[1].headers["authorization"] == "Bearer jeton-2")
    }

    /// A dead session (revoked, account deleted): the refresh fails (and supabase-swift signs the device out);
    /// the request is not sent again.
    @Test func deadSessionIsNotSentAgain() async throws {
        let credentials = ScriptedCredentials(refreshError: .notAuthenticated)
        let transport = FakeTransport([.json(400, Self.accountGone)])
        let groups = UnitBackend.services(transport, credentials: credentials).groups
        await #expect(throws: AppError.notAuthenticated) { try await groups.createGroup(name: "Encore") }
        #expect(credentials.refreshCount == 1)
        #expect(transport.sent.count == 1)
    }

    @Test func offlineRefreshIsANetworkError() async throws {
        let credentials = ScriptedCredentials(refreshError: .network)
        let transport = FakeTransport([.json(401, Self.jwtRefused)])
        let groups = UnitBackend.services(transport, credentials: credentials).groups
        await #expect(throws: AppError.network) { try await groups.myGroups() }
        #expect(transport.sent.count == 1)
    }

    /// At most one refresh per request.
    @Test func secondRefusalIsFinal() async throws {
        let credentials = ScriptedCredentials()
        let transport = FakeTransport([.json(401, Self.jwtRefused), .json(401, Self.jwtRefused)])
        let groups = UnitBackend.services(transport, credentials: credentials).groups
        await #expect(throws: AppError.notAuthenticated) { try await groups.myGroups() }
        #expect(credentials.refreshCount == 1)
        #expect(transport.sent.count == 2)
    }

    /// Other errors never refresh.
    @Test func otherErrorsDoNotRefresh() async throws {
        let credentials = ScriptedCredentials()
        let transport = FakeTransport([
            .json(403, #"{"code":"42501","details":null,"hint":null,"message":"forbidden"}"#),
            .json(503, #"{"code":"PGRST002","message":"Could not query the database for the schema cache. Retrying."}"#),
        ])
        let groups = UnitBackend.services(transport, credentials: credentials).groups
        await #expect(throws: AppError.forbidden) { try await groups.leave(groupId: Seed.lilas) }
        await #expect(throws: AppError.unknown(SupabaseErrorMapping.serverUnavailable)) { try await groups.myGroups() }
        #expect(credentials.refreshCount == 0)
        #expect(transport.sent.count == 2)
    }

    // MARK: - Account deletion

    /// « Réessayer » after a lost answer: `delete_my_account` says the token's account no longer exists. That is
    /// the requested end state: success, without a refresh.
    @Test func deletingAnAlreadyDeletedAccountSucceeds() async throws {
        let credentials = ScriptedCredentials(refreshError: .notAuthenticated)
        let transport = FakeTransport([.json(400, Self.accountGone)])
        try await UnitBackend.services(transport, credentials: credentials).auth.deleteAccount()
        #expect(credentials.refreshCount == 0)
        #expect(transport.sent.map(\.target) == ["rpc/delete_my_account"])
    }

    @Test func deletionWithARefusedTokenRefreshesOnce() async throws {
        let credentials = ScriptedCredentials()
        let transport = FakeTransport([.json(401, Self.jwtRefused), .json(204, "")])
        try await UnitBackend.services(transport, credentials: credentials).auth.deleteAccount()
        #expect(credentials.refreshCount == 1)
        #expect(transport.sent.map { $0.headers["authorization"] } == ["Bearer jeton-1", "Bearer jeton-2"])
    }

    @Test func deletionWithADeadSessionFails() async throws {
        let credentials = ScriptedCredentials(refreshError: .notAuthenticated)
        let transport = FakeTransport([.json(401, Self.jwtRefused)])
        let auth = UnitBackend.services(transport, credentials: credentials).auth
        await #expect(throws: AppError.notAuthenticated) { try await auth.deleteAccount() }
        #expect(transport.sent.count == 1)
    }

    @Test func deletionErrorsAreStillReported() async throws {
        let transport = FakeTransport([.failure(.notConnectedToInternet)])
        let auth = UnitBackend.services(transport, credentials: ScriptedCredentials()).auth
        await #expect(throws: AppError.network) { try await auth.deleteAccount() }
    }

    /// With the real Auth session: the account already gone → success and local sign-out.
    @Test(.timeLimit(.minutes(1))) func deletingAnAlreadyDeletedAccountSignsOutLocally() async throws {
        var session = try JSONDecoder.supabase().decode(Session.self, from: Data(AuthUnitTests.sessionJSON.utf8))
        session.expiresAt = Date().timeIntervalSince1970 + 3600
        let storage = InMemoryAuthStorage()
        try storage.store(key: "sb-127-auth-token", value: JSONEncoder().encode(session))
        let transport = FakeTransport([.json(400, Self.accountGone)])
        let services = SupabaseBackend.services(for: SupabaseContext(
            configuration: UnitBackend.configuration,
            authStorage: storage,
            now: { Date() },
            transport: transport
        ))
        #expect(await services.auth.currentUser()?.id == Seed.camille)
        try await services.auth.deleteAccount()
        #expect(await services.auth.currentUser() == nil)
        #expect(transport.sent.map { $0.headers["authorization"] } == ["Bearer jeton"])
    }
}

/// Forward compatibility of list reads (review ADP-4): a value added to a server enum by a later migration leaves
/// only its row out.
@Suite struct LossyDecodingTests {
    @Test func unknownTaskStatusLeavesOnlyThatTaskOut() async throws {
        let rows = try String(decoding: Fixture.data("group_tasks"), as: UTF8.self)
        let newer = rows.replacingOccurrences(of: #""status":"in_progress""#, with: #""status":"blocked""#)
        #expect(newer != rows)
        let tasks = try await UnitBackend.services(FakeTransport([.json(200, newer)])).tasks
            .tasks(groupId: Seed.lilas, includeOldDone: true)
        #expect(tasks.count == 4)
        #expect(!tasks.contains { $0.id == Seed.courses })
        #expect(tasks.contains { $0.id == Seed.poubelles } && tasks.contains { $0.id == Seed.cuisine })
    }

    @Test func unknownPriorityInMyTasks() async throws {
        let rows = try String(decoding: Fixture.data("my_tasks"), as: UTF8.self)
        let newer = rows.replacingOccurrences(of: #""priority":"high""#, with: #""priority":"urgent""#)
        #expect(newer != rows)
        let tasks = try await UnitBackend.services(FakeTransport([.json(200, newer)])).tasks.myTasks(includeDone: true)
        #expect(tasks.map(\.id) == [Seed.cuisine, Seed.courses])
    }

    @Test func unknownRoleLeavesOnlyThatMembershipOut() async throws {
        let json = try String(decoding: Fixture.data("my_groups"), as: UTF8.self)
        let newer = json.replacingOccurrences(of: #""role":"member""#, with: #""role":"owner""#)
        #expect(newer != json)
        let groups = try await UnitBackend.services(FakeTransport([.json(200, newer)])).groups.myGroups()
        #expect(groups.map(\.id) == [Seed.lilas])

        let members = try String(decoding: Fixture.data("members"), as: UTF8.self)
        let newerMembers = members.replacingOccurrences(of: #""role":"admin""#, with: #""role":"owner""#)
        let listed = try await UnitBackend.services(FakeTransport([.json(200, newerMembers)])).groups.members(groupId: Seed.lilas)
        #expect(listed.map(\.user.id) == [Seed.ines, Seed.lucas])
    }

    /// A single task (a link, an RPC result) with an unknown value is an unexpected answer, not « not found ».
    @Test func singleTaskWithAnUnknownValueIsAnError() async throws {
        let json = #"""
        [{"id":"b0000000-0000-4000-8000-000000000002","group_id":"a0000000-0000-4000-8000-000000000001","title":"Faire les courses","details":null,"status":"blocked","priority":"medium","due_at":null,"created_by":null,"created_at":"2026-09-21T23:52:26+00:00","updated_at":"2026-09-21T23:52:26+00:00","completed_at":null,"assignees":[]}]
        """#
        let tasks = UnitBackend.services(FakeTransport([.json(200, json)])).tasks
        await #expect(throws: AppError.unknown(SupabaseErrorMapping.unexpectedAnswer)) { try await tasks.task(id: Seed.courses) }
    }

    /// Any other malformed row still fails the whole answer.
    @Test func otherMalformedRowsStillFail() async throws {
        let rows = try String(decoding: Fixture.data("group_tasks"), as: UTF8.self)
        let broken = rows.replacingOccurrences(of: #""title":"Sortir les poubelles""#, with: #""title":null"#)
        #expect(broken != rows)
        let tasks = UnitBackend.services(FakeTransport([.json(200, broken)])).tasks
        await #expect(throws: AppError.unknown(SupabaseErrorMapping.unexpectedAnswer)) {
            try await tasks.tasks(groupId: Seed.lilas, includeOldDone: true)
        }
    }

    @Test func skippedRowsAreCounted() throws {
        let json = #"[{"role":"owner","group":{}},{"role":"admin","group":{"id":"a0000000-0000-4000-8000-000000000001","name":"G","created_by":null,"created_at":"2026-09-13T23:52:26+00:00","last_activity_at":"2026-09-13T23:52:26+00:00"}},{"role":"chef","group":{}}]"#
        let decoded = try RestDecoding.makeDecoder().decode(LossyRows<MyGroupRow>.self, from: Data(json.utf8))
        #expect(decoded.rows.map(\.role) == [.admin])
        #expect(decoded.skipped == 2)
    }
}
