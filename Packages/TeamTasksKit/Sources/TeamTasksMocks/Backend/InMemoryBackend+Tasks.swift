import Foundation
import TeamTasksCore

// Tasks and assignees (docs/CONTRACTS.md §2, §4).
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

    /// Tasks assigned to the caller, with `myAssignedAt` and `groupName`. Unless `includeDone`, done tasks are omitted.
    func myTasks(clientId: UUID, includeDone: Bool) throws -> [TaskItem] {
        try read(as: clientId) { data, me in
            data.tasks.values
                .filter { task in
                    data.assignees[task.id]?[me] != nil && (includeDone || task.status != .done)
                }
                .sorted(by: InMemoryBackend.creationOrder)
                .map { task in
                    var item = data.taskItem(task)
                    item.myAssignedAt = data.assignees[task.id]?[me]?.assignedAt
                    item.groupName = data.groups[task.groupId]?.name
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

    /// Assignments of the caller made by someone else (or by a deleted user) strictly after `since`, oldest first.
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
                        dueAt: task.dueAt
                    )
                }
        }
    }

    // MARK: - RPCs

    /// `create_task`: members only (`.forbidden` otherwise), atomic insert of the task and its assignees.
    func createTask(clientId: UUID, groupId: UUID, draft: TaskDraft) throws -> TaskItem {
        try write(as: clientId) { transaction, me in
            guard transaction.data.isMember(me, of: groupId) else { throw AppError.forbidden }
            let title = try InputRules.title(draft.title)
            let details = try InputRules.details(draft.details)
            try InputRules.assignees(draft.assigneeIds, groupId: groupId, in: transaction.data)
            let task = TaskRecord(
                id: UUID(),
                groupId: groupId,
                title: title,
                details: details,
                status: .todo,
                priority: draft.priority,
                dueAt: draft.dueAt,
                createdBy: me,
                createdAt: transaction.now,
                updatedAt: transaction.now,
                completedAt: nil
            )
            transaction.data.tasks[task.id] = task
            transaction.bump(groupId)
            for userId in draft.assigneeIds.sortedByUUIDString() {
                transaction.insertAssignee(taskId: task.id, groupId: groupId, userId: userId, assignedBy: me)
            }
            return transaction.data.taskItem(task)
        }
    }

    /// `update_task`: full edit (fields + assignees), admin or creator only. A nil due date clears it.
    func updateTask(clientId: UUID, taskId: UUID, draft: TaskDraft) throws -> TaskItem {
        try write(as: clientId) { transaction, me in
            guard var task = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            guard transaction.data.canEdit(task, userId: me) else { throw AppError.forbidden }
            task.title = try InputRules.title(draft.title)
            task.details = try InputRules.details(draft.details)
            try InputRules.assignees(draft.assigneeIds, groupId: task.groupId, in: transaction.data)
            task.priority = draft.priority
            task.dueAt = draft.dueAt
            task.updatedAt = transaction.now
            transaction.data.tasks[task.id] = task
            transaction.bump(task.groupId)
            transaction.replaceAssignees(of: task, with: draft.assigneeIds, by: me)
            return transaction.data.taskItem(task)
        }
    }

    /// `set_task_status`: admin, creator or assignee. `completed_at` is set when the task becomes done
    /// (kept if it already was) and cleared otherwise.
    func setStatus(clientId: UUID, taskId: UUID, status: TaskStatus) throws -> TaskItem {
        try write(as: clientId) { transaction, me in
            guard var task = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            guard transaction.data.canChangeStatus(task, userId: me) else { throw AppError.forbidden }
            if status == .done {
                if task.status != .done { task.completedAt = transaction.now }
            } else {
                task.completedAt = nil
            }
            task.status = status
            task.updatedAt = transaction.now
            transaction.data.tasks[task.id] = task
            transaction.bump(task.groupId)
            return transaction.data.taskItem(task)
        }
    }

    /// `delete_task`: admin or creator only; cascades to assignees.
    func deleteTask(clientId: UUID, taskId: UUID) throws {
        try write(as: clientId) { transaction, me in
            guard let task = transaction.data.visibleTask(taskId, to: me) else { throw AppError.notFound }
            guard transaction.data.canEdit(task, userId: me) else { throw AppError.forbidden }
            transaction.data.tasks[task.id] = nil
            transaction.data.assignees[task.id] = nil
            transaction.bump(task.groupId)
        }
    }

    // MARK: - Helpers

    static func creationOrder(_ lhs: TaskRecord, _ rhs: TaskRecord) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
    }
}
