import Foundation

// All service methods throw `AppError` (implementations must map backend errors with `BackendErrorMapper`).
// Semantics are specified in docs/CONTRACTS.md and docs/CONTRACTS-V2.md; the mocks (TeamTasksMocks) and the
// Supabase adapters (TeamTasksSupabase) must behave identically.

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
    /// The current user's profile. v2: with `avatarColor`, `avatarEmoji`, `onboardedAt` and `createdAt`.
    func myProfile() async throws -> UserProfile
    /// v2: an actual change also bumps every group of the user (co-members get `.groupActivity`).
    func updateDisplayName(_ name: String) async throws -> UserProfile
    /// v2: sets the current user's avatar (`PATCH profiles`): nil color = automatic; nil or blank emoji = the
    /// initials. The emoji is checked with `InputValidation.emoji(_:)` (`.invalidAppearance`) and stored normalized.
    /// Returns the updated profile. The user's own devices get `.membershipsChanged`; an actual change also bumps
    /// every group of the user (co-members get `.groupActivity`).
    func updateAvatar(color: ColorKey?, emoji: String?) async throws -> UserProfile
    /// v2: marks the onboarding as done (`complete_onboarding()`): sets `onboardedAt` once; later calls change
    /// nothing.
    func completeOnboarding() async throws
}

public protocol GroupService: Sendable {
    /// Groups the current user belongs to, most recently active first.
    func myGroups() async throws -> [GroupSummary]
    /// Same as `createGroup(name:color:emoji:)` with an automatic color and no emoji.
    func createGroup(name: String) async throws -> GroupSummary
    /// v2: creates a group with its appearance, the caller being its admin (`create_group`). nil color = automatic;
    /// nil or blank emoji = none. Checks the name (`.invalidName`), then the emoji (`.invalidAppearance`), then the
    /// server's write quota (`.rateLimited`).
    func createGroup(name: String, color: ColorKey?, emoji: String?) async throws -> GroupSummary
    /// Throws `.invalidCode` or `.rateLimited`.
    func join(code: InviteCode) async throws -> JoinResult
    func rename(groupId: UUID, name: String) async throws -> TeamGroup
    /// v2: admins only (`set_group_appearance`): sets both the color and the emoji (nil = automatic color / no
    /// emoji). Unknown group → `.notFound`; not an admin → `.forbidden`; then `.invalidAppearance`. Bumps the
    /// group.
    func setAppearance(groupId: UUID, color: ColorKey?, emoji: String?) async throws -> TeamGroup
    func deleteGroup(groupId: UUID) async throws
    /// Members sorted by role (admins first) then display name.
    func members(groupId: UUID) async throws -> [Membership]
    /// v2: the figures of the groups list for all of `groupIds` at once (docs/CONTRACTS-V2.md §10 « Groups overview »):
    /// each group's members (with their avatar, in the order of `members(groupId:)`), its tasks not done, and its tasks
    /// done at or after `doneSince` (inclusive; the groups list passes the start of the week,
    /// `WeeklyRecap.weekStart(of:calendar:)`). Tasks with a status unknown to this client are not counted.
    ///
    /// One overview per distinct group of `groupIds`, in that order. A group is left out when the caller is not a
    /// member of it (or it does not exist), and when its rows exceed what the server returns in one page (the
    /// Supabase adapter reads at most `Limits.readRowsMax` rows per request, §10): the caller then shows that group
    /// without figures. An empty `groupIds` reads nothing.
    func overviews(groupIds: [UUID], doneSince: Date) async throws -> [GroupOverview]
    /// v2: the group's activity feed, newest first, at most `Limits.activityFeedMax` events (older events are not
    /// read); events of an unknown kind are left out. Non-members read an empty list.
    func activity(groupId: UUID) async throws -> [ActivityEvent]
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
    /// v2: with their recurrence, rotation, turn, series, `completedBy` and checklist.
    func tasks(groupId: UUID, includeOldDone: Bool) async throws -> [TaskItem]
    /// Tasks assigned to the current user across all groups (with `myAssignedAt` and `groupName` filled; v2: also
    /// `groupColor` and `groupEmoji`).
    func myTasks(includeDone: Bool) async throws -> [TaskItem]
    /// v2: the same tasks without the pile of old done ones (docs/CONTRACTS-V2.md §10 « My tasks, bounded »): every task
    /// assigned to the current user that is not done, plus the done ones completed at or after `doneSince`
    /// (inclusive), with the fields of `myTasks(includeDone:)`. « Mes tâches » passes the start of today, so the read
    /// no longer grows with the done occurrences of recurring tasks.
    func myTasks(doneSince: Date) async throws -> [TaskItem]
    func task(id: UUID) async throws -> TaskItem
    /// Creates a task. v2: with the draft's recurrence, rotation and initial checklist. Checks, in this order:
    /// membership (`.forbidden`), title, details, due date, recurrence (`InputValidation.recurrence(_:dueAt:)`),
    /// rotation (`InputValidation.rotation(_:recurrence:)`, then its members: `.invalidRotation`), assignees when
    /// there is no rotation (count, then membership), checklist (`InputValidation.checklist(_:)`), then the server's
    /// write quota. With a rotation, `draft.assigneeIds` is ignored: `rotation[0]` is the turn holder and the only
    /// assignee. The checklist items get the positions 1…n.
    func create(groupId: UUID, draft: TaskDraft) async throws -> TaskItem
    /// Full edit (fields + assignees), atomic. Admin or creator only.
    /// v2: also a full edit of the recurrence and the rotation (build the draft with `TaskDraft(task:)`): nil
    /// recurrence removes the rule and the rotation; a rule needs `dueAt` (`.recurrenceNeedsDueDate`); an empty
    /// rotation removes it; the task's own rotation sent back is kept without checks. Checks, in this order: task
    /// (`.notFound`), rights (`.forbidden`), title, details, due date, recurrence, rotation, then the assignees.
    /// While the edited task has a rotation, `draft.assigneeIds` is ignored and the turn holder stays the only
    /// assignee. `draft.checklist` is ignored. Editing the rule never creates an occurrence.
    func update(taskId: UUID, draft: TaskDraft) async throws -> TaskItem
    /// Admin, creator or assignee. v2: when a recurring task becomes done, the server creates its next occurrence
    /// (`NextDueCalculator`, `RotationHandover`); the returned task has `nextOccurrenceId` and `completedBy`.
    func setStatus(taskId: UUID, status: TaskStatus) async throws -> TaskItem
    /// Admin or creator only.
    func delete(taskId: UUID) async throws
    /// Assignments to the current user made by someone else after `since`, oldest first.
    /// v2: with `taskHasRotation` (rotation turns are worded « C’est ton tour »).
    func assignments(since: Date) async throws -> [AssignmentEvent]

