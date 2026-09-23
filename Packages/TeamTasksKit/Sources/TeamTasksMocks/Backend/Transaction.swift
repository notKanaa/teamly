import Foundation
import TeamTasksCore

/// One write "transaction" on a copy of the data. It also records the change signals of
/// docs/CONTRACTS.md §6 (at most one bump per group per transaction), applied by `finish()`.
struct Transaction {
    var data: BackendData
    /// Like Postgres `now()`: one timestamp for the whole transaction.
    let now: Date

    /// Groups whose `last_activity_at` is bumped (tasks, assignees, members, rename).
    private(set) var bumpedGroups: Set<UUID> = []
    /// Groups whose row is updated without a bump (e.g. `created_by` set to NULL): Realtime UPDATE only.
    private(set) var touchedGroups: Set<UUID> = []
    /// Users whose `memberships_changed_at` is bumped.
    private(set) var membershipChangedUsers: Set<UUID> = []
    /// Users whose profile row is updated for another reason (display name).
    private(set) var updatedProfiles: Set<UUID> = []
    /// New `task_assignees` rows (Realtime INSERT).
    private(set) var insertedAssignments: [AssigneeRecord] = []
    /// Groups that lost a member (safety-net heal trigger).
    private var groupsThatLostMembers: Set<UUID> = []

    init(data: BackendData, now: Date) {
        self.data = data
        self.now = now
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

    // MARK: Memberships

    mutating func insertMembership(groupId: UUID, userId: UUID, role: MemberRole) {
        data.members[groupId, default: [:]][userId] = MemberRecord(
            groupId: groupId, userId: userId, role: role, joinedAt: now
        )
        bump(groupId)
        membershipsChanged(userId)
    }

    /// Changes a role; an unchanged role writes nothing (no bump).
    mutating func updateRole(groupId: UUID, userId: UUID, role: MemberRole) {
        guard let current = data.members[groupId]?[userId]?.role, current != role else { return }
        data.members[groupId]?[userId]?.role = role
        bump(groupId)
        membershipsChanged(userId)
    }

    /// Deletes a membership; the FK cascade deletes the user's assignments in that group.
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
    }

    /// Deletes a group and cascades to its invite, members, tasks and assignees.
    mutating func deleteGroup(_ groupId: UUID) {
        for userId in (data.members[groupId] ?? [:]).keys {
            membershipsChanged(userId)
        }
        data.members[groupId] = nil
        for taskId in data.taskIds(in: groupId) {
            data.tasks[taskId] = nil
            data.assignees[taskId] = nil
        }
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
        // auth.users → profiles → group_members (and their assignments) cascade.
        for groupId in data.groupIds(of: userId) {
            deleteMembership(groupId: groupId, userId: userId)
        }
        // ON DELETE SET NULL fires the UPDATE triggers: the group bumps, but `tasks_before_update` keeps
        // `updated_at` (no editable field changed).
        for taskId in Array(data.tasks.keys) where data.tasks[taskId]?.createdBy == userId {
            data.tasks[taskId]?.createdBy = nil
            if let groupId = data.tasks[taskId]?.groupId { bump(groupId) }
        }
        for taskId in Array(data.assignees.keys) {
            for (assigneeId, row) in data.assignees[taskId] ?? [:] where row.assignedBy == userId {
                data.assignees[taskId]?[assigneeId]?.assignedBy = nil
                bump(row.groupId)
            }
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
        data.profiles[userId] = nil
        data.accounts[userId] = nil
        membershipChangedUsers.remove(userId)
        updatedProfiles.remove(userId)
    }
}
