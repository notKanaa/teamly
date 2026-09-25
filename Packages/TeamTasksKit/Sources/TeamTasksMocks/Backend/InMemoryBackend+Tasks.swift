import Foundation
import TeamTasksCore

// Tasks, assignees and checklists (docs/CONTRACTS.md §2, §4; docs/CONTRACTS-V2.md §0, §3–§8).
extension InMemoryBackend {
    // MARK: - Reads

    /// Tasks of a group (empty for non-members, like RLS). Unless `includeOldDone`, done tasks completed
    /// before `now - Limits.oldDoneTaskDays` are omitted (`completed_at.gte.<now-30d>` keeps the boundary).
    func tasks(clientId: UUID, groupId: UUID, includeOldDone: Bool) throws -> [TaskItem] {
        try read(as: clientId) { data, me in
            guard data.isMember(me, of: groupId) else { return [] }
            let cutoff = nowProvider().addingTimeInterval(-TimeInterval(Limits.oldDoneTaskDays) * 86_400)
            return data.tasks.values
                .filter { task in
                    guard task.groupId == groupId else { return false }
                    if includeOldDone || task.status != .done { return true }
                    return (task.completedAt ?? .distantPast) >= cutoff
                }
                .sorted(by: InMemoryBackend.creationOrder)
                .map(data.taskItem)
        }
    }

    /// Tasks assigned to the caller, with `myAssignedAt`, `myAssignedBy`, `groupName` and (v2) `groupColor` and
    /// `groupEmoji`. Unless `includeDone`, done tasks are omitted.
    func myTasks(clientId: UUID, includeDone: Bool) throws -> [TaskItem] {
        try read(as: clientId) { data, me in
            data.tasks.values
                .filter { task in
                    data.assignees[task.id]?[me] != nil && (includeDone || task.status != .done)
                }
                .sorted(by: InMemoryBackend.creationOrder)
                .map { task in
                    var item = data.taskItem(task)
                    let mine = data.assignees[task.id]?[me]
                    let group = data.groups[task.groupId]
                    item.myAssignedAt = mine?.assignedAt
                    item.myAssignedBy = mine?.assignedBy
                    item.groupName = group?.name
                    item.groupColor = group?.color
                    item.groupEmoji = group?.emoji
                    return item
                }
        }
    }

    /// One task; `.notFound` when it does not exist or is not visible.
    func task(clientId: UUID, taskId: UUID) throws -> TaskItem {
        try read(as: clientId) { data, me in
            guard let task = data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            return data.taskItem(task)
        }
    }

    /// Assignments of the caller made by someone else (or by nobody: a deleted user, a rotation turn handed out by the
    /// server) strictly after `since`, oldest first. v2: `taskHasRotation` reads the task's current rotation.
    func assignments(clientId: UUID, since: Date) throws -> [AssignmentEvent] {
        try read(as: clientId) { data, me in
            data.assignees.values
                .compactMap { $0[me] }
                .filter { $0.assignedAt > since && $0.assignedBy != me }
                .sorted { ($0.assignedAt, $0.taskId.uuidString) < ($1.assignedAt, $1.taskId.uuidString) }
                .compactMap { row -> AssignmentEvent? in
                    guard let task = data.tasks[row.taskId], let group = data.groups[row.groupId] else { return nil }
                    return AssignmentEvent(
                        taskId: task.id,
                        groupId: group.id,
                        taskTitle: task.title,
                        groupName: group.name,
                        assignedBy: row.assignedBy,
                        assignedAt: row.assignedAt,
                        dueAt: task.dueAt,
                        taskHasRotation: !task.rotation.isEmpty
                    )
                }
        }
    }

    /// v2 recap read (docs/CONTRACTS-V2.md §8): the group's done tasks with `completed_at >= since` (inclusive).
    /// Non-members read nothing.
    func completions(clientId: UUID, groupId: UUID, since: Date) throws -> [TaskCompletion] {
        try read(as: clientId) { data, me in
            guard data.isMember(me, of: groupId) else { return [] }
            return data.tasks.values
                .filter { $0.groupId == groupId && $0.status == .done }
                .sorted(by: InMemoryBackend.creationOrder)
                .compactMap { task -> TaskCompletion? in
                    guard let completedAt = task.completedAt, completedAt >= since else { return nil }
                    return TaskCompletion(taskId: task.id, completedBy: task.completedBy, completedAt: completedAt)
                }
        }
    }

