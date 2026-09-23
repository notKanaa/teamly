import Foundation

// All service methods throw `AppError` (implementations must map backend errors with `BackendErrorMapper`).
// Semantics are specified in docs/CONTRACTS.md; the mocks (TeamTasksMocks) and the Supabase adapters
// (TeamTasksSupabase) must behave identically.

public protocol AuthService: Sendable {
    /// Emits the current state first (possibly `.unknown` until the stored session is restored), then every change.
    func authStates() -> AsyncStream<AuthState>
    func currentUser() async -> AuthUser?
    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome
    func signIn(email: String, password: String) async throws
    func signOut() async throws
    /// Sends a 6-digit recovery code by e-mail.
    func sendPasswordReset(email: String) async throws
    /// Verifies the recovery code. On success the user is signed in (recovery session).
    func verifyRecoveryCode(email: String, code: String) async throws
    /// Sets a new password for the signed-in user.
    func updatePassword(_ newPassword: String) async throws
    /// Deletes the account and all personal data (RPC `delete_my_account`), then signs out locally.
    func deleteAccount() async throws
}

public protocol ProfileService: Sendable {
    func myProfile() async throws -> UserProfile
    func updateDisplayName(_ name: String) async throws -> UserProfile
}

public protocol GroupService: Sendable {
    /// Groups the current user belongs to, most recently active first.
    func myGroups() async throws -> [GroupSummary]
    func createGroup(name: String) async throws -> GroupSummary
    /// Throws `.invalidCode` or `.rateLimited`.
    func join(code: InviteCode) async throws -> JoinResult
    func rename(groupId: UUID, name: String) async throws -> TeamGroup
    func deleteGroup(groupId: UUID) async throws
    /// Members sorted by role (admins first) then display name.
    func members(groupId: UUID) async throws -> [Membership]
    /// Admins only.
    func inviteCode(groupId: UUID) async throws -> InviteCode
    /// Admins only. The previous code stops working.
    func regenerateInviteCode(groupId: UUID) async throws -> InviteCode
    func setRole(groupId: UUID, userId: UUID, role: MemberRole) async throws
    func removeMember(groupId: UUID, userId: UUID) async throws
    func leave(groupId: UUID) async throws
}

public protocol TaskService: Sendable {
    /// Tasks of a group. Done tasks completed more than `Limits.oldDoneTaskDays` ago are omitted unless `includeOldDone`.
    func tasks(groupId: UUID, includeOldDone: Bool) async throws -> [TaskItem]
    /// Tasks assigned to the current user across all groups (with `myAssignedAt` and `groupName` filled).
    func myTasks(includeDone: Bool) async throws -> [TaskItem]
    func task(id: UUID) async throws -> TaskItem
    func create(groupId: UUID, draft: TaskDraft) async throws -> TaskItem
    /// Full edit (fields + assignees), atomic. Admin or creator only.
    func update(taskId: UUID, draft: TaskDraft) async throws -> TaskItem
    /// Admin, creator or assignee.
    func setStatus(taskId: UUID, status: TaskStatus) async throws -> TaskItem
    /// Admin or creator only.
    func delete(taskId: UUID) async throws
    /// Assignments to the current user made by someone else after `since`, oldest first.
    func assignments(since: Date) async throws -> [AssignmentEvent]
}

public protocol RealtimeService: Sendable {
    /// Live change signals for the current user. The stream ends when the consumer cancels.
    /// Emits `.connected` on every (re)subscription.
    func events(userId: UUID, groupIds: [UUID]) -> AsyncStream<RealtimeEvent>
}

/// Optional "real push" through the free ntfy app (docs/NOTIFICATIONS.md).
public protocol PushService: Sendable {
    /// The current user's private ntfy topic, if enabled.
    func currentTopic() async throws -> String?
    /// Enables push and returns the (new or existing) topic.
    func enable() async throws -> String
    func disable() async throws
}

/// All backend services, injected into view models.
public struct AppServices: Sendable {
    public var auth: any AuthService
    public var profiles: any ProfileService
    public var groups: any GroupService
    public var tasks: any TaskService
    public var realtime: any RealtimeService
    public var push: any PushService

    public init(
        auth: any AuthService,
        profiles: any ProfileService,
        groups: any GroupService,
        tasks: any TaskService,
        realtime: any RealtimeService,
        push: any PushService
    ) {
        self.auth = auth
        self.profiles = profiles
        self.groups = groups
        self.tasks = tasks
        self.realtime = realtime
        self.push = push
    }
}
