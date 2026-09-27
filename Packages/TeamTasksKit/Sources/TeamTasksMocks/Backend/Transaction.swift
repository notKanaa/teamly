import Foundation
import TeamTasksCore

/// One write "transaction" on a copy of the data. It also records the change signals of
/// docs/CONTRACTS.md §6 (at most one bump per group per transaction), applied by `finish()`, and mirrors the server
/// triggers of docs/CONTRACTS-V2.md (activity feed, spawn of the next occurrence, turn handover) and
/// docs/CONTRACTS-V3.md (absence skip, swap repayment and automatic cancellation, the rows published to Realtime).
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
    /// v3: new `task_nudges` rows (Realtime INSERT).
    private(set) var insertedNudges: [NudgeRecord] = []
    /// v3: new `turn_swaps` rows (Realtime INSERT).
    private(set) var insertedSwaps: [UUID] = []
    /// v3: updated `turn_swaps` rows, in order, each once (Realtime UPDATE).
    private(set) var updatedSwaps: [UUID] = []
    /// v3: new `activity_reactions` rows (Realtime INSERT).
    private(set) var insertedReactions: [ReactionRecord] = []
    /// v3: new `task_comments` rows (Realtime INSERT).
    private(set) var insertedComments: [UUID] = []
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

    /// Runs the safety-net heal, cancels the swaps that no longer hold (v3) and applies the signal bumps. Called once,
    /// before commit.
    mutating func finish() {
        healGroupsWithoutAdmin()
        cancelStaleSwaps()
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
    /// v3: the reactions of a deleted event go with it (`on delete cascade`).
    mutating func logActivity(
        groupId: UUID,
        kind: ActivityKind,
        actorId: UUID? = nil,
        subjectId: UUID? = nil,
        taskId: UUID? = nil,
        taskTitle: String? = nil,
        itemTitle: String? = nil,
        startsOn: LocalDate? = nil,
        endsOn: LocalDate? = nil
    ) {
        guard data.groups[groupId] != nil else { return }
        let cutoff = now.addingTimeInterval(-TimeInterval(Limits.activityRetentionDays) * 86_400)
        let expired = Set(data.activity.filter { $0.groupId == groupId && $0.createdAt < cutoff }.map(\.id))
        if !expired.isEmpty {
            data.activity.removeAll { expired.contains($0.id) }
            data.reactions.removeAll { expired.contains($0.activityId) }
        }
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
            createdAt: now,
            startsOn: startsOn,
            endsOn: endsOn
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
    ///   turn (v3: skipping the members away on the occurrence's local due date), becomes the only assignee
    ///   (`assigned_by` NULL, existing row kept) and `turn_started` is written; the stored rotation keeps `departed`
    ///   until the next spawn;
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
            let day = data.localDueDate(of: task)
            let handover = RotationHandover(
                after: task.rotation, turnUserId: departed, isMember: { data.isMember($0, of: groupId) },
                isAway: { data.isAway($0, on: day) }
            )
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

    /// Deletes a group and cascades to its invite, members, tasks, assignees, checklist items and activity feed (v3:
    /// nudges, swaps, reactions, comments and photo rows; the stored objects are left behind). No event is written for
    /// a group being deleted, and nothing is handed over.
    mutating func deleteGroup(_ groupId: UUID) {
        data.nudges.removeAll { $0.groupId == groupId }
        data.swaps = data.swaps.filter { $0.value.groupId != groupId }
        data.reactions.removeAll { $0.groupId == groupId }
        data.comments = data.comments.filter { $0.value.groupId != groupId }
        data.photos = data.photos.filter { $0.value.groupId != groupId }
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

    /// Deletes a task with its assignees and checklist items (FK cascades); v3: with its nudges, swaps, comments and
    /// photo rows (the stored objects are left behind). Its activity events stay (no FK).
    mutating func deleteTask(_ task: TaskRecord) {
        data.tasks[task.id] = nil
        data.assignees[task.id] = nil
        data.checklistItems = data.checklistItems.filter { $0.value.taskId != task.id }
        data.nudges.removeAll { $0.taskId == task.id }
        data.swaps = data.swaps.filter { $0.value.taskId != task.id }
        data.comments = data.comments.filter { $0.value.taskId != task.id }
        data.photos = data.photos.filter { $0.value.taskId != task.id }
        bump(task.groupId)
    }

    /// `private.spawn_next_occurrence` (docs/CONTRACTS-V2.md §6), for `task`, a recurring occurrence whose status is
    /// becoming done: inserts the next occurrence and returns its id.
    /// - due date: `NextDueCalculator` with this transaction's `now` (the completion time);
    /// - copied: group, title, details, priority, the rule (`monthDay` as is), the series creator, the series id;
    ///   status todo; the checklist, unchecked, with the same positions;
    /// - rotation: `RotationHandover` after the turn holder, skipping the members away on the new due date (v3); then
    ///   the repayment of a swap (`repaySwap`); its assignee has `assigned_by` NULL, or the completer when the completer
    ///   takes the turn; without rotation, the same assignees, each a continuation (`assigned_by` = the assignee);
    /// - `turn_started` when the new occurrence has a turn holder. No `task_created`, no write quota.
    mutating func spawnNextOccurrence(of task: TaskRecord) -> UUID? {
        guard let rule = task.recurrence, let dueAt = task.dueAt,
              let due = NextDueCalculator.nextDueDate(after: dueAt, rule: rule, now: now)
        else { return nil }
        let data = data
        let seriesId = task.seriesId ?? task.id
        let day = rule.timeZone.map { LocalDate(due, timeZone: $0) }
        var rotation: [UUID] = []
        var turn: UUID?
        var assignee: UUID?
        if !task.rotation.isEmpty {
            let handover = RotationHandover(
                after: task.rotation, turnUserId: task.turnUserId, isMember: { data.isMember($0, of: task.groupId) },
                isAway: { data.isAway($0, on: day) }
            )
            rotation = handover.rotation
            turn = handover.turnUserId
            assignee = handover.assigneeId
            if let next = turn, let repaid = repaySwap(seriesId: seriesId, nextTurn: next, rotation: rotation, groupId: task.groupId, day: day) {
                turn = repaid
                assignee = repaid
            }
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
            seriesId: seriesId,
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

    // MARK: Turn swaps (v3, docs/CONTRACTS-V3.md §3)

    /// The repayment at a spawn: the oldest (`created_at`, then id) accepted swap of the series taken by `nextTurn`,
    /// not repaid yet, whose author is still a member listed in the new rotation (a swap whose author left never blocks
    /// the others). When that author is not away on the new due date, the turn goes back to them and the swap gets
    /// `repaid_at = now()` (a Realtime UPDATE for its author); otherwise nothing is repaid this time. Returns the
    /// author, or nil when nothing is repaid.
    private mutating func repaySwap(seriesId: UUID, nextTurn: UUID, rotation: [UUID], groupId: UUID, day: LocalDate?) -> UUID? {
        let data = data
        guard let swap = data.swaps.values
            .filter({ swap in
                swap.seriesId == seriesId && swap.status == .accepted && swap.toUser == nextTurn && swap.repaidAt == nil
                    && data.isMember(swap.fromUser, of: groupId) && rotation.contains(swap.fromUser)
            })
            .min(by: SwapRecord.olderFirst)
        else { return nil }
        let author = swap.fromUser
        guard !data.isAway(author, on: day) else { return nil }
        let now = now // local copy: see finish()
        self.data.swaps[swap.id]?.repaidAt = now
        bump(groupId)
        swapUpdated(swap.id)
        return author
    }

    mutating func swapInserted(_ swapId: UUID) {
        insertedSwaps.append(swapId)
    }

    mutating func swapUpdated(_ swapId: UUID) {
        if !updatedSwaps.contains(swapId) { updatedSwaps.append(swapId) }
    }

    /// Automatic cancellation: a pending swap that can no longer be accepted as asked becomes `cancelled`, with
    /// `responded_at`: its occurrence is done, lost its rotation, has another turn holder than the author, or no longer
    /// lists the target; or the author or the target is no longer a member of the group. Deleted occurrences and
    /// deleted accounts take their swaps with them (no UPDATE). The group bumps.
    private mutating func cancelStaleSwaps() {
        let now = now
        for swap in data.swaps.values where swap.status == .pending {
            guard let task = data.tasks[swap.taskId] else { continue }
            let holds = task.status != .done && !task.rotation.isEmpty && task.turnUserId == swap.fromUser
                && task.rotation.contains(swap.toUser)
                && data.isMember(swap.fromUser, of: swap.groupId) && data.isMember(swap.toUser, of: swap.groupId)
            guard !holds else { continue }
            data.swaps[swap.id]?.status = .cancelled
            data.swaps[swap.id]?.respondedAt = now
            bumpedGroups.insert(swap.groupId)
            swapUpdated(swap.id)
        }
    }

    // MARK: Social rows (v3)

    mutating func insertNudge(_ nudge: NudgeRecord) {
        data.nudges.append(nudge)
        insertedNudges.append(nudge)
    }

    mutating func insertReaction(_ reaction: ReactionRecord) {
        data.reactions.append(reaction)
        insertedReactions.append(reaction)
    }

    mutating func insertComment(_ comment: CommentRecord) {
        data.comments[comment.id] = comment
        insertedComments.append(comment.id)
    }

    // MARK: Mode absent (v3, docs/CONTRACTS-V3.md §2)

    /// The handover of `set_away`: every pending occurrence of a rotating task whose turn `userId` holds and whose local
    /// due date is in `from…until` goes to the next member after them (`RotationHandover`, absence skip included),
    /// assigned by nobody, with a `turn_started` event. An occurrence whose rotation has fewer than 2 members is left
    /// alone. In due date order, then task id order.
    mutating func handOverTurnsOfAbsence(of userId: UUID, from: LocalDate, until: LocalDate) {
        let pending = data.tasks.values.filter { task in
            guard task.status != .done, !task.rotation.isEmpty, task.turnUserId == userId,
                  let day = data.localDueDate(of: task)
            else { return false }
            return from <= day && day <= until
        }
        let ordered = pending.sorted { lhs, rhs in
            (lhs.dueAt ?? .distantPast, lhs.id.uuidString) < (rhs.dueAt ?? .distantPast, rhs.id.uuidString)
        }
        for task in ordered {
            let data = data
            let day = data.localDueDate(of: task)
            let handover = RotationHandover(
                after: task.rotation, turnUserId: userId, isMember: { data.isMember($0, of: task.groupId) },
                isAway: { data.isAway($0, on: day) }
            )
            guard let turn = handover.turnUserId, turn != userId else { continue }
            self.data.tasks[task.id]?.turnUserId = turn
            for assigneeId in data.assigneeIds(of: task.id) where assigneeId != turn {
                self.data.assignees[task.id]?[assigneeId] = nil
            }
            if self.data.assignees[task.id]?[turn] == nil {
                insertAssignee(taskId: task.id, groupId: task.groupId, userId: turn, assignedBy: nil)
            }
            bump(task.groupId)
            logActivity(groupId: task.groupId, kind: .turnStarted, subjectId: turn, taskId: task.id, taskTitle: task.title)
        }
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
        // v3 cascades of the profile: nudges and swaps from or to the user, their reactions; `target_user`,
        // `author_id` and `uploaded_by` become NULL.
        data.nudges.removeAll { $0.fromUser == userId || $0.toUser == userId }
        data.swaps = data.swaps.filter { $0.value.fromUser != userId && $0.value.toUser != userId }
        data.reactions.removeAll { $0.userId == userId }
        for index in data.reactions.indices where data.reactions[index].targetUser == userId {
            data.reactions[index].targetUser = nil
        }
        for (commentId, comment) in data.comments where comment.authorId == userId {
            data.comments[commentId]?.authorId = nil
        }
        for (photoId, photo) in data.photos where photo.uploadedBy == userId {
            data.photos[photoId]?.uploadedBy = nil
        }
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