    // MARK: - Task RPCs

    /// `create_task`: members only (`.forbidden` otherwise), then, in the order of docs/CONTRACTS-V2.md §3: title,
    /// details, due date, recurrence (shape, then the due date), rotation (with its membership), assignees when there
    /// is no rotation (count, then membership), checklist (each title, then the count). The write quota is not
    /// mirrored. With a rotation the assignee ids are ignored: `rotation[0]` is the turn holder and the only assignee,
    /// assigned by the creator. The checklist items get the positions 1…n. Writes `task_created`.
    func createTask(clientId: UUID, groupId: UUID, draft: TaskDraft) throws -> TaskItem {
        try write(as: clientId) { transaction, me in
            guard transaction.data.isMember(me, of: groupId) else { throw AppError.forbidden }
            let title = try InputRules.title(draft.title)
            let details = try InputRules.details(draft.details)
            let dueAt = try InputRules.dueDate(draft.dueAt)
            let rule = try InputRules.recurrence(draft.recurrence, dueAt: dueAt)
            let rotation = try InputRules.rotation(
                draft.rotation, recurrence: rule, groupId: groupId, in: transaction.data
            )
            if rotation.isEmpty {
                try InputRules.assignees(draft.assigneeIds, groupId: groupId, in: transaction.data)
            }
            let checklist = try InputRules.checklist(draft.checklist)

            var task = TaskRecord(
                id: UUID(),
                groupId: groupId,
                title: title,
                details: details,
                status: .todo,
                priority: draft.priority,
                dueAt: dueAt,
                createdBy: me,
                createdAt: transaction.now,
                updatedAt: transaction.now,
                completedAt: nil
            )
            if let rule, let dueAt {
                task.recurrence = StoredRecurrence.created(rule, dueAt: dueAt)
                task.seriesId = task.id
                task.rotation = rotation
                task.turnUserId = rotation.first
            }
            transaction.data.tasks[task.id] = task
            transaction.bump(groupId)
            // tasks_after_insert_v2: task_created, the rotation's first turn, the checklist.
            transaction.logActivity(groupId: groupId, kind: .taskCreated, actorId: me, taskId: task.id, taskTitle: title)
            if let turn = task.turnUserId {
                transaction.insertAssignee(taskId: task.id, groupId: groupId, userId: turn, assignedBy: me)
            }
            for (index, itemTitle) in checklist.enumerated() {
                transaction.insertChecklistItem(taskId: task.id, groupId: groupId, title: itemTitle, position: index + 1)
            }
            // create_task then calls set_task_assignees for a task without rotation.
            if task.rotation.isEmpty {
                for userId in draft.assigneeIds.sortedByUUIDString() {
                    transaction.insertAssignee(taskId: task.id, groupId: groupId, userId: userId, assignedBy: me)
                }
            }
            return transaction.data.taskItem(task)
        }
    }

