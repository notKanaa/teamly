import Foundation
import TeamTasksCore

/// `TaskService` on the task RPCs and PostgREST reads (docs/CONTRACTS.md §1, §3, §4; docs/CONTRACTS-V2.md §3, §5,
/// §8, §10).
struct SupabaseTaskService: TaskService {
    let context: SupabaseContext

    private var rest: RestClient { context.rest }

    /// Unless `includeOldDone`: `or=(status.neq.done,completed_at.gte.<now − 30 × 86 400 s>)`.
    /// Non-members read an empty list (RLS). Tasks with a status, priority or repetition frequency unknown to this
    /// client (added by a later version) are left out (`RestClient.fetchRows`).
    func tasks(groupId: UUID, includeOldDone: Bool) async throws -> [TaskItem] {
        let now = context.now()
        let rows = try await rest.fetchRows(TaskDTO.self) { _ in
            RestQuery.groupTasks(groupId: groupId, includeOldDone: includeOldDone, now: now)
        }
        return rows.map { $0.item() }.sorted(by: TaskDTO.creationOrder)
    }

    /// Tasks with a value unknown to this client are left out, as in `tasks(groupId:includeOldDone:)`.
    func myTasks(includeDone: Bool) async throws -> [TaskItem] {
        let rows = try await rest.fetchRows(TaskDTO.self) { RestQuery.myTasks(me: $0.userId, includeDone: includeDone) }
        return rows.map(\.myTaskItem).sorted(by: TaskDTO.creationOrder)
    }

    /// 0 rows (unknown or not visible) → `.notFound`; a value unknown to this client → `.unknown`.
    func task(id: UUID) async throws -> TaskItem {
        let rows = try await rest.fetch([TaskDTO].self) { _ in RestQuery.task(id: id) }
        guard let row = rows.first else { throw AppError.notFound }
        return row.item()
    }

    /// `create_task` returns a bare `tasks` row. Without a checklist its assignees are known: the turn holder alone on
    /// a rotating task (the draft's assignees are ignored), else exactly the (validated) draft's. The ids of a new
    /// checklist's items are only known from a read of the task (`completed(_:)`); should that read fail, the task was
    /// created all the same: it is returned without its items rather than as an error (a retry would create it twice).
    func create(groupId: UUID, draft: TaskDraft) async throws -> TaskItem {
        let fields = try TaskFields(draft, for: .create)
        let row = try await rest.fetch(TaskDTO.self) { _ in
            RestQuery.rpc("create_task", fields.createParams(groupId: groupId))
        }
        let assignees = row.rotation == nil ? Array(fields.assigneeIds) : [row.turnUserId].compactMap { $0 }
        guard !fields.checklist.isEmpty else { return row.item(assigneeIds: assignees) }
        return (try? await completed(row)) ?? row.item(assigneeIds: assignees)
    }

    /// `update_task` is a full edit (fields, assignees, recurrence and rotation, docs/CONTRACTS-V2.md §5). It returns a
    /// bare `tasks` row, completed with the assignees and the checklist read right after (`completed(_:)`).
    func update(taskId: UUID, draft: TaskDraft) async throws -> TaskItem {
        let fields = try TaskFields(draft, for: .update)
        let row = try await rest.fetch(TaskDTO.self) { _ in
            RestQuery.rpc("update_task", fields.updateParams(taskId: taskId))
        }
        return try await completed(row)
    }

    /// `set_task_status` returns a bare `tasks` row (v2: with `completedBy`, and `nextOccurrenceId` once a recurring
    /// task is done), completed with the assignees and the checklist read right after (`completed(_:)`).
    func setStatus(taskId: UUID, status: TaskStatus) async throws -> TaskItem {
        let row = try await rest.fetch(TaskDTO.self) { _ in
            RestQuery.rpc("set_task_status", ["p_task_id": .uuid(taskId), "p_status": .string(status.rawValue)])
        }
        return try await completed(row)
    }

    func delete(taskId: UUID) async throws {
        _ = try await rest.send { _ in RestQuery.rpc("delete_task", ["p_task_id": .uuid(taskId)]) }
    }

    /// Exclusive `since` sent with microseconds; oldest first (server order, then task id for equal instants).
    /// v2: `taskHasRotation` from the embedded task's `rotation`.
    func assignments(since: Date) async throws -> [AssignmentEvent] {
        let rows = try await rest.fetch([AssignmentRow].self) { RestQuery.assignments(me: $0.userId, since: since) }
        return rows.compactMap(\.event).sorted { lhs, rhs in
            if lhs.assignedAt != rhs.assignedAt { return lhs.assignedAt < rhs.assignedAt }
            return lhs.taskId.uuidString < rhs.taskId.uuidString
        }
    }

    /// A bare `tasks` row returned by an RPC, completed like a later `task(id:)` read (docs/CONTRACTS.md §4.1): the
    /// row's own fields (the state the call wrote), with the sorted assignees and checklist of a read made right after.
    /// The RPC result cannot embed them: PostgREST evaluates an embedding with the snapshot of the call's statement,
    /// which misses the rows the function wrote. A task gone right after the call (deleted, or no longer visible) keeps
    /// no assignee and no item.
    private func completed(_ row: TaskDTO) async throws -> TaskItem {
        do {
            let current = try await task(id: row.id)
            return row.item(assigneeIds: current.assigneeIds, checklist: current.checklist)
        } catch AppError.notFound {
            return row.item(assigneeIds: [], checklist: [])
        }
    }

    // MARK: - Checklist (docs/CONTRACTS-V2.md §5)

