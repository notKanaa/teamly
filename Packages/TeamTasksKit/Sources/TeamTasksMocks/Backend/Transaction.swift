import Foundation
import TeamTasksCore

/// One write "transaction" on a copy of the data. It also records the change signals of
/// docs/CONTRACTS.md §6 (at most one bump per group per transaction), applied by `finish()`, and mirrors the server
/// triggers of docs/CONTRACTS-V2.md (activity feed, spawn of the next occurrence, turn handover).
struct Transaction {
    var data: BackendData
    /// Like Postgres `now()`: one timestamp for the whole transaction.
    let now: Date
    /// `auth.uid()`: the session user of the call (nil in trusted contexts).
    let actor: UUID?

    /// Groups whose `last_activity_at` is bumped (tasks, assignees, members, checklist items, rename, profiles).
    private(set) var bumpedGroups: Set<UUID> = []
    /// Groups whose row is updated without a bump (e.g. `created_by` set to NULL): Realtime UPDATE only.
    private(set) var touchedGroups: Set<UUID> = []
    /// Users whose `memberships_changed_at` is bumped.
    private(set) var membershipChangedUsers: Set<UUID> = []
    /// Users whose profile row is updated for another reason (display name, avatar, onboarding).
    private(set) var updatedProfiles: Set<UUID> = []
    /// New `task_assignees` rows (Realtime INSERT).
    private(set) var insertedAssignments: [AssigneeRecord] = []
    /// Groups that lost a member (safety-net heal trigger).
    private var groupsThatLostMembers: Set<UUID> = []

    init(data: BackendData, now: Date, actor: UUID?) {
        self.data = data
        self.now = now
        self.actor = actor
    }

    // MARK: Signals

    mutating func bump(_ groupId: UUID) {
        bumpedGroups.insert(groupId)
    }

    mutating func touch(_ groupId: UUID) {
        touchedGroups.insert(groupId)
    }

    mutating func membershipsChanged(_ userId: UUID) {
        membershipChangedUsers.insert(userId)
    }

    mutating func profileUpdated(_ userId: UUID) {
        updatedProfiles.insert(userId)
    }

    /// Users whose profile row was updated (→ Realtime `.membershipsChanged`).
    var profileUpdates: Set<UUID> {
        membershipChangedUsers.union(updatedProfiles).filter { data.profiles[$0] != nil }
    }

    /// Groups that emit a Realtime UPDATE (→ `.groupActivity`).
    var groupActivity: [UUID] {
        bumpedGroups.union(touchedGroups).filter { data.groups[$0] != nil }.sortedByUUIDString()
    }

    /// Runs the safety-net heal and applies the signal bumps. Called once, before commit.
    mutating func finish() {
        healGroupsWithoutAdmin()
        // Local copy: reading `self.now` inside `data[…]?.x = …` overlaps the modify access to `self`
        // (rejected by the Darwin compiler's static exclusivity check).
        let now = now
        for groupId in bumpedGroups {
            data.groups[groupId]?.lastActivityAt = now
        }
        for userId in membershipChangedUsers {
            data.profiles[userId]?.membershipsChangedAt = now
        }
    }

    // MARK: Profiles (v2)

    /// An UPDATE of a profile row (`profiles_before_write` + `profiles_after_update_signal`): `updated_at` and the
    /// groups of the user only move when the display name, the avatar color or the avatar emoji actually changes.
    /// The row is written anyway: the user's own devices get `.membershipsChanged`.
    mutating func updateProfile(_ userId: UUID, _ change: (inout ProfileRecord) -> Void) {
        guard let stored = data.profiles[userId] else { return }
        var profile = stored
        change(&profile)
        let changed = profile.displayName != stored.displayName || profile.avatarColor != stored.avatarColor
            || profile.avatarEmoji != stored.avatarEmoji
        profile.updatedAt = changed ? now : stored.updatedAt
        data.profiles[userId] = profile
        profileUpdated(userId)
        guard changed else { return }
        for groupId in data.groupIds(of: userId) {
            bump(groupId)
        }
    }

    // MARK: Activity feed (v2)