    /// `update_task` as the Swift client calls it: a full edit (fields, assignees, recurrence, rotation), admin or
    /// creator only. A nil due date clears it. The row is always updated (group bump); `updatedAt` only moves when a
    /// v1 field changes.
    /// - recurrence: nil is sent as `{}`: the task becomes a plain task (rule, rotation and turn cleared; the
    ///   checklist, the assignees and `nextOccurrenceId` stay, then the draft's assignees apply). A rule needs a due
    ///   date (`.recurrenceNeedsDueDate`, checked after its shape); `monthDay` is the server's (never sent).
    /// - rotation: empty = none; the stored list sent back as is = unchanged (not checked again, even if someone
    ///   listed has left); another list is checked like on create. A new rotation keeps the turn holder when still
    ///   listed, else the turn goes to `rotation[0]`; the turn holder then becomes the only assignee (assigned by the
    ///   editor, an existing row kept).
    /// - assignees: ignored while the task has a rotation after the edit; otherwise `set_task_assignees`.
    /// Editing the rule never spawns an occurrence.
    func updateTask(clientId: UUID, taskId: UUID, draft: TaskDraft) throws -> TaskItem {
        try write(as: clientId) { transaction, me in
            guard let stored = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            guard transaction.data.canEdit(stored, userId: me) else { throw AppError.forbidden }
            var task = stored
            task.title = try InputRules.title(draft.title)
            task.details = try InputRules.details(draft.details)
            task.dueAt = try InputRules.dueDate(draft.dueAt)
            task.priority = draft.priority

            // tasks_before_update_v2, step 1: the draft's recurrence (never NULL from the Swift client) …
            if let rule = draft.recurrence {
                task.recurrence = try InputValidation.recurrence(rule)
                guard task.dueAt != nil else { throw AppError.recurrenceNeedsDueDate }
            } else {
                task.recurrence = nil
                task.rotation = []
            }
            // … then its rotation.
            if draft.rotation.isEmpty {
                task.rotation = []
            } else if draft.rotation != stored.rotation {
                guard task.recurrence != nil else { throw AppError.invalidRotation }
                task.rotation = try InputRules.rotation(
                    draft.rotation, recurrence: task.recurrence, groupId: task.groupId, in: transaction.data
                )
            }

            // Step 2: the server-maintained fields.
            if let rule = task.recurrence, let dueAt = task.dueAt {
                task.recurrence = StoredRecurrence.updated(rule, dueAt: dueAt, stored: stored)
                task.seriesId = stored.seriesId ?? task.id
                if task.rotation.isEmpty {
                    task.turnUserId = nil
                } else if task.rotation != stored.rotation,
                          task.turnUserId.map({ !task.rotation.contains($0) }) ?? true {
                    task.turnUserId = task.rotation.first
                }
            } else {
                task.recurrence = nil
                task.seriesId = nil
                task.rotation = []
                task.turnUserId = nil
            }
            task.touch(from: stored, at: transaction.now)
            transaction.data.tasks[task.id] = task
            transaction.bump(task.groupId)

            // tasks_after_update_v2: a new rotation or turn holder → the turn holder is the only assignee.
            if let turn = task.turnUserId, task.rotation != stored.rotation || turn != stored.turnUserId {
                for userId in transaction.data.assigneeIds(of: task.id) where userId != turn {
                    transaction.data.assignees[task.id]?[userId] = nil
                    transaction.bump(task.groupId)
                }
                if transaction.data.assignees[task.id]?[turn] == nil, transaction.data.isMember(turn, of: task.groupId) {
                    transaction.insertAssignee(taskId: task.id, groupId: task.groupId, userId: turn, assignedBy: me)
                }
            }
            // update_task then calls set_task_assignees for a task without rotation.
            if task.rotation.isEmpty {
                try InputRules.assignees(draft.assigneeIds, groupId: task.groupId, in: transaction.data)
                transaction.replaceAssignees(of: task, with: draft.assigneeIds, by: me)
            }
            guard let updated = transaction.data.tasks[task.id] else { throw AppError.notFound }
            return transaction.data.taskItem(updated)
        }
    }

    /// `set_task_status`: admin, creator or assignee. `completed_at` and (v2) `completed_by` are set when the task
    /// becomes done (kept if it already was) and cleared otherwise; `updatedAt` only moves when the status changes.
    /// v2: becoming done writes `task_completed`, then spawns the next occurrence of a recurring task that has none
    /// yet (reopening and completing again spawns nothing more).
    func setStatus(clientId: UUID, taskId: UUID, status: TaskStatus) throws -> TaskItem {
        try write(as: clientId) { transaction, me in
            guard let stored = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            guard transaction.data.canChangeStatus(stored, userId: me) else { throw AppError.forbidden }
            var task = stored
            let becomesDone = status == .done && stored.status != .done
            if status == .done {
                if becomesDone {
                    task.completedAt = transaction.now
                    task.completedBy = me
                }
            } else {
                task.completedAt = nil
                task.completedBy = nil
            }
            task.status = status
            task.touch(from: stored, at: transaction.now)
            if becomesDone {
                transaction.logActivity(
                    groupId: task.groupId, kind: .taskCompleted, actorId: me, taskId: task.id, taskTitle: task.title
                )
                if task.recurrence != nil, task.nextOccurrenceId == nil {
                    task.nextOccurrenceId = transaction.spawnNextOccurrence(of: task)
                }
            }
            transaction.data.tasks[task.id] = task
            transaction.bump(task.groupId)
            return transaction.data.taskItem(task)
        }
    }

