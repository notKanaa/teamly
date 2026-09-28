import Foundation
import Observation

/// The figures of the « Réglages » profile card (docs/CONTRACTS-V3.md §8): « tâches ce mois » and « semaines de
/// série » (`PersonalStats`). The number of groups comes from the groups list.
///
/// The tasks are read with `TaskService.myCompletions(since: PersonalStats.readStart(…))`
/// (`tasks?completed_by=eq.<me>&completed_at=gte.<since>`): every task the user completed, assigned to them or not.
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
            let completions = try await session.services.tasks.myCompletions(
                since: PersonalStats.readStart(now: now, calendar: calendar)
            )
            stats = PersonalStats(completions: completions.map { $0.completedAt }, now: now, calendar: calendar)
            loadedRevision = revision
        } catch {
            // Keep the figures already read; the next change signal reads again.
        }
    }
}
