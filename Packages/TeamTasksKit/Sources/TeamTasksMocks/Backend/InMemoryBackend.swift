import Foundation
import TeamTasksCore

/// In-memory backend reproducing the SQL backend of docs/CONTRACTS.md: Auth, PostgREST reads, RPCs, the
/// permission matrix, the change signals and Realtime. Used by previews, UI tests and unit tests.
///
/// Several "devices" can act on the same backend: `services(for:)` returns an `AppServices` bound to its own
/// session. Every access goes through one lock; a write runs on a copy of the data and is committed only if it
/// succeeds (like a Postgres transaction). Realtime events are delivered while the lock is held, so every
/// subscriber receives them in commit order. Streams are never finished by the backend (consumers cancel).
public final class InMemoryBackend: @unchecked Sendable {
    /// Password-recovery code accepted by `verifyRecoveryCode` after `sendPasswordReset` (deterministic mock).
    public static let recoveryCode = "123456"
    /// Lifetime of a recovery code (Supabase `otp_expiry`).
    public static let recoveryCodeLifetime: TimeInterval = 3600
    /// `join_group_by_code`: once the caller has this many failed attempts in the last hour, every further
    /// attempt (even with a valid code) throws `.rateLimited` and is not logged.
    public static let maxFailedJoinsPerHour = 10
    public static let joinRateLimitWindow: TimeInterval = 3600
    public static let pushTopicPrefix = "equipe-"
    /// Group ids watched by one Realtime subscription (the first ones of the list). The real server fails the
    /// whole channel from about 70 ids in one `id=in.(…)` filter (index row size limit): adapters must cap too.
    public static let maxRealtimeGroups = 60

    /// Calendar used for demo dates.
    public let calendar: Calendar
    /// Artificial latency of every service call (SwiftUI previews). Zero by default.
    public let latency: Duration

    let nowProvider: NowProvider
    private let lock = NSLock()
    // Guarded by `lock`.
    private var data = BackendData()
    private var sessions: [UUID: SessionRecord] = [:]
    private var subscribers: [UUID: RealtimeSubscriber] = [:]

    struct SessionRecord {
        var userId: UUID?
        var authSubscribers: [UUID: AsyncStream<AuthState>.Continuation] = [:]
    }

    struct RealtimeSubscriber {
        /// Client whose session authorizes the channel (RLS of the session user, nothing when signed out).
        var clientId: UUID
        /// User of the filters (`user_id=eq.<userId>`, `id=eq.<userId>`).
        var userId: UUID
        var groupIds: Set<UUID>
        var continuation: AsyncStream<RealtimeEvent>.Continuation
    }

    public init(
        now: @escaping NowProvider = { Date() },
        calendar: Calendar = DemoData.calendar,
        latency: Duration = .zero
    ) {
        nowProvider = now
        self.calendar = calendar
        self.latency = latency
    }

    /// The backend's current date (its `now()`).
    public func now() -> Date {
        nowProvider()
    }

    // MARK: - Clients

    /// A new client ("device") with its own session, signed in as `userId` (or signed out when nil).
    public func services(for userId: UUID?) -> AppServices {
        let clientId = UUID()
        withLock { sessions[clientId] = SessionRecord(userId: userId) }
        let session = MockSession(backend: self, clientId: clientId)
        return AppServices(
            auth: MockAuthService(session: session),
            profiles: MockProfileService(session: session),
            groups: MockGroupService(session: session),
            tasks: MockTaskService(session: session),
            realtime: MockRealtimeService(session: session),
            push: MockPushService(session: session)
        )
    }

    // MARK: - Test & demo helpers

    /// Creates an account (and its profile) directly, without opening a session.
    @discardableResult
    public func createAccount(email: String, password: String, displayName: String, id: UUID = UUID()) throws -> AuthUser {
        let (email, name) = try InputValidation.signUp(email: email, password: password, displayName: displayName)
        return try withLock {
            guard data.account(email: email) == nil, data.accounts[id] == nil else { throw AppError.emailAlreadyUsed }
            insertAccountLocked(id: id, email: email, password: password, displayName: name, now: nowProvider())
            return AuthUser(id: id, email: email)
        }
    }

    public func userId(forEmail email: String) -> UUID? {
        withLock { data.account(email: InputRules.normalizedEmail(email))?.id }
    }

    /// The pending recovery code sent to `email` (what the user would read in the e-mail), if any.
    public func pendingRecoveryCode(email: String) -> String? {
        withLock {
            guard let account = data.account(email: InputRules.normalizedEmail(email)) else { return nil }
            return data.recoveries[account.id]?.code
        }
    }

    /// Number of live Realtime subscriptions (tests).
    public var realtimeSubscriberCount: Int {
        withLock { subscribers.count }
    }

    /// Seeds data directly (no signals). Used by `DemoData`.
    func seed(_ body: (inout BackendData) -> Void) {
        withLock { body(&data) }
    }

