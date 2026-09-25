import Foundation

/// v2: a group as the groups list shows it (docs/CONTRACTS-V2.md §10 « Groups overview »): its members and its task
/// counts, read for every group of the list at once with `GroupService.overviews(groupIds:doneSince:)`. The display
/// values (avatars, « 3 membres · 4 à faire », « 9 faites sur 13 ») are in `PresentationV2.swift`.
public struct GroupOverview: Sendable, Hashable, Identifiable {
    /// What an overview needs of one task of the group.
    public struct TaskState: Sendable, Hashable {
        public var status: TaskStatus
        /// Set when the task is done.
        public var completedAt: Date?

        public init(status: TaskStatus, completedAt: Date?) {
            self.status = status
            self.completedAt = completedAt
        }
    }

    public var groupId: UUID
    /// Every member with their avatar, admins first, then by display name (the order of
    /// `GroupService.members(groupId:)`, `NameOrder.sortedMembers`).
    public var members: [Membership]
    /// Tasks not done (« N à faire »).
    public var openTaskCount: Int
    /// Tasks done at or after the `doneSince` of the read (« X faites »).
    public var doneTaskCount: Int

    public var id: UUID { groupId }

    public init(groupId: UUID, members: [Membership], openTaskCount: Int, doneTaskCount: Int) {
        self.groupId = groupId
        self.members = members
        self.openTaskCount = openTaskCount
        self.doneTaskCount = doneTaskCount
    }

    /// The overview of one group from the rows the backends read, so that every backend sorts and counts alike:
    /// `members` in any order (sorted with `NameOrder.sortedMembers`), and the state of each task of the group. A task
    /// counts as open when it is not done, as done when it was completed at or after `doneSince`; an older done task
    /// does not count.
    public init(groupId: UUID, members: [Membership], tasks: [TaskState], doneSince: Date) {
        var open = 0
        var done = 0
        for task in tasks {
            if task.status != .done {
                open += 1
            } else if let completedAt = task.completedAt, completedAt >= doneSince {
                done += 1
            }
        }
        self.init(groupId: groupId, members: NameOrder.sortedMembers(members), openTaskCount: open, doneTaskCount: done)
    }
}
