import Foundation
import TeamTasksCore

// Rows of the in-memory "database". They mirror the tables of docs/CONTRACTS.md §3, docs/CONTRACTS-V2.md §2 and
// docs/CONTRACTS-V3.md.

struct AccountRecord: Sendable {
    var id: UUID
    /// Trimmed and lowercased (Supabase Auth stores e-mails lowercased).
    var email: String
    var password: String
    var createdAt: Date
}

struct ProfileRecord: Sendable {
    var id: UUID
    var displayName: String
    var membershipsChangedAt: Date
    var createdAt: Date
    var updatedAt: Date
    // v2
    var avatarColor: ColorKey? = nil
    /// Normalized (`InputValidation.emoji(_:)`).
    var avatarEmoji: String? = nil
    /// NULL for a new sign-up until `complete_onboarding()`.
    var onboardedAt: Date? = nil
    // v3: both NULL or both set (`set_away`, `clear_away`).
    var awayFrom: LocalDate? = nil
    var awayUntil: LocalDate? = nil

    /// v3: away on `day` (both days included).
    func isAway(on day: LocalDate) -> Bool {
        guard let awayFrom, let awayUntil else { return false }
        return awayFrom <= day && day <= awayUntil
    }
}

struct GroupRecord: Sendable {
    var id: UUID
    var name: String
    var createdBy: UUID?
    var createdAt: Date
    var lastActivityAt: Date
    // v2
    var color: ColorKey? = nil
    /// Normalized (`InputValidation.emoji(_:)`).
    var emoji: String? = nil
}

struct InviteRecord: Sendable {
    var groupId: UUID
    var code: String
    var createdBy: UUID?
    var createdAt: Date
}

struct MemberRecord: Sendable {
    var groupId: UUID
    var userId: UUID
    var role: MemberRole
    var joinedAt: Date

    /// Seniority order used to pick the member to promote: `joined_at`, then `user_id`.
    /// Uppercase `uuidString` order equals the byte order Postgres uses for `uuid`.
    static func joinedBefore(_ lhs: MemberRecord, _ rhs: MemberRecord) -> Bool {
        (lhs.joinedAt, lhs.userId.uuidString) < (rhs.joinedAt, rhs.userId.uuidString)
    }
}

struct TaskRecord: Sendable {
    var id: UUID
    var groupId: UUID
    var title: String
    var details: String?
    var status: TaskStatus
    var priority: TaskPriority
    var dueAt: Date?
    var createdBy: UUID?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    // v2
    /// `repeat_freq`, `repeat_interval`, `repeat_weekdays`, `repeat_tz` and `repeat_month_day` (`monthDay`, set for
    /// monthly rules only); nil = a plain task.
    var recurrence: RecurrenceRule? = nil
    var seriesId: UUID? = nil
    var nextOccurrenceId: UUID? = nil
    /// `rotation`; empty = NULL. It may still list people who left the group (the next spawn cleans it).
    var rotation: [UUID] = []
    var turnUserId: UUID? = nil
    var completedBy: UUID? = nil
}

extension TaskRecord {
    /// `tasks_before_update`: `updated_at` moves only when title, details, status, priority or due date changed
    /// (the v2 columns never move it).
    mutating func touch(from stored: TaskRecord, at now: Date) {
        let changed = title != stored.title || details != stored.details || status != stored.status
            || priority != stored.priority || dueAt != stored.dueAt
        updatedAt = changed ? now : stored.updatedAt
    }
}

struct AssigneeRecord: Sendable {
    var taskId: UUID
    var groupId: UUID
    var userId: UUID
    var assignedBy: UUID?
    var assignedAt: Date
}

/// `public.task_checklist_items` (docs/CONTRACTS-V2.md §2).
struct ChecklistItemRecord: Sendable {
    var id: UUID
    var taskId: UUID
    var groupId: UUID
    var title: String
    /// 1-based, unique per task; gaps are allowed.
    var position: Int
    var done: Bool = false
    var doneAt: Date? = nil
    var doneBy: UUID? = nil
    var createdAt: Date

    var item: ChecklistItem {
        ChecklistItem(id: id, title: title, position: position, isDone: done, doneAt: doneAt, doneBy: doneBy)
    }

    /// Display order: `position`, then `id.uuidString`.
    static func displayOrder(_ lhs: ChecklistItemRecord, _ rhs: ChecklistItemRecord) -> Bool {
        (lhs.position, lhs.id.uuidString) < (rhs.position, rhs.id.uuidString)
    }
}

