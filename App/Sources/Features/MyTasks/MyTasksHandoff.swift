import Foundation
import TeamTasksCore

/// The tasks « Mes tâches » showed last, handed to the task screen it opens.
///
/// A route only carries ids (`AppRoute.task(groupId:taskId:)`), and the task read of `TaskDetailViewModel` does not
/// return the group's name, color and emoji, which only `myTasks` reads. `MyTasksView` remembers its tasks here after
/// each load; `TaskDetailView` passes the one it opens as `TaskDetailViewModel(…, task:)`, which keeps the group's
/// badge (`groupAppearance`, the chip above the title) and shows the task at once, before its own read. Only the last
/// load of the current session is kept (a few dozen tasks at most).
@MainActor
enum MyTasksHandoff {
    private static var sessionId: UUID?
    private static var tasks: [UUID: TaskItem] = [:]

    /// Replaces the remembered tasks with those of a « Mes tâches » load of `session`.
    static func remember(_ loaded: [TaskItem], of session: SessionModel) {
        var byId: [UUID: TaskItem] = [:]
        for task in loaded where task.groupName != nil {
            byId[task.id] = task
        }
        sessionId = session.id
        tasks = byId
    }

    /// The task `taskId` of `groupId` as « Mes tâches » of `session` showed it; nil when it did not.
    static func task(_ taskId: UUID, in groupId: UUID, of session: SessionModel) -> TaskItem? {
        guard sessionId == session.id, let task = tasks[taskId], task.groupId == groupId else { return nil }
        return task
    }
}
