import Foundation

/// One event of a group's activity feed (`public.group_activity`, docs/CONTRACTS-V2.md §7), written by the server.
///
/// Names are resolved by the clients from the members list: an id outside it is a former member, and a nil
/// `actorId` / `subjectId` means no known person (a deleted account, or a server action such as `turnStarted`).
/// Titles are snapshots taken when the event was written.
///
/// Forward compatibility: a row whose `kind` is unknown to this client (`Kind(rawValue:)` is nil, a kind added by a
/// later version) is left out of the list, like the rows with an unknown enum value (docs/CONTRACTS.md §9).
public struct ActivityEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        /// A member created a task (`actorId`: the creator). Not written for the occurrences of a series.
        case taskCreated = "task_created"
        /// A task became done (`actorId`: who completed it).
        case taskCompleted = "task_completed"
        /// The turn of a rotating task goes to `subjectId` (`actorId` nil): at a spawn (`taskId`: the new occurrence,
        /// after the completion's `taskCompleted`), or at a handover when the turn holder left (`taskId`: the pending
        /// occurrence, after the `memberLeft`).
        case turnStarted = "turn_started"
        /// A checklist item became done (`actorId`: who checked it; `itemTitle`).
        case checklistItemDone = "checklist_item_done"
        /// Someone joined the group (`actorId` = `subjectId` = the new member).
        case memberJoined = "member_joined"
        /// Someone left or was removed (`actorId`: who did it; `subjectId`: the member; both nil for a deleted
        /// account).
        case memberLeft = "member_left"
    }

    /// Increasing with time: the feed is read newest first (`id` descending).
    public var id: Int64
    public var kind: Kind
    public var actorId: UUID?
    public var subjectId: UUID?
    /// The task concerned (it may have been deleted since).
    public var taskId: UUID?
    public var taskTitle: String?
    public var itemTitle: String?
    public var createdAt: Date

    public init(
        id: Int64,
        kind: Kind,
        actorId: UUID? = nil,
        subjectId: UUID? = nil,
        taskId: UUID? = nil,
        taskTitle: String? = nil,
        itemTitle: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.actorId = actorId
        self.subjectId = subjectId
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.itemTitle = itemTitle
        self.createdAt = createdAt
    }
}

/// A done task of a group, as read for the weekly recap (`TaskService.completions(groupId:since:)`,
/// docs/CONTRACTS-V2.md §8).
public struct TaskCompletion: Sendable, Hashable, Identifiable {
    public var taskId: UUID
    /// Who completed it; nil when unknown (a deleted account, a trusted context, a task completed before v2).
    public var completedBy: UUID?
    public var completedAt: Date

    public var id: UUID { taskId }

    public init(taskId: UUID, completedBy: UUID?, completedAt: Date) {
        self.taskId = taskId
        self.completedBy = completedBy
        self.completedAt = completedAt
    }
}
