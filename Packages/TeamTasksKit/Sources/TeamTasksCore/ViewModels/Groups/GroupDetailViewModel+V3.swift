import Foundation

// v3 of the group screen (docs/CONTRACTS-V3.md §1): « Relancer » from the card of an overdue task. The turns proposed to
// the user are `swapRequests`; the away badges of « À qui le tour ? » are in `turnCards`.
extension GroupDetailViewModel {
    /// « Relancer » on a card: any member, on an overdue task that has someone else assigned.
    public func canNudge(_ task: TaskItem) -> Bool {
        task.isOverdue(at: referenceDate) && TaskPermissions.canNudge(task, userId: session.userId, role: myRole)
    }

    /// The assignees a nudge of `task` reaches, the user excepted.
    public func nudgeRecipients(of task: TaskItem) -> [PersonBadge] {
        directory.badges(of: task.assigneeIds).filter { !$0.isMe }
    }

    /// « Relancer Inès ».
    public func nudgeTitle(for task: TaskItem) -> String {
        NudgeText.buttonTitle(names: nudgeRecipients(of: task).map(\.shortName))
    }

    /// Nudges the assignees of `task`: `toast` « Relance envoyée à Inès »; `error` says why not (« Tu as déjà relancé
    /// cette tâche aujourd’hui. »).
    @discardableResult
    public func nudge(_ task: TaskItem) async -> Bool {
        guard TaskPermissions.canNudge(task, userId: session.userId, role: myRole) else {
            present(AppError.forbidden)
            return false
        }
        guard !nudgingTaskIds.contains(task.id) else { return false }
        error = nil
        nudgingTaskIds.insert(task.id)
        defer { nudgingTaskIds.remove(task.id) }
        let names = nudgeRecipients(of: task).map(\.shortName)
        do {
            let count = try await session.services.tasks.nudge(taskId: task.id)
            toast = ToastNotice(NudgeText.sentMessage(names: names, count: count), systemImage: "bell.badge.fill")
            // The feed of the group has the nudge.
            session.feed.bump(groupId: groupId)
            return true
        } catch {
            switch present(error) {
            case .notFound?, .taskDone?, .nudgeNoRecipient?:
                // The task changed meanwhile: the reload shows it as it is.
                session.feed.bump(groupId: groupId)
            default:
                break
            }
            return false
        }
    }
}