/// `public.group_activity` (docs/CONTRACTS-V2.md §7). `id` is an identity: it increases with every event written.
struct ActivityRecord: Sendable {
    var id: Int64
    var groupId: UUID
    var kind: ActivityKind
    var actorId: UUID?
    var subjectId: UUID?
    var taskId: UUID?
    var taskTitle: String?
    var itemTitle: String?
    var createdAt: Date
    // v3: `member_away` only.
    var startsOn: LocalDate? = nil
    var endsOn: LocalDate? = nil

    /// The event with its reactions (`reactions:activity_reactions(user_id,emoji)`).
    func event(reactions: [ReactionRecord]) -> ActivityEvent {
        ActivityEvent(
            id: id, kind: kind, actorId: actorId, subjectId: subjectId, taskId: taskId,
            taskTitle: taskTitle, itemTitle: itemTitle, createdAt: createdAt,
            reactions: ActivityReaction.sorted(reactions.map { ActivityReaction(userId: $0.userId, emoji: $0.emoji) }),
            startsOn: startsOn, endsOn: endsOn
        )
    }
}

// MARK: - v3 (docs/CONTRACTS-V3.md)

/// `public.task_nudges` (§1).
struct NudgeRecord: Sendable {
    var id: UUID
    var taskId: UUID
    var groupId: UUID
    var fromUser: UUID
    var toUser: UUID
    var createdAt: Date

    var nudge: TaskNudge {
        TaskNudge(id: id, taskId: taskId, groupId: groupId, fromUserId: fromUser, toUserId: toUser, createdAt: createdAt)
    }
}

/// `public.turn_swaps` (§3).
struct SwapRecord: Sendable {
    var id: UUID
    var taskId: UUID
    var groupId: UUID
    var seriesId: UUID
    var fromUser: UUID
    var toUser: UUID
    var status: TurnSwap.Status
    var createdAt: Date
    var respondedAt: Date? = nil
    var repaidAt: Date? = nil

    var swap: TurnSwap {
        TurnSwap(
            id: id, taskId: taskId, groupId: groupId, seriesId: seriesId, fromUserId: fromUser, toUserId: toUser,
            status: status, createdAt: createdAt, respondedAt: respondedAt, repaidAt: repaidAt
        )
    }

    /// The order of the swap reads and of the repayment (« the oldest »): `created_at`, then `id`.
    static func olderFirst(_ lhs: SwapRecord, _ rhs: SwapRecord) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
    }
}

/// `public.activity_reactions` (§4); primary key `(activity_id, user_id, emoji)`.
struct ReactionRecord: Sendable {
    var activityId: Int64
    var groupId: UUID
    var userId: UUID
    /// The event's actor when the reaction was made (NULL for an event without actor, or once that account is gone).
    var targetUser: UUID?
    var emoji: ReactionEmoji
    var createdAt: Date
}

/// `public.task_comments` (§5).
struct CommentRecord: Sendable {
    var id: UUID
    var taskId: UUID
    var groupId: UUID
    var authorId: UUID?
    var body: String
    var mentions: [UUID]
    var createdAt: Date

    var comment: TaskComment {
        TaskComment(
            id: id, taskId: taskId, groupId: groupId, authorId: authorId, body: body, mentions: mentions,
            createdAt: createdAt
        )
    }
}

/// `public.task_photos` (§6).
struct PhotoRecord: Sendable {
    var id: UUID
    var taskId: UUID
    var groupId: UUID
    var path: String
    var uploadedBy: UUID?
    var createdAt: Date

    var photo: TaskPhoto {
        TaskPhoto(id: id, taskId: taskId, groupId: groupId, path: path, uploadedBy: uploadedBy, createdAt: createdAt)
    }
}

/// An object of the bucket `task-photos` (`storage.objects`), bytes included.
struct StoredObject: Sendable {
    var path: String
    var data: Data
    var contentType: String
    /// `storage.objects.owner`: the uploader.
    var owner: UUID?
    var createdAt: Date
}

struct PushRecord: Sendable {
    var userId: UUID
    var topic: String
    var createdAt: Date
}

struct JoinAttemptRecord: Sendable {
    var userId: UUID
    var attemptedAt: Date
    var succeeded: Bool
}

struct RecoveryRecord: Sendable {
    var userId: UUID
    var code: String
    var createdAt: Date
}