    /// `private.log_activity`: skipped for a group that no longer exists (being deleted); first deletes the group's
    /// events older than `Limits.activityRetentionDays` days (one exactly that old is kept); an actor or subject
    /// whose profile no longer exists is stored as NULL. Writing an event does not bump the group.
    mutating func logActivity(
        groupId: UUID,
        kind: ActivityEvent.Kind,
        actorId: UUID? = nil,
        subjectId: UUID? = nil,
        taskId: UUID? = nil,
        taskTitle: String? = nil,
        itemTitle: String? = nil
    ) {
        guard data.groups[groupId] != nil else { return }
        let cutoff = now.addingTimeInterval(-TimeInterval(Limits.activityRetentionDays) * 86_400)
        data.activity.removeAll { $0.groupId == groupId && $0.createdAt < cutoff }
        data.lastActivityId += 1
        let profiles = data.profiles
        data.activity.append(ActivityRecord(
            id: data.lastActivityId,
            groupId: groupId,
            kind: kind,
            actorId: actorId.flatMap { profiles[$0] == nil ? nil : $0 },
            subjectId: subjectId.flatMap { profiles[$0] == nil ? nil : $0 },
            taskId: taskId,
            taskTitle: taskTitle,
            itemTitle: itemTitle,
            createdAt: now
        ))
    }

    // MARK: Memberships

    /// A `group_members` insert: bumps, and `member_joined` unless it is the first member of the group (its creator,
    /// whose membership `create_group` inserts alone).
    mutating func insertMembership(groupId: UUID, userId: UUID, role: MemberRole) {
        let hasOtherMembers = (data.members[groupId] ?? [:]).keys.contains { $0 != userId }
        data.members[groupId, default: [:]][userId] = MemberRecord(
            groupId: groupId, userId: userId, role: role, joinedAt: now
        )
        bump(groupId)
        membershipsChanged(userId)
        if hasOtherMembers {
            logActivity(groupId: groupId, kind: .memberJoined, actorId: userId, subjectId: userId)
        }
    }

    /// Changes a role; an unchanged role writes nothing (no bump).
    mutating func updateRole(groupId: UUID, userId: UUID, role: MemberRole) {
        guard let current = data.members[groupId]?[userId]?.role, current != role else { return }
        data.members[groupId]?[userId]?.role = role
        bump(groupId)
        membershipsChanged(userId)
    }

    /// Deletes a membership; the FK cascade deletes the user's assignments in that group. v2: `member_left` (actor =
    /// the caller), then the turn handover of the pending rotating occurrences whose turn holder this user was.
    mutating func deleteMembership(groupId: UUID, userId: UUID) {
        guard data.members[groupId]?[userId] != nil else { return }
        data.members[groupId]?[userId] = nil
        if data.members[groupId]?.isEmpty == true {
            data.members[groupId] = nil
        }
        for taskId in data.taskIds(in: groupId) where data.assignees[taskId]?[userId] != nil {
            data.assignees[taskId]?[userId] = nil
        }
        bump(groupId)
        membershipsChanged(userId)
        groupsThatLostMembers.insert(groupId)
        logActivity(groupId: groupId, kind: .memberLeft, actorId: actor, subjectId: userId)
        handOverTurns(in: groupId, departed: userId)
    }

