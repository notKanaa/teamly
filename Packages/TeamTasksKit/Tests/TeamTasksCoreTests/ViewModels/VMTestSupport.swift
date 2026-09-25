import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

// Test doubles for the view model suites. Names are prefixed with `VM` so they never clash with helpers of
// other suites of this test target.

// MARK: - Fixtures

enum VMFixtures {
    static let paris = TimeZone(identifier: "Europe/Paris")!
    static let calendar = Calendar.frenchGregorian(timeZone: paris)

    /// Thursday 24 September 2026, 10:00 in Paris.
    static let now: Date = date(2026, 9, 24, 10)

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    static let camille = DemoData.camille
    static let lucas = DemoData.lucas
    static let ines = DemoData.ines
    static let lilas = DemoData.lilasGroupId
    static let sport = DemoData.sportGroupId
    typealias Tasks = DemoData.TaskIDs
}

// MARK: - Waiting

enum VMWait {
    /// Polls `condition` until it holds; records an issue after `timeout`.
    @MainActor
    static func until(
        _ description: String = "condition",
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var attempts = 0
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
                return
            }
            attempts += 1
            if attempts % 20 == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000)
            } else {
                await Task.yield()
            }
        }
    }

    /// Lets already-enqueued jobs run.
    @MainActor
    static func settle() async {
        for _ in 0..<50 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
        for _ in 0..<50 {
            await Task.yield()
        }
    }
}

// MARK: - Notification scheduler

final class VMScheduler: NotificationScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var _authorization: NotificationAuthorization
    private var _grantOnRequest: Bool
    private var _pending: [String: LocalNotification] = [:]
    private var _delivered: [LocalNotification] = []
    private var _requestCount = 0

    init(authorization: NotificationAuthorization = .authorized, grantOnRequest: Bool = true) {
        _authorization = authorization
        _grantOnRequest = grantOnRequest
    }

    var authorization: NotificationAuthorization {
        get { lock.withLock { _authorization } }
        set { lock.withLock { _authorization = newValue } }
    }

    var grantOnRequest: Bool {
        get { lock.withLock { _grantOnRequest } }
        set { lock.withLock { _grantOnRequest = newValue } }
    }

    var pending: [String: LocalNotification] { lock.withLock { _pending } }
    /// Pending due-date reminders, sorted.
    var dueIds: [String] { lock.withLock { _pending.keys.filter { $0.hasPrefix("due-") }.sorted() } }
    /// "Deliver now" notifications (assignments, summaries), in order.
    var delivered: [LocalNotification] { lock.withLock { _delivered } }
    var requestCount: Int { lock.withLock { _requestCount } }

    func clearPending() {
        lock.withLock { _pending.removeAll() }
    }

    func authorizationStatus() async -> NotificationAuthorization {
        lock.withLock { _authorization }
    }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            _requestCount += 1
            if _authorization == .notDetermined {
                _authorization = _grantOnRequest ? .authorized : .denied
            }
            return _authorization == .authorized
        }
    }

    func pendingIdentifiers(prefix: String) async -> [String] {
        lock.withLock { _pending.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    }

    func add(_ notification: LocalNotification) async throws {
        lock.withLock {
            if notification.fireDate == nil {
                _delivered.append(notification)
            } else {
                _pending[notification.id] = notification
            }
        }
    }

    func removePending(ids: [String]) async {
        lock.withLock {
            for id in ids {
                _pending.removeValue(forKey: id)
            }
        }
    }

    func setBadge(_ count: Int) async {}
}

// MARK: - Fault injection

/// Counts service calls, makes chosen calls fail, and holds chosen calls until released.
final class VMFaults: @unchecked Sendable {
    enum Op: String, Sendable, Hashable {
        case signUp, signIn, signOut, sendPasswordReset, verifyRecoveryCode, updatePassword, deleteAccount
        case myProfile, updateDisplayName
        case myGroups, createGroup, join, rename, deleteGroup, members, inviteCode, regenerateInviteCode
        case setRole, removeMember, leave
        case tasks, myTasks, task, createTask, updateTask, setStatus, deleteTask, assignments
        case currentTopic, enablePush, disablePush
        // v2 (`createGroup` also counts `createGroup(name:color:emoji:)`).
        case updateAvatar, completeOnboarding
        case setAppearance, activity
        case addChecklistItem, renameChecklistItem, setChecklistItemDone, deleteChecklistItem, completions
    }