    /// The title is sent as typed (`ServerChecked`): the server checks it after the task and the caller's rights
    /// (`task_not_found` → `forbidden` → `invalid_item_title` → `too_many_items`), trims it, and adds the item at the
    /// end (position = the largest one + 1).
    func addChecklistItem(taskId: UUID, title: String) async throws -> ChecklistItem {
        let title = ServerChecked.title(title)
        let row = try await rest.fetch(ChecklistItemRow.self) { _ in
            RestQuery.rpc("add_checklist_item", ["p_task_id": .uuid(taskId), "p_title": .string(title)])
        }
        return row.item
    }

    /// The title is sent as typed, like `addChecklistItem(taskId:title:)` (`item_not_found` → `forbidden` →
    /// `invalid_item_title`).
    func renameChecklistItem(itemId: UUID, title: String) async throws -> ChecklistItem {
        let title = ServerChecked.title(title)
        let row = try await rest.fetch(ChecklistItemRow.self) { _ in
            RestQuery.rpc("rename_checklist_item", ["p_item_id": .uuid(itemId), "p_title": .string(title)])
        }
        return row.item
    }

    /// The same value is a no-op on the server, which returns the item unchanged.
    func setChecklistItemDone(itemId: UUID, done: Bool) async throws -> ChecklistItem {
        let row = try await rest.fetch(ChecklistItemRow.self) { _ in
            RestQuery.rpc("set_checklist_item_done", ["p_item_id": .uuid(itemId), "p_done": .bool(done)])
        }
        return row.item
    }

    func deleteChecklistItem(itemId: UUID) async throws {
        _ = try await rest.send { _ in RestQuery.rpc("delete_checklist_item", ["p_item_id": .uuid(itemId)]) }
    }

    // MARK: - Weekly recap (docs/CONTRACTS-V2.md §8)

    /// `since` is inclusive and sent with microseconds; ordered by completion, then task id. Non-members read an empty
    /// list (RLS).
    func completions(groupId: UUID, since: Date) async throws -> [TaskCompletion] {
        let rows = try await rest.fetch([CompletionRow].self) { _ in
            RestQuery.completions(groupId: groupId, since: since)
        }
        return rows.map(\.completion).sorted { lhs, rhs in
            if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
            return lhs.taskId.uuidString < rhs.taskId.uuidString
        }
    }
}

/// The fields of a draft, checked with `InputValidation` in the server's order (docs/CONTRACTS-V2.md §3): title →
/// details → due date → recurrence (shape, then the due date) → rotation (count, duplicates).
///
/// The rest is left to the server: the rotation's members, the assignees (count, then membership) and, for a new task,
/// the checklist (each title, then the count). The checklist comes after membership checks the client cannot make:
/// checking it here first could report another error than the server (TeamTasksCore v2 API note 3).
struct TaskFields: Sendable, Hashable {
    enum Operation: Sendable {
        case create
        case update
    }

    let title: String
    let details: String?
    let priority: TaskPriority
    let dueAt: Date?
    let assigneeIds: Set<UUID>
    let recurrence: RecurrenceRule?
    /// In turn order; empty = no rotation.
    let rotation: [UUID]
    /// `create_task` only: the titles as typed (the server trims and checks them).
    let checklist: [String]

    init(_ draft: TaskDraft, for operation: Operation) throws {
        title = try InputValidation.taskTitle(draft.title)
        details = try InputValidation.taskDetails(draft.details)
        dueAt = try InputValidation.dueDate(draft.dueAt)
        priority = draft.priority
        recurrence = try InputValidation.recurrence(draft.recurrence, dueAt: dueAt)
        switch operation {
        case .create:
            rotation = try InputValidation.rotation(draft.rotation, recurrence: recurrence)
            checklist = draft.checklist
        case .update:
            // The server takes the task's own rotation sent back as unchanged, without any check. With a rule, the
            // count and duplicate checks are safe here: that rotation always passes them. Without a rule (the edit
            // removes the rule, and any rotation with it), only the server can tell the task's own rotation (accepted)
            // from a new one (`invalid_rotation`).
            rotation = recurrence == nil
                ? draft.rotation
                : try InputValidation.rotation(draft.rotation, recurrence: recurrence)
            checklist = []
        }
        assigneeIds = draft.assigneeIds
    }

    /// Every `p_…` parameter of `create_task`, explicit `null`s and empty values included. The checklist titles are
    /// sent as typed (`ServerChecked`).
    func createParams(groupId: UUID) -> [String: JSONValue] {
        var params = commonParams
        params["p_group_id"] = .uuid(groupId)
        params["p_checklist"] = .array(checklist.map { .string(ServerChecked.title($0)) })
        return params
    }

    /// Every `p_…` parameter of `update_task` (no defaults for the v1 ones), explicit `null`s included.
    func updateParams(taskId: UUID) -> [String: JSONValue] {
        var params = commonParams
        params["p_task_id"] = .uuid(taskId)
        return params
    }

    /// The full state: `p_recurrence` `{}` = no rule, `p_rotation` `[]` (SQL `'{}'`) = no rotation. With a rotation the
    /// server ignores `p_assignee_ids`.
    private var commonParams: [String: JSONValue] {
        [
            "p_title": .string(title),
            "p_details": .optionalString(details),
            "p_priority": .string(priority.rawValue),
            "p_due_at": .timestamp(dueAt),
            "p_assignee_ids": .uuids(assigneeIds),
            "p_recurrence": .recurrence(recurrence),
            "p_rotation": .array(rotation.map(JSONValue.uuid)),
        ]
    }
}