    // MARK: v2 checklist (docs/CONTRACTS-V2.md §5): the rights of `setStatus` (`TaskPermissions.canManageChecklist`).
    // Unknown or invisible task / item → `.notFound`; no right → `.forbidden`. Every write bumps the task's group.

    /// Adds an item at the end of the task's checklist (position = the largest one + 1). Checks the title
    /// (`InputValidation.checklistItemTitle(_:)`), then the count (`.tooManyChecklistItems`).
    func addChecklistItem(taskId: UUID, title: String) async throws -> ChecklistItem
    /// Renames an item (`InputValidation.checklistItemTitle(_:)`).
    func renameChecklistItem(itemId: UUID, title: String) async throws -> ChecklistItem
    /// Checks or unchecks an item (`doneAt` and `doneBy` follow); the same value changes nothing.
    func setChecklistItemDone(itemId: UUID, done: Bool) async throws -> ChecklistItem
    /// Deletes an item; the other items keep their positions.
    func deleteChecklistItem(itemId: UUID) async throws

    /// v2: the group's done tasks completed at or after `since`, for the weekly recap (read them from
    /// `WeeklyRecap.readStart(now:calendar:)`), in no particular order. Non-members read an empty list.
    func completions(groupId: UUID, since: Date) async throws -> [TaskCompletion]
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