    private let lock = NSLock()
    private var queued: [Op: [any Error]] = [:]
    private var callCounts: [Op: Int] = [:]
    private var held: Set<Op> = []
    private var waiters: [Op: [CheckedContinuation<Void, Never>]] = [:]

    /// The next `times` calls of `op` throw `error` (after being counted).
    func fail(_ op: Op, with error: any Error, times: Int = 1) {
        lock.withLock { queued[op, default: []].append(contentsOf: Array(repeating: error, count: times)) }
    }

    func calls(_ op: Op) -> Int {
        lock.withLock { callCounts[op, default: 0] }
    }

    /// Calls of `op` wait until `release(op)`.
    func hold(_ op: Op) {
        lock.withLock { _ = held.insert(op) }
    }

    func release(_ op: Op) {
        let continuations = lock.withLock {
            held.remove(op)
            return waiters.removeValue(forKey: op) ?? []
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    /// Number of calls of `op` currently held.
    func waiting(_ op: Op) -> Int {
        lock.withLock { waiters[op]?.count ?? 0 }
    }

    func check(_ op: Op) async throws {
        let (error, mustWait) = lock.withLock { () -> ((any Error)?, Bool) in
            callCounts[op, default: 0] += 1
            var error: (any Error)?
            if var list = queued[op], !list.isEmpty {
                error = list.removeFirst()
                queued[op] = list
            }
            return (error, held.contains(op))
        }
        if mustWait {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    guard held.contains(op) else { return true }
                    waiters[op, default: []].append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if let error { throw error }
    }
}

struct VMAuthService: AuthService {
    let base: any AuthService
    let faults: VMFaults
    var signUpOutcome: SignUpOutcome?

    func authStates() -> AsyncStream<AuthState> { base.authStates() }
    func currentUser() async -> AuthUser? { await base.currentUser() }

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        try await faults.check(.signUp)
        let outcome = try await base.signUp(email: email, password: password, displayName: displayName)
        return signUpOutcome ?? outcome
    }

    func signIn(email: String, password: String) async throws {
        try await faults.check(.signIn)
        try await base.signIn(email: email, password: password)
    }

    func signOut() async throws {
        try await faults.check(.signOut)
        try await base.signOut()
    }

    func sendPasswordReset(email: String) async throws {
        try await faults.check(.sendPasswordReset)
        try await base.sendPasswordReset(email: email)
    }

    func verifyRecoveryCode(email: String, code: String) async throws {
        try await faults.check(.verifyRecoveryCode)
        try await base.verifyRecoveryCode(email: email, code: code)
    }

    func updatePassword(_ newPassword: String) async throws {
        try await faults.check(.updatePassword)
        try await base.updatePassword(newPassword)
    }

    func deleteAccount() async throws {
        try await faults.check(.deleteAccount)
        try await base.deleteAccount()
    }
}

struct VMProfileService: ProfileService {
    let base: any ProfileService
    let faults: VMFaults

    func myProfile() async throws -> UserProfile {
        try await faults.check(.myProfile)
        return try await base.myProfile()
    }

    func updateDisplayName(_ name: String) async throws -> UserProfile {
        try await faults.check(.updateDisplayName)
        return try await base.updateDisplayName(name)
    }

    func updateAvatar(color: ColorKey?, emoji: String?) async throws -> UserProfile {
        try await faults.check(.updateAvatar)
        return try await base.updateAvatar(color: color, emoji: emoji)
    }

    func completeOnboarding() async throws {
        try await faults.check(.completeOnboarding)
        try await base.completeOnboarding()
    }
}

struct VMGroupService: GroupService {
    let base: any GroupService
    let faults: VMFaults

    func myGroups() async throws -> [GroupSummary] {
        try await faults.check(.myGroups)
        return try await base.myGroups()
    }

    func createGroup(name: String) async throws -> GroupSummary {
        try await faults.check(.createGroup)
        return try await base.createGroup(name: name)
    }

    func join(code: InviteCode) async throws -> JoinResult {
        try await faults.check(.join)
        return try await base.join(code: code)
    }

    func rename(groupId: UUID, name: String) async throws -> TeamGroup {
        try await faults.check(.rename)
        return try await base.rename(groupId: groupId, name: name)
    }

    func deleteGroup(groupId: UUID) async throws {
        try await faults.check(.deleteGroup)
        try await base.deleteGroup(groupId: groupId)
    }

    func members(groupId: UUID) async throws -> [Membership] {
        try await faults.check(.members)
        return try await base.members(groupId: groupId)
    }

    func inviteCode(groupId: UUID) async throws -> InviteCode {
        try await faults.check(.inviteCode)
        return try await base.inviteCode(groupId: groupId)
    }

    func regenerateInviteCode(groupId: UUID) async throws -> InviteCode {
        try await faults.check(.regenerateInviteCode)
        return try await base.regenerateInviteCode(groupId: groupId)
    }

    func setRole(groupId: UUID, userId: UUID, role: MemberRole) async throws {
        try await faults.check(.setRole)
        try await base.setRole(groupId: groupId, userId: userId, role: role)
    }

    func removeMember(groupId: UUID, userId: UUID) async throws {
        try await faults.check(.removeMember)
        try await base.removeMember(groupId: groupId, userId: userId)
    }

    func leave(groupId: UUID) async throws {
        try await faults.check(.leave)
        try await base.leave(groupId: groupId)
    }

    func createGroup(name: String, color: ColorKey?, emoji: String?) async throws -> GroupSummary {
        try await faults.check(.createGroup)
        return try await base.createGroup(name: name, color: color, emoji: emoji)
    }

    func setAppearance(groupId: UUID, color: ColorKey?, emoji: String?) async throws -> TeamGroup {
        try await faults.check(.setAppearance)
        return try await base.setAppearance(groupId: groupId, color: color, emoji: emoji)
    }

    func activity(groupId: UUID) async throws -> [ActivityEvent] {
        try await faults.check(.activity)
        return try await base.activity(groupId: groupId)
    }
}

struct VMTaskService: TaskService {
    let base: any TaskService
    let faults: VMFaults

    func tasks(groupId: UUID, includeOldDone: Bool) async throws -> [TaskItem] {
        try await faults.check(.tasks)
        return try await base.tasks(groupId: groupId, includeOldDone: includeOldDone)
    }

    func myTasks(includeDone: Bool) async throws -> [TaskItem] {
        try await faults.check(.myTasks)
        return try await base.myTasks(includeDone: includeDone)
    }

    func task(id: UUID) async throws -> TaskItem {
        try await faults.check(.task)
        return try await base.task(id: id)
    }

    func create(groupId: UUID, draft: TaskDraft) async throws -> TaskItem {
        try await faults.check(.createTask)
        return try await base.create(groupId: groupId, draft: draft)
    }

    func update(taskId: UUID, draft: TaskDraft) async throws -> TaskItem {
        try await faults.check(.updateTask)
        return try await base.update(taskId: taskId, draft: draft)
    }

    func setStatus(taskId: UUID, status: TaskStatus) async throws -> TaskItem {
        try await faults.check(.setStatus)
        return try await base.setStatus(taskId: taskId, status: status)
    }

    func delete(taskId: UUID) async throws {
        try await faults.check(.deleteTask)
        try await base.delete(taskId: taskId)
    }

    func assignments(since: Date) async throws -> [AssignmentEvent] {
        try await faults.check(.assignments)
        return try await base.assignments(since: since)
    }

    func addChecklistItem(taskId: UUID, title: String) async throws -> ChecklistItem {
        try await faults.check(.addChecklistItem)
        return try await base.addChecklistItem(taskId: taskId, title: title)
    }

    func renameChecklistItem(itemId: UUID, title: String) async throws -> ChecklistItem {
        try await faults.check(.renameChecklistItem)
        return try await base.renameChecklistItem(itemId: itemId, title: title)
    }

    func setChecklistItemDone(itemId: UUID, done: Bool) async throws -> ChecklistItem {
        try await faults.check(.setChecklistItemDone)
        return try await base.setChecklistItemDone(itemId: itemId, done: done)
    }

    func deleteChecklistItem(itemId: UUID) async throws {
        try await faults.check(.deleteChecklistItem)
        try await base.deleteChecklistItem(itemId: itemId)
    }

    func completions(groupId: UUID, since: Date) async throws -> [TaskCompletion] {
        try await faults.check(.completions)
        return try await base.completions(groupId: groupId, since: since)
    }
}

struct VMPushService: PushService {
    let base: any PushService
    let faults: VMFaults

    func currentTopic() async throws -> String? {
        try await faults.check(.currentTopic)
        return try await base.currentTopic()
    }

    func enable() async throws -> String {
        try await faults.check(.enablePush)
        return try await base.enable()
    }

    func disable() async throws {
        try await faults.check(.disablePush)
        try await base.disable()
    }
}

extension AppServices {
    /// The same services, counted and failing on demand through `faults`.
    func instrumented(with faults: VMFaults, signUpOutcome: SignUpOutcome? = nil) -> AppServices {
        AppServices(
            auth: VMAuthService(base: auth, faults: faults, signUpOutcome: signUpOutcome),
            profiles: VMProfileService(base: profiles, faults: faults),
            groups: VMGroupService(base: groups, faults: faults),
            tasks: VMTaskService(base: tasks, faults: faults),
            realtime: realtime,
            push: VMPushService(base: push, faults: faults)
        )
    }
}

// MARK: - Harness

/// A mock backend with demo data (docs/CONTRACTS.md §8) seen from one device, with instrumented services and fake
/// platform services. The backend clock advances by 1 s at every read (strictly increasing server timestamps);
/// the device clock reads it without advancing it.
@MainActor
struct VMHarness {
    let environment: MockEnvironment
    let clock: MockClock
    let faults: VMFaults
    let services: AppServices
    let scheduler: VMScheduler
    let store: InMemoryKeyValueStore
    let platform: PlatformServices

    var backend: InMemoryBackend { environment.backend }

    init(
        _ scenario: MockScenario = .populated,
        authorization: NotificationAuthorization = .authorized,
        signUpOutcome: SignUpOutcome? = nil
    ) {
        let clock = MockClock(VMFixtures.now, autoAdvance: 1)
        self.clock = clock
        environment = MockEnvironment.make(scenario: scenario, now: clock.provider)
        faults = VMFaults()
        services = environment.services.instrumented(with: faults, signUpOutcome: signUpOutcome)
        scheduler = VMScheduler(authorization: authorization)
        store = InMemoryKeyValueStore()
        platform = PlatformServices(
            notifications: scheduler,
            store: store,
            now: { clock.peek() },
            calendar: VMFixtures.calendar
        )
    }

    static let testConfiguration = SessionModel.Configuration(
        realtimeDebounce: .zero,
        realtimeRetryDelay: .milliseconds(20)
    )

    /// A session of the scenario's signed-in user (not started).
    func makeSession(user: DemoUser? = nil) -> SessionModel {
        let demoUser = user ?? environment.signedInUser ?? VMFixtures.camille
        return SessionModel(
            user: AuthUser(id: demoUser.id, email: demoUser.email),
            services: services,
            platform: platform,
            configuration: Self.testConfiguration
        )
    }

    func makeApp() -> AppModel {
        AppModel(services: services, platform: platform, sessionConfiguration: Self.testConfiguration)
    }

    /// Services of another device signed in as `user` (not instrumented).
    func device(_ user: DemoUser) -> AppServices {
        backend.services(for: user.id)
    }

    /// Reminder ids expected for these tasks (lead time 1 h).
    func reminderIds(_ taskIds: [UUID]) async throws -> [String] {
        var ids: [String] = []
        let lucas = device(VMFixtures.lucas)
        for taskId in taskIds {
            let task = try await lucas.tasks.task(id: taskId)
            ids.append(ReminderPlanner.identifier(taskId: taskId, dueAt: try #require(task.dueAt)))
        }
        return ids.sorted()
    }
}
