import Foundation
import Observation

/// Revision counters that view models observe to know when to reload (fed by `RealtimeCoordinator`,
/// and bumped locally after the user's own mutations).
///
/// Revisions only ever increase. A view model remembers the revision it loaded and reloads when the
/// observed value changes, e.g. `.onChange(of: feed.groupRevision(groupId)) { reload() }`.
@MainActor
@Observable
public final class ChangeFeed {
    /// Bumped when the current user's memberships change (group list, roles).
    public private(set) var membershipsRevision = 0
    /// Bumped when the tasks assigned to the current user may have changed ("Mes tâches", reminders).
    public private(set) var myTasksRevision = 0
    /// Bumped by `bumpAll()`; part of every group revision.
    public private(set) var allRevision = 0
    private var groupRevisions: [UUID: Int] = [:]

    public init() {}

    /// Revision of one group's content (tasks, assignees, members, name). Includes `allRevision`,
    /// so `bumpAll()` changes every group's revision, including groups never bumped before.
    public func groupRevision(_ groupId: UUID) -> Int {
        allRevision &+ groupRevisions[groupId, default: 0]
    }

    public func bump(groupId: UUID) {
        groupRevisions[groupId, default: 0] &+= 1
    }

    public func bumpMemberships() {
        membershipsRevision &+= 1
    }

    public func bumpMyTasks() {
        myTasksRevision &+= 1
    }

    /// Everything may have changed (realtime reconnection, return to foreground).
    public func bumpAll() {
        allRevision &+= 1
        membershipsRevision &+= 1
        myTasksRevision &+= 1
    }
}