    // MARK: - Latency

    func simulateLatency() async throws {
        guard latency > .zero else { return }
        do {
            try await Task.sleep(for: latency)
        } catch {
            throw AppError.wrap(error)
        }
    }

    // MARK: - Locking primitives

    private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Must be called with the lock held.
    private func sessionUserLocked(_ clientId: UUID) throws -> UUID {
        guard let userId = sessions[clientId]?.userId, data.accounts[userId] != nil else {
            throw AppError.notAuthenticated
        }
        return userId
    }

    /// Reads as the session user of `clientId`.
    func read<Result>(as clientId: UUID, _ body: (BackendData, UUID) throws -> Result) throws -> Result {
        try withLock {
            let me = try sessionUserLocked(clientId)
            return try body(data, me)
        }
    }

    /// Runs a write transaction as the session user of `clientId`. Nothing is committed if `body` throws.
    ///
    /// A session whose account no longer exists (deleted on another device) is ended, like the Supabase adapter
    /// does when the server answers `not_authenticated` and the session cannot be refreshed: the client's
    /// `authStates()` emit `.signedOut`, then `.notAuthenticated` is thrown.
    func write<Result>(as clientId: UUID, _ body: (inout Transaction, UUID) throws -> Result) throws -> Result {
        try withLock {
            if endStaleSessionLocked(clientId) { throw AppError.notAuthenticated }
            let me = try sessionUserLocked(clientId)
            var transaction = Transaction(data: data, now: nowProvider())
            let result = try body(&transaction, me)
            commitLocked(&transaction)
            return result
        }
    }

    private func commitLocked(_ transaction: inout Transaction) {
        transaction.finish()
        data = transaction.data
        deliverLocked(transaction)
    }

    private func insertAccountLocked(id: UUID, email: String, password: String, displayName: String, now: Date) {
        data.accounts[id] = AccountRecord(id: id, email: email, password: password, createdAt: now)
        // The `handle_new_user` trigger creates the profile.
        data.profiles[id] = ProfileRecord(
            id: id, displayName: displayName, membershipsChangedAt: now, createdAt: now, updatedAt: now
        )
    }

    // MARK: - Realtime (docs/CONTRACTS.md §6)

