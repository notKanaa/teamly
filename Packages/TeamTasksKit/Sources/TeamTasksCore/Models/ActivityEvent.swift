import Foundation

/// Every kind of activity event this client knows (docs/CONTRACTS-V2.md §7, docs/CONTRACTS-V3.md §7), v2 and v3.
///
/// `ActivityEvent.kind` has this type. The v2 kinds are also `ActivityEvent.Kind`, kept unchanged for the code written
/// for v2 (an exhaustive `switch` over it still compiles): `ActivityEvent.Kind(kind)` is nil for a v3 kind.
public enum ActivityKind: String, Sendable, Hashable, Codable, CaseIterable {
    case taskCreated = "task_created"
    case taskCompleted = "task_completed"
    case turnStarted = "turn_started"
    case checklistItemDone = "checklist_item_done"
    case memberJoined = "member_joined"
    case memberLeft = "member_left"
    // v3 (docs/CONTRACTS-V3.md §7)
    /// A member nudged an assignee (`actorId`: who nudged; `subjectId`: the assignee nudged). One event per assignee.
    case taskNudged = "task_nudged"
    /// A member announced an absence (`actorId` = `subjectId` = the member; `startsOn`, `endsOn`).
    case memberAway = "member_away"
    /// A member took someone's turn (`actorId`: who accepted and now holds the turn; `subjectId`: who proposed it).
    case turnSwapped = "turn_swapped"
    /// A member commented on a task (`actorId`: the author; `itemTitle`: the first 80 characters of the comment).
    case commentAdded = "comment_added"
    /// A member added a photo to a task (`actorId`: who added it).
    case photoAdded = "photo_added"

    /// The kinds added by v3 (the v2 screens leave them out).
    public var isV3: Bool { ActivityEvent.Kind(self) == nil }
}

/// One event of a group's activity feed (`public.group_activity`, docs/CONTRACTS-V2.md §7, docs/CONTRACTS-V3.md §4, §7),
/// written by the server.
///
/// Names are resolved by the clients from the members list: an id outside it is a former member, and a nil
/// `actorId` / `subjectId` means no known person (a deleted account, or a server action such as `turnStarted`).
/// Titles are snapshots taken when the event was written.
///
/// Forward compatibility: a row whose `kind` is unknown to this client (`ActivityKind(rawValue:)` is nil, a kind added
/// by a later version) is left out of the list, like the rows with an unknown enum value (docs/CONTRACTS.md §9).
public struct ActivityEvent: Sendable, Hashable, Identifiable {
    /// The v2 kinds (docs/CONTRACTS-V2.md §7), unchanged since v2 so that an exhaustive `switch` written for v2 still
    /// compiles. `ActivityEvent.kind` is an `ActivityKind`, which also has the v3 kinds.
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        /// A member created a task (`actorId`: the creator). Not written for the occurrences of a series.
        case taskCreated = "task_created"
        /// A task became done (`actorId`: who completed it).
        case taskCompleted = "task_completed"
        /// The turn of a rotating task goes to `subjectId` (`actorId` nil): at a spawn (`taskId`: the new occurrence,
        /// after the completion's `taskCompleted`), or at a handover when the turn holder left or went away (`taskId`:
        /// the pending occurrence).
        case turnStarted = "turn_started"
        /// A checklist item became done (`actorId`: who checked it; `itemTitle`).
        case checklistItemDone = "checklist_item_done"
        /// Someone joined the group (`actorId` = `subjectId` = the new member).
        case memberJoined = "member_joined"
        /// Someone left or was removed (`actorId`: who did it; `subjectId`: the member; both nil for a deleted
        /// account).
        case memberLeft = "member_left"

        /// The v2 kind of `kind`; nil for a kind added by v3.
        public init?(_ kind: ActivityKind) {
            self.init(rawValue: kind.rawValue)
        }

        /// The same kind as an `ActivityKind`.
        public var activityKind: ActivityKind {
            ActivityKind(rawValue: rawValue) ?? .taskCreated
        }
    }

    /// Increasing with time: the feed is read newest first (`id` descending).
    public var id: Int64
    public var kind: ActivityKind
    public var actorId: UUID?
    public var subjectId: UUID?
    /// The task concerned (it may have been deleted since).
    public var taskId: UUID?
    public var taskTitle: String?
    public var itemTitle: String?
    public var createdAt: Date
    /// v3: the « Bravo » reactions (`reactions:activity_reactions(user_id,emoji)`), in display order
    /// (`ActivityReaction.sorted(_:)`). Reactions with an emoji unknown to this client are left out.
    public var reactions: [ActivityReaction]
    /// v3, `memberAway` only: the first day of the absence (`starts_on`).
    public var startsOn: LocalDate?
    /// v3, `memberAway` only: the last day of the absence (`ends_on`).
    public var endsOn: LocalDate?

    public init(
        id: Int64,
        kind: ActivityKind,
        actorId: UUID? = nil,
        subjectId: UUID? = nil,
        taskId: UUID? = nil,
        taskTitle: String? = nil,
        itemTitle: String? = nil,
        createdAt: Date,
        reactions: [ActivityReaction] = [],
        startsOn: LocalDate? = nil,
        endsOn: LocalDate? = nil
    ) {
        self.id = id
        self.kind = kind
        self.actorId = actorId
        self.subjectId = subjectId
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.itemTitle = itemTitle
        self.createdAt = createdAt
        self.reactions = reactions
        self.startsOn = startsOn
        self.endsOn = endsOn
    }

    /// v3: the reactions grouped by emoji, in the order of `ReactionEmoji.allCases` (only the emojis used).
    public func reactionSummaries(currentUserId: UUID) -> [ReactionSummary] {
        ReactionSummary.summaries(of: reactions, currentUserId: currentUserId)
    }
}

/// A done task of a group, as read for the weekly recap (`TaskService.completions(groupId:since:)`,
/// docs/CONTRACTS-V2.md §8) and for the personal stats (`TaskService.myCompletions(since:)`, docs/CONTRACTS-V3.md §8).
public struct TaskCompletion: Sendable, Hashable, Identifiable {
    public var taskId: UUID
    /// Who completed it; nil when unknown (a deleted account, a trusted context, a task completed before v2).
    public var completedBy: UUID?
    public var completedAt: Date
    /// v3: the task's group, filled by `myCompletions(since:)` only (nil in the weekly recap read).
    public var groupId: UUID?

    public var id: UUID { taskId }

    public init(taskId: UUID, completedBy: UUID?, completedAt: Date, groupId: UUID? = nil) {
        self.taskId = taskId
        self.completedBy = completedBy
        self.completedAt = completedAt
        self.groupId = groupId
    }
}