/// The whole persistent state. A value type, so a transaction works on a copy and commits atomically.
struct BackendData: Sendable {
    var accounts: [UUID: AccountRecord] = [:]
    var profiles: [UUID: ProfileRecord] = [:]
    var groups: [UUID: GroupRecord] = [:]
    /// Keyed by group id (one invite per group).
    var invites: [UUID: InviteRecord] = [:]
    /// group id → user id → membership.
    var members: [UUID: [UUID: MemberRecord]] = [:]
    var tasks: [UUID: TaskRecord] = [:]
    /// task id → user id → assignee row.
    var assignees: [UUID: [UUID: AssigneeRecord]] = [:]
    /// Keyed by user id.
    var pushTopics: [UUID: PushRecord] = [:]
    var joinAttempts: [JoinAttemptRecord] = []
    /// Pending password-recovery codes, keyed by user id.
    var recoveries: [UUID: RecoveryRecord] = [:]
    /// v2: checklist items, keyed by item id.
    var checklistItems: [UUID: ChecklistItemRecord] = [:]
    /// v2: the activity feed of every group, in id order.
    var activity: [ActivityRecord] = []
    /// v2: the last `group_activity.id` handed out (identities never go back, even when rows are deleted).
    var lastActivityId: Int64 = 0
    /// v3: nudges, oldest first.
    var nudges: [NudgeRecord] = []
    /// v3: turn swaps, keyed by id.
    var swaps: [UUID: SwapRecord] = [:]
    /// v3: reactions, in insertion order.
    var reactions: [ReactionRecord] = []
    /// v3: comments, keyed by id.
    var comments: [UUID: CommentRecord] = [:]
    /// v3: photo rows, keyed by id.
    var photos: [UUID: PhotoRecord] = [:]
    /// v3: the objects of the bucket `task-photos`, keyed by path.
    var photoObjects: [String: StoredObject] = [:]
}

// MARK: - Queries

extension BackendData {
    func account(email: String) -> AccountRecord? {
        accounts.values.first { $0.email == email }
    }

    func role(of userId: UUID, in groupId: UUID) -> MemberRole? {
        members[groupId]?[userId]?.role
    }

    func isMember(_ userId: UUID, of groupId: UUID) -> Bool {
        members[groupId]?[userId] != nil
    }

    func adminCount(in groupId: UUID) -> Int {
        members[groupId]?.values.filter { $0.role == .admin }.count ?? 0
    }

    /// Groups the user belongs to, in a stable order.
    func groupIds(of userId: UUID) -> [UUID] {
        members.compactMap { $0.value[userId] != nil ? $0.key : nil }.sortedByUUIDString()
    }

    func taskIds(in groupId: UUID) -> [UUID] {
        tasks.values.filter { $0.groupId == groupId }.map(\.id).sortedByUUIDString()
    }

    func assigneeIds(of taskId: UUID) -> [UUID] {
        Array((assignees[taskId] ?? [:]).keys).sortedByUUIDString()
    }

    /// The checklist of a task, in display order.
    func checklist(of taskId: UUID) -> [ChecklistItemRecord] {
        checklistItems.values.filter { $0.taskId == taskId }.sorted(by: ChecklistItemRecord.displayOrder)
    }

    /// `profiles` SELECT policy: self or co-member.
    func canSeeProfile(of userId: UUID, as viewer: UUID) -> Bool {
        viewer == userId || members.values.contains { $0[viewer] != nil && $0[userId] != nil }
    }

    /// Visibility rule of the `tasks` SELECT policy: members of the task's group.
    func visibleTask(_ taskId: UUID, to userId: UUID) -> TaskRecord? {
        guard let task = tasks[taskId], isMember(userId, of: task.groupId) else { return nil }
        return task
    }

    /// Visibility rule of the `task_checklist_items` SELECT policy: members of the item's group.
    func visibleChecklistItem(_ itemId: UUID, to userId: UUID) -> ChecklistItemRecord? {
        guard let item = checklistItems[itemId], isMember(userId, of: item.groupId) else { return nil }
        return item
    }

    /// Admin of the task's group, or creator who is still a member (docs/CONTRACTS.md §2).
    func canEdit(_ task: TaskRecord, userId: UUID) -> Bool {
        guard let role = role(of: userId, in: task.groupId) else { return false }
        return role == .admin || task.createdBy == userId
    }

    /// Editors, plus members assigned to the task. Also the checklist rights (docs/CONTRACTS-V2.md §4).
    func canChangeStatus(_ task: TaskRecord, userId: UUID) -> Bool {
        guard isMember(userId, of: task.groupId) else { return false }
        return canEdit(task, userId: userId) || assignees[task.id]?[userId] != nil
    }

