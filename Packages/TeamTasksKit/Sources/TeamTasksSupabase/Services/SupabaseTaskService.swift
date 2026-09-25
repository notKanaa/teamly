import Foundation
import TeamTasksCore

/// `TaskService` on the task RPCs and PostgREST reads (docs/CONTRACTS.md §1, §3, §4).
struct SupabaseTaskService: TaskService {
    let context: SupabaseContext

    private var rest: RestClient { context.rest }

    /// Unless `includeOldDone`: `or=(status.neq.done,completed_at.gte.<now − 30 × 86 400 s>)`.
    /// Non-members read an empty list (RLS). Tasks with a status or priority unknown to this client (added by a
    /// later migration) are left out (`RestClient.fetchRows`).
    func tasks(groupId: UUID, includeOldDone: Bool) async throws -> [TaskItem] {
        let now = context.now()
        let rows = try await rest.fetchRows(TaskDTO.self) { _ in
            RestQuery.groupTasks(groupId: groupId, includeOldDone: includeOldDone, now: now)
        }
        return rows.map { $0.item() }.sorted(by: TaskDTO.creationOrder)
    }

    /// Tasks with a status or priority unknown to this client are left out, as in `tasks(groupId:includeOldDone:)`.
    func myTasks(includeDone: Bool) async throws -> [TaskItem] {
        let rows = try await rest.fetchRows(TaskDTO.self) { RestQuery.myTasks(me: $0.userId, includeDone: includeDone) }
        return rows.map(\.myTaskItem).sorted(by: TaskDTO.creationOrder)
    }

    /// 0 rows (unknown or not visible) → `.notFound`; an enum value unknown to this client → `.unknown`.
    func task(id: UUID) async throws -> TaskItem {
        let rows = try await rest.fetch([TaskDTO].self) { _ in RestQuery.task(id: id) }
        guard let row = rows.first else { throw AppError.notFound }
        return row.item()
    }

    /// `create_task` returns a bare `tasks` row; its assignees are exactly the (validated) draft's.
    func create(groupId: UUID, draft: TaskDraft) async throws -> TaskItem {
        let fields = try TaskFields(draft)
        let row = try await rest.fetch(TaskDTO.self) { _ in
            RestQuery.rpc("create_task", fields.params(adding: ["p_group_id": .uuid(groupId)]))
        }
        return row.item(assigneeIds: Array(draft.assigneeIds))
    }

    /// `update_task` (full edit, atomic) replaces the assignees by the draft's.
    func update(taskId: UUID, draft: TaskDraft) async throws -> TaskItem {
        let fields = try TaskFields(draft)
        let row = try await rest.fetch(TaskDTO.self) { _ in
            RestQuery.rpc("update_task", fields.params(adding: ["p_task_id": .uuid(taskId)]))
        }
        return row.item(assigneeIds: Array(draft.assigneeIds))
    }

    /// `set_task_status` returns a bare `tasks` row: the assignees come from a read of the task, so the result
    /// equals a later `task(id:)`.
    func setStatus(taskId: UUID, status: TaskStatus) async throws -> TaskItem {
        let row = try await rest.fetch(TaskDTO.self) { _ in
            RestQuery.rpc("set_task_status", ["p_task_id": .uuid(taskId), "p_status": .string(status.rawValue)])
        }
        let assignees: [UUID]
        do {
            assignees = try await task(id: taskId).assigneeIds
        } catch AppError.notFound {
            assignees = [] // deleted (or hidden) right after the change
        }
        return row.item(assigneeIds: assignees)
    }

    func delete(taskId: UUID) async throws {
        _ = try await rest.send { _ in RestQuery.rpc("delete_task", ["p_task_id": .uuid(taskId)]) }
    }

    /// Exclusive `since` sent with microseconds; oldest first (server order, then task id for equal instants).
    func assignments(since: Date) async throws -> [AssignmentEvent] {
        let rows = try await rest.fetch([AssignmentRow].self) { RestQuery.assignments(me: $0.userId, since: since) }
        return rows.compactMap(\.event).sorted { lhs, rhs in
            if lhs.assignedAt != rhs.assignedAt { return lhs.assignedAt < rhs.assignedAt }
            return lhs.taskId.uuidString < rhs.taskId.uuidString
        }
    }

    // TODO(v2-supabase): implement (docs/CONTRACTS-V2.md §5 add_checklist_item).
    func addChecklistItem(taskId: UUID, title: String) async throws -> ChecklistItem {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-supabase): implement (docs/CONTRACTS-V2.md §5 rename_checklist_item).
    func renameChecklistItem(itemId: UUID, title: String) async throws -> ChecklistItem {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-supabase): implement (docs/CONTRACTS-V2.md §5 set_checklist_item_done).
    func setChecklistItemDone(itemId: UUID, done: Bool) async throws -> ChecklistItem {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-supabase): implement (docs/CONTRACTS-V2.md §5 delete_checklist_item).
    func deleteChecklistItem(itemId: UUID) async throws {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-supabase): implement (docs/CONTRACTS-V2.md §8 recap read).
    func completions(groupId: UUID, since: Date) async throws -> [TaskCompletion] {
        throw AppError.unknown("pas encore disponible")
    }
}

/// The editable fields of a draft, validated with `InputValidation` in the server's order (title, details,
/// due date); the assignee rules are checked by the server.
struct TaskFields: Sendable, Hashable {
    let title: String
    let details: String?
    let priority: TaskPriority
    let dueAt: Date?
    let assigneeIds: Set<UUID>

    init(_ draft: TaskDraft) throws {
        title = try InputValidation.taskTitle(draft.title)
        details = try InputValidation.taskDetails(draft.details)
        dueAt = try InputValidation.dueDate(draft.dueAt)
        priority = draft.priority
        assigneeIds = draft.assigneeIds
    }

    /// Every `p_…` parameter, explicit `null`s included (`update_task` has no defaults).
    func params(adding extra: [String: JSONValue]) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "p_title": .string(title),
            "p_details": .optionalString(details),
            "p_priority": .string(priority.rawValue),
            "p_due_at": .timestamp(dueAt),
            "p_assignee_ids": .uuids(assigneeIds),
        ]
        params.merge(extra) { _, new in new }
        return params
    }
}
