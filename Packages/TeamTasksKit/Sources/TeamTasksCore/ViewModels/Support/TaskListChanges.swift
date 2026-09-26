import Foundation

extension TaskItem {
    /// The task as `set_task_status` leaves it (docs/CONTRACTS.md §4.1, docs/CONTRACTS-V2.md §5): what a list shows
    /// before the server answers. `completedAt` and `completedBy` are set when the task becomes done (kept when it
    /// already was) and cleared otherwise; `updatedAt` only moves when the status changes.
    public func settingStatus(_ status: TaskStatus, by userId: UUID, at date: Date) -> TaskItem {
        var task = self
        if status == .done {
            if self.status != .done {
                task.completedAt = date
                task.completedBy = userId
            }
        } else {
            task.completedAt = nil
            task.completedBy = nil
        }
        if status != self.status {
            task.updatedAt = date
        }
        task.status = status
        return task
    }
}

/// The local changes of a task list (the group screen, « Mes tâches »): the status changes shown at once and saved in
/// the background, and the writes that a fetch which read the server before them must not undo.
///
/// - A status change shows at once. Asked while the same task is being saved, it is shown too and sent right after
///   that save (the last one asked wins): two quick taps on the status give « En cours », then « Terminée ».
/// - `merge(_:local:since:)`: a fetch that started before a local write (or during a save) keeps the local version of
///   that task. Every write bumps the feed, so the reload that follows reads the saved state.
@MainActor
final class TaskListChanges {
    /// Tasks whose status is being saved.
    private(set) var savingIds: Set<UUID> = []
    /// The status asked for a task while it was being saved: sent once that save is over.
    private var queuedStatus: [UUID: TaskStatus] = [:]
    /// Order of the local writes, and the last write of each task.
    private var writeCount = 0
    private var lastWrite: [UUID: Int] = [:]

    /// Take it when a fetch starts, and give it back to `merge(_:local:since:)`.
    var mark: Int { writeCount }

    /// A local write of the task: a status shown, saved or put back, a task saved by another screen, a deletion.
    func record(_ taskId: UUID) {
        writeCount &+= 1
        lastWrite[taskId] = writeCount
    }

    /// Starts saving `status`. False when the task is already being saved: `status` is then sent after that save.
    func beginStatus(_ status: TaskStatus, for taskId: UUID) -> Bool {
        record(taskId)
        guard !savingIds.contains(taskId) else {
            queuedStatus[taskId] = status
            return false
        }
        savingIds.insert(taskId)
        return true
    }

    /// The status asked while the last one was being saved, if any: the save goes on with it.
    func nextStatus(for taskId: UUID) -> TaskStatus? {
        queuedStatus.removeValue(forKey: taskId)
    }

    /// The save of the task is over (saved, put back, or the task is gone).
    func endStatus(for taskId: UUID) {
        savingIds.remove(taskId)
        queuedStatus[taskId] = nil
        record(taskId)
    }

    /// `fetched`, where every task written locally after `mark`, or being saved, keeps its version of `local`: added
    /// when the fetch missed it, left out when it is no longer in `local` (deleted here). Forgets the writes the fetch
    /// has seen.
    func merge(_ fetched: [TaskItem], local: [TaskItem], since mark: Int) -> [TaskItem] {
        lastWrite = lastWrite.filter { $0.value > mark }
        let kept = Set(lastWrite.keys).union(savingIds)
        guard !kept.isEmpty else { return fetched }
        var localTasks: [UUID: TaskItem] = [:]
        for task in local where kept.contains(task.id) && localTasks[task.id] == nil {
            localTasks[task.id] = task
        }
        var merged: [TaskItem] = []
        var seen = Set<UUID>()
        for task in fetched where seen.insert(task.id).inserted {
            if kept.contains(task.id) {
                if let localTask = localTasks[task.id] {
                    merged.append(localTask)
                }
            } else {
                merged.append(task)
            }
        }
        for task in local where localTasks[task.id] != nil && seen.insert(task.id).inserted {
            merged.append(task)
        }
        return merged
    }
}