    /// `delete_task`: admin or creator only; cascades to assignees and checklist items. Deleting the pending
    /// occurrence of a series ends it.
    func deleteTask(clientId: UUID, taskId: UUID) throws {
        try write(as: clientId) { transaction, me in
            guard let task = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            guard transaction.data.canEdit(task, userId: me) else { throw AppError.forbidden }
            transaction.deleteTask(task)
        }
    }

    // MARK: - Checklist RPCs (docs/CONTRACTS-V2.md §5): the rights of « change status »; every write bumps the group.

    /// `add_checklist_item`: `task_not_found` (missing or not visible) → `forbidden` → title → at most 30 items.
    /// Position = the largest one + 1.
    func addChecklistItem(clientId: UUID, taskId: UUID, title: String) throws -> ChecklistItem {
        try write(as: clientId) { transaction, me in
            guard let task = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            guard transaction.data.canChangeStatus(task, userId: me) else { throw AppError.forbidden }
            let title = try InputRules.checklistItemTitle(title)
            let items = transaction.data.checklist(of: task.id)
            guard items.count < Limits.checklistItemsMax else { throw AppError.tooManyChecklistItems }
            let position = (items.map(\.position).max() ?? 0) + 1
            return transaction.insertChecklistItem(
                taskId: task.id, groupId: task.groupId, title: title, position: position
            ).item
        }
    }

    /// `rename_checklist_item`: `item_not_found` → `forbidden` → title. Always writes the row (and bumps).
    func renameChecklistItem(clientId: UUID, itemId: UUID, title: String) throws -> ChecklistItem {
        try write(as: clientId) { transaction, me in
            let item = try transaction.data.checklistItemForChange(itemId, by: me)
            let title = try InputRules.checklistItemTitle(title)
            transaction.data.checklistItems[item.id]?.title = title
            transaction.bump(item.groupId)
            guard let renamed = transaction.data.checklistItems[item.id] else { throw AppError.notFound }
            return renamed.item
        }
    }

    /// `set_checklist_item_done`: `item_not_found` → `forbidden`. The same value is a no-op (no write, no signal);
    /// checking sets `doneAt` / `doneBy` and writes `checklist_item_done`, unchecking clears them.
    func setChecklistItemDone(clientId: UUID, itemId: UUID, done: Bool) throws -> ChecklistItem {
        try write(as: clientId) { transaction, me in
            let item = try transaction.data.checklistItemForChange(itemId, by: me)
            guard item.done != done else { return item.item }
            var updated = item
            updated.done = done
            updated.doneAt = done ? transaction.now : nil
            updated.doneBy = done ? me : nil
            transaction.data.checklistItems[item.id] = updated
            transaction.bump(item.groupId)
            if done {
                transaction.logActivity(
                    groupId: item.groupId, kind: .checklistItemDone, actorId: me, taskId: item.taskId,
                    taskTitle: transaction.data.tasks[item.taskId]?.title, itemTitle: item.title
                )
            }
            return updated.item
        }
    }

    /// `delete_checklist_item`: `item_not_found` → `forbidden`. The other items keep their positions.
    func deleteChecklistItem(clientId: UUID, itemId: UUID) throws {
        try write(as: clientId) { transaction, me in
            let item = try transaction.data.checklistItemForChange(itemId, by: me)
            transaction.data.checklistItems[item.id] = nil
            transaction.bump(item.groupId)
        }
    }

    // MARK: - Helpers

    static func creationOrder(_ lhs: TaskRecord, _ rhs: TaskRecord) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
    }
}

extension BackendData {
    /// An item the caller may change: `.notFound` when it does not exist or is not visible (`item_not_found`),
    /// `.forbidden` without the « change status » rights on its task.
    func checklistItemForChange(_ itemId: UUID, by userId: UUID) throws -> ChecklistItemRecord {
        guard let item = visibleChecklistItem(itemId, to: userId), let task = tasks[item.taskId] else {
            throw AppError.notFound
        }
        guard canChangeStatus(task, userId: userId) else { throw AppError.forbidden }
        return item
    }
}