    func subscribe(clientId: UUID, userId: UUID, groupIds: [UUID]) -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self, bufferingPolicy: .unbounded)
        let subscriptionId = UUID()
        withLock {
            subscribers[subscriptionId] = RealtimeSubscriber(
                clientId: clientId,
                userId: userId,
                groupIds: Set(groupIds.prefix(InMemoryBackend.maxRealtimeGroups)),
                continuation: continuation
            )
            continuation.yield(.connected)
        }
        continuation.onTermination = { [weak self] _ in
            self?.removeRealtimeSubscriber(subscriptionId)
        }
        return stream
    }

    private func removeRealtimeSubscriber(_ subscriptionId: UUID) {
        withLock { _ = subscribers.removeValue(forKey: subscriptionId) }
    }

    private func removeAuthSubscriber(clientId: UUID, subscriptionId: UUID) {
        withLock { _ = sessions[clientId]?.authSubscribers.removeValue(forKey: subscriptionId) }
    }

    /// Mirrors the three Realtime bindings: filters use the subscription's `userId`, visibility follows the RLS of
    /// the client's current session user (the channel's token), evaluated after the commit. Signed out (anon
    /// role, no policy), nothing is delivered.
    private func deliverLocked(_ transaction: Transaction) {
        guard !subscribers.isEmpty else { return }
        let activity = transaction.groupActivity
        let profileUpdates = transaction.profileUpdates
        for subscriber in subscribers.values {
            guard let viewer = sessions[subscriber.clientId]?.userId, data.accounts[viewer] != nil else { continue }
            // groups SELECT: member of the group.
            for groupId in activity
            where subscriber.groupIds.contains(groupId) && data.isMember(viewer, of: groupId) {
                subscriber.continuation.yield(.groupActivity(groupId: groupId))
            }
            // profiles SELECT: self or co-member.
            if profileUpdates.contains(subscriber.userId), data.canSeeProfile(of: subscriber.userId, as: viewer) {
                subscriber.continuation.yield(.membershipsChanged)
            }
            // task_assignees SELECT: member of the group.
            for row in transaction.insertedAssignments
            where row.userId == subscriber.userId && data.isMember(viewer, of: row.groupId) {
                subscriber.continuation.yield(.assigned(taskId: row.taskId, groupId: row.groupId, assignedBy: row.assignedBy))
            }
        }
    }

    // MARK: - Auth

    private func authStateLocked(_ clientId: UUID) -> AuthState {
        guard let userId = sessions[clientId]?.userId, let user = data.authUser(userId) else { return .signedOut }
        return .signedIn(user)
    }

    /// Ends the session of `clientId` if its account no longer exists (its subscribers last saw `.signedIn`).
    /// Returns whether it did.
    private func endStaleSessionLocked(_ clientId: UUID) -> Bool {
        guard let userId = sessions[clientId]?.userId, data.accounts[userId] == nil else { return false }
        sessions[clientId]?.userId = nil
        for continuation in (sessions[clientId]?.authSubscribers ?? [:]).values {
            continuation.yield(.signedOut)
        }
        return true
    }

    /// Changes the session of a client and notifies its `authStates()` subscribers if the state changed.
    private func setSessionLocked(_ clientId: UUID, userId: UUID?) {
        let before = authStateLocked(clientId)
        sessions[clientId, default: SessionRecord()].userId = userId
        let after = authStateLocked(clientId)
        guard after != before else { return }
        for continuation in (sessions[clientId]?.authSubscribers ?? [:]).values {
            continuation.yield(after)
        }
    }

    func authStates(clientId: UUID) -> AsyncStream<AuthState> {
        let (stream, continuation) = AsyncStream.makeStream(of: AuthState.self, bufferingPolicy: .unbounded)
        let subscriptionId = UUID()
        withLock {
            sessions[clientId, default: SessionRecord()].authSubscribers[subscriptionId] = continuation
            continuation.yield(authStateLocked(clientId))
        }
        continuation.onTermination = { [weak self] _ in
            self?.removeAuthSubscriber(clientId: clientId, subscriptionId: subscriptionId)
        }
        return stream
    }

    func currentUser(clientId: UUID) -> AuthUser? {
        withLock { authStateLocked(clientId).user }
    }

    /// Validates like the Supabase adapter does before calling Auth (`InputValidation.signUp`): Supabase Auth
    /// alone would accept a blank or too long display name.
    func signUp(clientId: UUID, email: String, password: String, displayName: String) throws -> SignUpOutcome {
        let (email, name) = try InputValidation.signUp(email: email, password: password, displayName: displayName)
        try withLock {
            guard data.account(email: email) == nil else { throw AppError.emailAlreadyUsed }
            let id = UUID()
            insertAccountLocked(id: id, email: email, password: password, displayName: name, now: nowProvider())
            setSessionLocked(clientId, userId: id)
        }
        return .signedIn
    }

    func signIn(clientId: UUID, email: String, password: String) throws {
        try withLock {
            guard let account = data.account(email: InputRules.normalizedEmail(email)), account.password == password else {
                throw AppError.invalidCredentials
            }
            setSessionLocked(clientId, userId: account.id)
        }
    }

    func signOut(clientId: UUID) {
        withLock { setSessionLocked(clientId, userId: nil) }
    }

    /// Stores the deterministic recovery code for an existing account. Unknown e-mails succeed silently
    /// (no account enumeration, like Supabase).
    func sendPasswordReset(email: String) throws {
        let email = try InputRules.email(email)
        withLock {
            guard let account = data.account(email: email) else { return }
            data.recoveries[account.id] = RecoveryRecord(
                userId: account.id, code: InMemoryBackend.recoveryCode, createdAt: nowProvider()
            )
        }
    }

    /// A valid, unexpired code signs the client in (recovery session) and is consumed.
    func verifyRecoveryCode(clientId: UUID, email: String, code: String) throws {
        try withLock {
            guard let account = data.account(email: InputRules.normalizedEmail(email)),
                  let recovery = data.recoveries[account.id],
                  recovery.code == InputRules.trimmed(code),
                  nowProvider().timeIntervalSince(recovery.createdAt) <= InMemoryBackend.recoveryCodeLifetime
            else { throw AppError.otpInvalid }
            data.recoveries[account.id] = nil
            setSessionLocked(clientId, userId: account.id)
        }
    }

    func updatePassword(clientId: UUID, newPassword: String) throws {
        try withLock {
            let me = try sessionUserLocked(clientId)
            try InputRules.password(newPassword)
            data.accounts[me]?.password = newPassword
        }
    }

    /// `delete_my_account()`, then local sign-out of this client.
    ///
    /// When the session's account no longer exists (deleted by an earlier attempt whose answer was lost, or on
    /// another device), the requested end state holds: the session is ended and the call succeeds, like the
    /// Supabase adapter.
    func deleteAccount(clientId: UUID) throws {
        try withLock {
            if endStaleSessionLocked(clientId) { return }
            let me = try sessionUserLocked(clientId)
            // Sign out first so that subscribers see `.signedOut` (afterwards the account no longer exists).
            setSessionLocked(clientId, userId: nil)
            var transaction = Transaction(data: data, now: nowProvider())
            transaction.deleteAccount(me)
            commitLocked(&transaction)
        }
    }
}

/// A client ("device") of the backend: the backend plus the id of its session.
struct MockSession: Sendable {
    let backend: InMemoryBackend
    let clientId: UUID
}
