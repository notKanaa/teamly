import Foundation
import Observation

/// The figures of the « Réglages » profile card (docs/CONTRACTS-V3.md §8): « tâches ce mois » and « semaines de
/// série » (`PersonalStats`). The number of groups comes from the groups list.
///
/// Until the v3 read `tasks?completed_by=eq.<me>&completed_at=gte.<since>` exists, the tasks come from
/// `TaskService.myTasks(doneSince: PersonalStats.readStart(…))` (the tasks assigned to the user) filtered on
/// `completedBy == me`: a task the user completed without being one of its assignees is not counted yet.
/// v3: switch the read of `fetch()` to the new service; `PersonalStats(completions:now:calendar:)` stays.
///
/// Reloads when « Mes tâches » may have changed (`ChangeFeed.myTasksRevision`: the user's own status changes, new
/// assignments, return to foreground). The figures are optional: a failed read keeps the previous ones (nil before
/// the first one) and shows no error.
/// View: `.task(id: model.refreshKey) { await model.load() }`.
@MainActor
@Observable
public final class PersonalStatsViewModel {
    /// nil until the first successful read.
    public private(set) var stats: PersonalStats?

    public let session: SessionModel
    private let runner = LoadRunner()
    private var loadedRevision: Int?

    public init(session: SessionModel) {
        self.session = session
    }

    public var refreshKey: RefreshKey { RefreshKey(revision: session.feed.myTasksRevision) }

    public var needsRefresh: Bool { stats == nil || loadedRevision != session.feed.myTasksRevision }

    /// Reads the figures when never read or out of date.
    public func load() async {
        guard needsRefresh else { return }
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetch() }
    }

    /// Always reads again (pull to refresh).
    public func reload() async {
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetch() }
    }

    private func fetch() async {
        let revision = session.feed.myTasksRevision
        let now = session.platform.now()
        let calendar = session.platform.calendar
        do {
            // v3: read the tasks completed by the user (docs/CONTRACTS-V3.md §8) instead.
            let tasks = try await session.services.tasks.myTasks(
                doneSince: PersonalStats.readStart(now: now, calendar: calendar)
            )
            stats = PersonalStats(tasks: tasks, userId: session.userId, now: now, calendar: calendar)
            loadedRevision = revision
        } catch {
            // Keep the figures already read; the next change signal reads again.
        }
    }
}