    /// `private.hand_over_turns` (docs/CONTRACTS-V2.md §6): every pending (`status ≠ done`) occurrence of a rotating
    /// task of the group whose turn holder was `departed` (or whose turn is NULL while it lists `departed`) is handed
    /// over at once, in task id order:
    /// - at least 2 members of the rotation left: the next member cyclically after `departed`'s position takes the
    ///   turn, becomes the only assignee (`assigned_by` NULL, existing row kept) and `turn_started` is written; the
    ///   stored rotation keeps `departed` until the next spawn;
    /// - fewer: the rotation and the turn are dropped (the rule stays) and the remaining member, if any, becomes an
    ///   assignee (`assigned_by` NULL); no `turn_started`.
    private mutating func handOverTurns(in groupId: UUID, departed: UUID) {
        guard data.groups[groupId] != nil else { return }
        let pending = data.tasks.values.filter { task in
            task.groupId == groupId && task.status != .done && !task.rotation.isEmpty
                && (task.turnUserId == departed || (task.turnUserId == nil && task.rotation.contains(departed)))
        }
        for task in pending.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let data = data
            let handover = RotationHandover(after: task.rotation, turnUserId: departed) { data.isMember($0, of: groupId) }
            if let turn = handover.turnUserId {
                self.data.tasks[task.id]?.turnUserId = turn
                for userId in data.assigneeIds(of: task.id) where userId != turn {
                    self.data.assignees[task.id]?[userId] = nil
                }
                if self.data.assignees[task.id]?[turn] == nil {
                    insertAssignee(taskId: task.id, groupId: groupId, userId: turn, assignedBy: nil)
                }
                bump(groupId)
                logActivity(
                    groupId: groupId, kind: .turnStarted, subjectId: turn, taskId: task.id, taskTitle: task.title
                )
            } else {
                self.data.tasks[task.id]?.rotation = []
                self.data.tasks[task.id]?.turnUserId = nil
                if let remaining = handover.assigneeId, self.data.assignees[task.id]?[remaining] == nil {
                    insertAssignee(taskId: task.id, groupId: groupId, userId: remaining, assignedBy: nil)
                }
                bump(groupId)
            }
        }
    }

    /// Deletes a group and cascades to its invite, members, tasks, assignees, checklist items and activity feed. No
    /// event is written for a group being deleted, and nothing is handed over.
    mutating func deleteGroup(_ groupId: UUID) {
        for userId in (data.members[groupId] ?? [:]).keys {
            membershipsChanged(userId)
        }
        data.members[groupId] = nil
        for taskId in data.taskIds(in: groupId) {
            data.tasks[taskId] = nil
            data.assignees[taskId] = nil
        }
        data.checklistItems = data.checklistItems.filter { $0.value.groupId != groupId }
        data.activity.removeAll { $0.groupId == groupId }
        data.invites[groupId] = nil
        data.groups[groupId] = nil
    }

    /// Safety net: a group with members but no admin gets its oldest member promoted.
    private mutating func healGroupsWithoutAdmin() {
        for groupId in groupsThatLostMembers.sortedByUUIDString() {
            guard data.groups[groupId] != nil,
                  let members = data.members[groupId], !members.isEmpty,
                  !members.values.contains(where: { $0.role == .admin }),
                  let oldest = members.values.min(by: MemberRecord.joinedBefore)
            else { continue }
            updateRole(groupId: groupId, userId: oldest.userId, role: .admin)
        }
    }

    // MARK: Assignees

    mutating func insertAssignee(taskId: UUID, groupId: UUID, userId: UUID, assignedBy: UUID?) {
        let row = AssigneeRecord(taskId: taskId, groupId: groupId, userId: userId, assignedBy: assignedBy, assignedAt: now)
        data.assignees[taskId, default: [:]][userId] = row
        insertedAssignments.append(row)
        bump(groupId)
    }

    /// `set_task_assignees`: keeps rows (and their metadata) of users still listed, deletes the others,
    /// inserts the new ones with `assigned_by = me`.
    mutating func replaceAssignees(of task: TaskRecord, with userIds: Set<UUID>, by me: UUID) {
        let current = Set((data.assignees[task.id] ?? [:]).keys)
        for userId in current.subtracting(userIds) {
            data.assignees[task.id]?[userId] = nil
            bump(task.groupId)
        }
        for userId in userIds.subtracting(current).sortedByUUIDString() {
            insertAssignee(taskId: task.id, groupId: task.groupId, userId: userId, assignedBy: me)
        }
        if data.assignees[task.id]?.isEmpty == true {
            data.assignees[task.id] = nil
        }
    }

    // MARK: Tasks (v2)

    /// A new checklist item (unchecked). Bumps the group like every checklist write.
    @discardableResult
    mutating func insertChecklistItem(taskId: UUID, groupId: UUID, title: String, position: Int) -> ChecklistItemRecord {
        let item = ChecklistItemRecord(
            id: UUID(), taskId: taskId, groupId: groupId, title: title, position: position, createdAt: now
        )
        data.checklistItems[item.id] = item
        bump(groupId)
        return item
    }

    /// Deletes a task with its assignees and checklist items (FK cascades). Its activity events stay (no FK).
    mutating func deleteTask(_ task: TaskRecord) {
        data.tasks[task.id] = nil
        data.assignees[task.id] = nil
        data.checklistItems = data.checklistItems.filter { $0.value.taskId != task.id }
        bump(task.groupId)
    }

    /// `private.spawn_next_occurrence` (docs/CONTRACTS-V2.md §6), for `task`, a recurring occurrence whose status is
    /// becoming done: inserts the next occurrence and returns its id.
    /// - due date: `NextDueCalculator` with this transaction's `now` (the completion time);
    /// - copied: group, title, details, priority, the rule (`monthDay` as is), the series creator, the series id;
    ///   status todo; the checklist, unchecked, with the same positions;
    /// - rotation: `RotationHandover` after the turn holder; its assignee has `assigned_by` NULL, or the completer when
    ///   the completer takes the turn; without rotation, the same assignees, each a continuation (`assigned_by` =
    ///   the assignee);
    /// - `turn_started` when the new occurrence has a turn holder. No `task_created`, no write quota.
    mutating func spawnNextOccurrence(of task: TaskRecord) -> UUID? {
        guard let rule = task.recurrence, let dueAt = task.dueAt,
              let due = NextDueCalculator.nextDueDate(after: dueAt, rule: rule, now: now)
        else { return nil }
        let data = data
        var rotation: [UUID] = []
        var turn: UUID?
        var assignee: UUID?
        if !task.rotation.isEmpty {
            let handover = RotationHandover(after: task.rotation, turnUserId: task.turnUserId) {
                data.isMember($0, of: task.groupId)
            }
            rotation = handover.rotation
            turn = handover.turnUserId
            assignee = handover.assigneeId
        }
        let next = TaskRecord(
            id: UUID(),
            groupId: task.groupId,
            title: task.title,
            details: task.details,
            status: .todo,
            priority: task.priority,
            dueAt: due,
            createdBy: task.createdBy,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            recurrence: rule,
            seriesId: task.seriesId ?? task.id,
            nextOccurrenceId: nil,
            rotation: rotation,
            turnUserId: turn,
            completedBy: nil
        )
        self.data.tasks[next.id] = next
        bump(task.groupId)
        for item in data.checklist(of: task.id) {
            insertChecklistItem(taskId: next.id, groupId: task.groupId, title: item.title, position: item.position)
        }
        if !task.rotation.isEmpty {
            if let assignee {
                let assignedBy = assignee == actor ? actor : nil
                insertAssignee(taskId: next.id, groupId: task.groupId, userId: assignee, assignedBy: assignedBy)
            }
        } else {
            for userId in data.assigneeIds(of: task.id) {
                insertAssignee(taskId: next.id, groupId: task.groupId, userId: userId, assignedBy: userId)
            }
        }
        if let turn {
            logActivity(groupId: task.groupId, kind: .turnStarted, subjectId: turn, taskId: next.id, taskTitle: task.title)
        }
        return next.id
    }

    // MARK: Accounts

    /// `delete_my_account()` (docs/CONTRACTS.md §2), then the cascade of deleting the auth user.
    mutating func deleteAccount(_ userId: UUID) {
        for groupId in data.groupIds(of: userId) {
            guard let members = data.members[groupId] else { continue }
            if members.count == 1 {
                deleteGroup(groupId)
                continue
            }
            if members[userId]?.role == .admin, data.adminCount(in: groupId) == 1,
               let oldest = members.values.filter({ $0.userId != userId }).min(by: MemberRecord.joinedBefore) {
                updateRole(groupId: groupId, userId: oldest.userId, role: .admin)
            }
        }
        // auth.users → profiles: the profile row goes first, so the membership cascade below writes `member_left`
        // with no actor nor subject (their profile no longer exists), then the turn handovers.
        data.profiles[userId] = nil
        data.accounts[userId] = nil
        for groupId in data.groupIds(of: userId) {
            deleteMembership(groupId: groupId, userId: userId)
        }
        // ON DELETE SET NULL fires the UPDATE triggers: the group bumps, but `tasks_before_update` keeps
        // `updated_at` (no editable field changed).
        for taskId in Array(data.tasks.keys) {
            guard let task = data.tasks[taskId] else { continue }
            var updated = task
            if updated.createdBy == userId { updated.createdBy = nil }
            if updated.turnUserId == userId { updated.turnUserId = nil }
            if updated.completedBy == userId { updated.completedBy = nil }
            guard updated.createdBy != task.createdBy || updated.turnUserId != task.turnUserId
                || updated.completedBy != task.completedBy
            else { continue }
            data.tasks[taskId] = updated
            bump(task.groupId)
        }
        for taskId in Array(data.assignees.keys) {
            for (assigneeId, row) in data.assignees[taskId] ?? [:] where row.assignedBy == userId {
                data.assignees[taskId]?[assigneeId]?.assignedBy = nil
                bump(row.groupId)
            }
        }
        for (itemId, item) in data.checklistItems where item.doneBy == userId {
            data.checklistItems[itemId]?.doneBy = nil
            bump(item.groupId)
        }
        // group_activity: no trigger, no bump.
        for index in data.activity.indices {
            if data.activity[index].actorId == userId { data.activity[index].actorId = nil }
            if data.activity[index].subjectId == userId { data.activity[index].subjectId = nil }
        }
        for groupId in Array(data.groups.keys) where data.groups[groupId]?.createdBy == userId {
            data.groups[groupId]?.createdBy = nil
            touch(groupId)
        }
        for groupId in Array(data.invites.keys) where data.invites[groupId]?.createdBy == userId {
            data.invites[groupId]?.createdBy = nil
        }
        data.pushTopics[userId] = nil
        data.recoveries[userId] = nil
        membershipChangedUsers.remove(userId)
        updatedProfiles.remove(userId)
    }
}
