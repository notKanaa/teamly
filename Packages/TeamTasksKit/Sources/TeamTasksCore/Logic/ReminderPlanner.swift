import Foundation

/// Computes the due-date reminders that should be pending (docs/CONTRACTS.md §7). Pure: no side effects.
///
/// Rules: only tasks assigned to `userId`, not done, with a due date; the reminder fires at
/// `dueAt - leadTime` and is kept only if that date is strictly after `now`; at most `maxPending`
/// reminders (iOS keeps 64 pending requests per app), the soonest first.
/// Apply the result with `ReminderReconciler`.
public struct ReminderPlanner: Sendable, Hashable {
    /// Identifier prefix of every reminder.
    public static let identifierPrefix = "due-"
    /// Default cap on pending reminders (leaves room below the iOS limit of 64 for other notifications).
    public static let defaultMaxPending = 60
    /// Title of every reminder.
    public static let title = "Échéance proche"

    public var maxPending: Int
    /// Time zone of the French wording in the body (and calendar for "1 jour avant").
    public var calendar: Calendar

    public init(calendar: Calendar, maxPending: Int = ReminderPlanner.defaultMaxPending) {
        self.calendar = calendar
        self.maxPending = max(0, maxPending)
    }

    /// `due-<taskId>-<dueEpochSeconds>`: the id changes when the due date changes, so the reconciler
    /// replaces the reminder.
    public static func identifier(taskId: UUID, dueAt: Date) -> String {
        "\(identifierPrefix)\(taskId.uuidString)-\(epochSeconds(dueAt))"
    }

    /// Whole seconds since 1970 (rounded down).
    public static func epochSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    /// The desired reminders, sorted by fire date (then id), at most `maxPending`.
    /// - Parameters:
    ///   - tasks: typically `TaskService.myTasks(includeDone: false)`; other tasks are ignored.
    ///   - groupNames: fallback group names when `TaskItem.groupName` is nil or empty.
    public func plan(
        tasks: [TaskItem],
        userId: UUID,
        leadTime: ReminderLeadTime,
        now: Date,
        groupNames: [UUID: String] = [:]
    ) -> [LocalNotification] {
        guard leadTime.isEnabled, maxPending > 0 else { return [] }
        let formatter = FrenchDateFormatter(timeZone: calendar.timeZone)
        var seenTaskIds = Set<UUID>()
        var reminders: [(fireDate: Date, notification: LocalNotification)] = []

        for task in tasks {
            guard task.status != .done,
                  let dueAt = task.dueAt,
                  task.isAssigned(to: userId),
                  seenTaskIds.insert(task.id).inserted,
                  let fireDate = leadTime.fireDate(forDueAt: dueAt, calendar: calendar),
                  fireDate > now
            else { continue }

            let when = formatter.relativeDateTime(dueAt, relativeTo: fireDate)
            let body: String
            if let groupName = [task.groupName, groupNames[task.groupId]].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                body = "\(task.title) — \(groupName), \(when)"
            } else {
                body = "\(task.title), \(when)"
            }
            let notification = LocalNotification(
                id: Self.identifier(taskId: task.id, dueAt: dueAt),
                title: Self.title,
                body: body,
                fireDate: fireDate,
                userInfo: ["taskId": task.id.uuidString, "groupId": task.groupId.uuidString],
                threadId: task.groupId.uuidString
            )
            reminders.append((fireDate, notification))
        }

        reminders.sort { lhs, rhs in
            lhs.fireDate != rhs.fireDate ? lhs.fireDate < rhs.fireDate : lhs.notification.id < rhs.notification.id
        }
        return reminders.prefix(maxPending).map { $0.notification }
    }
}