    func teamGroup(_ record: GroupRecord) -> TeamGroup {
        TeamGroup(
            id: record.id,
            name: record.name,
            createdBy: record.createdBy,
            createdAt: record.createdAt,
            lastActivityAt: record.lastActivityAt,
            color: record.color,
            emoji: record.emoji
        )
    }

    func taskItem(_ record: TaskRecord) -> TaskItem {
        TaskItem(
            id: record.id,
            groupId: record.groupId,
            title: record.title,
            details: record.details,
            status: record.status,
            priority: record.priority,
            dueAt: record.dueAt,
            createdBy: record.createdBy,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            completedAt: record.completedAt,
            assigneeIds: assigneeIds(of: record.id),
            recurrence: record.recurrence,
            rotation: record.rotation,
            turnUserId: record.turnUserId,
            seriesId: record.seriesId,
            nextOccurrenceId: record.nextOccurrenceId,
            completedBy: record.completedBy,
            checklist: checklist(of: record.id).map(\.item),
            commentCount: comments.values.filter { $0.taskId == record.id }.count,
            photos: TaskPhoto.sorted(photos.values.filter { $0.taskId == record.id }.map(\.photo))
        )
    }

    /// v3: the event of an activity row, with its reactions.
    func activityEvent(_ record: ActivityRecord) -> ActivityEvent {
        record.event(reactions: reactions.filter { $0.activityId == record.id })
    }

    /// v3: the local date of a task's due date in its rule's time zone (`(due_at at time zone repeat_tz)::date`); nil
    /// without due date or rule.
    func localDueDate(of task: TaskRecord) -> LocalDate? {
        guard let dueAt = task.dueAt, let zone = task.recurrence?.timeZone else { return nil }
        return LocalDate(dueAt, timeZone: zone)
    }

    /// v3: `userId` is away on `day` (a nil day: never).
    func isAway(_ userId: UUID, on day: LocalDate?) -> Bool {
        guard let day else { return false }
        return profiles[userId]?.isAway(on: day) ?? false
    }

    /// The profile as a co-member reads it (`profile:profiles(id,display_name,avatar_color,avatar_emoji,away_from,
    /// away_until)`), and as the profile `PATCH`es return it.
    func publicProfile(_ record: ProfileRecord) -> UserProfile {
        UserProfile(
            id: record.id, displayName: record.displayName, avatarColor: record.avatarColor, avatarEmoji: record.avatarEmoji,
            awayFrom: record.awayFrom, awayUntil: record.awayUntil
        )
    }

    /// The profile as its owner reads it (docs/CONTRACTS-V2.md §9: with `onboarded_at` and `created_at`; v3: the away
    /// dates), and as `set_away` / `clear_away` return it.
    func ownProfile(_ record: ProfileRecord) -> UserProfile {
        UserProfile(
            id: record.id,
            displayName: record.displayName,
            avatarColor: record.avatarColor,
            avatarEmoji: record.avatarEmoji,
            onboardedAt: record.onboardedAt,
            createdAt: record.createdAt,
            awayFrom: record.awayFrom,
            awayUntil: record.awayUntil
        )
    }

    func membership(_ record: MemberRecord) -> Membership? {
        guard let profile = profiles[record.userId] else { return nil }
        return Membership(groupId: record.groupId, user: publicProfile(profile), role: record.role, joinedAt: record.joinedAt)
    }

    func authUser(_ userId: UUID) -> AuthUser? {
        guard let account = accounts[userId] else { return nil }
        return AuthUser(id: account.id, email: account.email)
    }
}

// MARK: - Generators

extension BackendData {
    static let inviteAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let topicAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// Random 8-character code from the invite alphabet, unique among existing invites
    /// (mirrors `private.generate_invite_code()`).
    func newInviteCode() -> String {
        let used = Set(invites.values.map(\.code))
        while true {
            let code = String((0..<InviteCode.length).map { _ in BackendData.inviteAlphabet.randomElement() ?? "A" })
            if !used.contains(code) { return code }
        }
    }

    /// `equipe-` + 24 random `[a-z0-9]` characters, unique among existing subscriptions.
    func newPushTopic() -> String {
        let used = Set(pushTopics.values.map(\.topic))
        while true {
            let suffix = String((0..<24).map { _ in BackendData.topicAlphabet.randomElement() ?? "a" })
            let topic = InMemoryBackend.pushTopicPrefix + suffix
            if !used.contains(topic) { return topic }
        }
    }
}

// MARK: - Helpers

extension Sequence where Element == UUID {
    /// Sorted by `uuidString` (the order used for `TaskItem.assigneeIds`).
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}
