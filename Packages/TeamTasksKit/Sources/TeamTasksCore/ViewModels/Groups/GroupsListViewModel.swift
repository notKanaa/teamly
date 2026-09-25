import Foundation
import Observation

/// « Groupes » tab root: the groups of the current user, most recently active first, and (v2) the figures of their
/// cards: the members, the tasks to do and the week's progress (`overview(of:)`), and the header's summary
/// (`headerText`).
///
/// Reloads when the memberships revision changes (joined, left, removed, role changed, group created or
/// deleted) and when one of the listed groups has activity (renamed, reordered by `last_activity_at`; any task,
/// assignee or member change, v2: an avatar change). Every load reads the groups, then their overviews in one call
/// (`GroupService.overviews(groupIds:doneSince:)` from Monday 00:00 of the current week in the injected calendar,
/// `WeeklyRecap.weekStart`), and shows both at once. A failed overview read never fails the list: the groups are
/// shown with the figures already read this week (else without figures), and the next `load()` reads everything
/// again, as it does once the week has changed.
/// View: `.task(id: model.refreshKey) { await model.load() }` and `.refreshable { await model.reload() }`.
@MainActor
@Observable
public final class GroupsListViewModel: ErrorPresenting {
    public static let emptyTitle = "Aucun groupe"
    public static let emptyMessage = "Crée un groupe ou rejoins-en un avec un code d’invitation."

    public private(set) var groups: [GroupSummary] = []
    /// v2: the figures of the listed groups' cards, by group id (see `overview(of:)`).
    public private(set) var overviews: [UUID: GroupOverview] = [:]
    /// v2: Monday 00:00 of the week whose done tasks the overviews count; nil before the first load.
    public private(set) var overviewsWeekStart: Date?
    public private(set) var loadState: LoadState = .idle
    public var error: ErrorState?

    public let session: SessionModel
    private let runner = LoadRunner()
    private var loadedMemberships: Int?
    private var loadedGroupRevisions: [UUID: Int] = [:]
    /// The last overview read failed: the next `load()` reads again.
    private var overviewsAreStale = false
    /// Revisions read when the fetch in progress started.
    private var fetchingMemberships: Int?

    public init(session: SessionModel) {
        self.session = session
    }

    /// Loaded, and the user belongs to no group: show the empty state.
    public var isEmpty: Bool { loadState == .loaded && groups.isEmpty }

    /// v2: the figures of a listed group's card: members and avatars, « 4 à faire », « 9 faites sur 13 »
    /// (`PresentationV2.swift`). nil before they are read, after a failed read, and for a group whose rows are too many
    /// for one page of the server (docs/CONTRACTS-V2.md §10): the card then shows the group without figures.
    public func overview(of groupId: UUID) -> GroupOverview? {
        overviews[groupId]
    }

    /// v2: the header's summary: « 3 groupes · 11 tâches à faire », « 1 groupe · aucune tâche à faire »; only
    /// « 3 groupes » while a listed group has no overview; nil without groups.
    public var headerText: String? {
        guard !groups.isEmpty else { return nil }
        let groupsText = FrenchText.count(groups.count, "groupe", "groupes")
        let counts = groups.compactMap { overviews[$0.id]?.openTaskCount }
        guard counts.count == groups.count else { return groupsText }
        let open = counts.reduce(0, +)
        let openText = open == 0 ? "aucune tâche à faire" : "\(FrenchText.count(open, "tâche", "tâches")) à faire"
        return "\(groupsText) · \(openText)"
    }

    public var refreshKey: RefreshKey {
        let feed = session.feed
        let revision = groups.reduce(feed.membershipsRevision) { $0 &+ feed.groupRevision($1.id) }
        return RefreshKey(revision: revision)
    }

    /// True when the content is older than the latest change signals, when the last overview read failed, and once the
    /// week of the overviews is over.
    public var needsRefresh: Bool {
        let feed = session.feed
        guard loadState == .loaded, loadedMemberships == feed.membershipsRevision, !overviewsAreStale,
              overviewsWeekStart == currentWeekStart
        else { return true }
        return groups.contains { feed.groupRevision($0.id) != loadedGroupRevisions[$0.id] }
    }

    /// Loads if never loaded or out of date; otherwise returns immediately. Safe to call repeatedly.
    public func load() async {
        guard needsRefresh else { return }
        let upToDate = runner.isRunning && fetchingMemberships == session.feed.membershipsRevision
        await runner.run(rerunIfRunning: !upToDate) { [weak self] in await self?.fetch() }
    }

    /// Always fetches again (pull to refresh, « Réessayer »).
    public func reload() async {
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetch() }
    }

    /// Monday 00:00 of the current week, in the injected calendar.
    private var currentWeekStart: Date {
        WeeklyRecap.weekStart(of: session.platform.now(), calendar: session.platform.calendar)
    }

    private func fetch() async {
        let feed = session.feed
        let startMemberships = feed.membershipsRevision
        let startGroupRevisions = Dictionary(groups.map { ($0.id, feed.groupRevision($0.id)) }, uniquingKeysWith: { first, _ in first })
        fetchingMemberships = startMemberships
        defer { fetchingMemberships = nil }
        if loadState != .loaded { loadState = .loading }
        let result: [GroupSummary]
        do {
            result = try await session.services.groups.myGroups()
        } catch {
            handleLoadFailure(error)
            return
        }
        let weekStart = currentWeekStart
        let read = await readOverviews(of: result, weekStart: weekStart)
        groups = result
        loadedMemberships = startMemberships
        // Groups new to the list: their revision at the end of the fetch (their data is at least that recent).
        loadedGroupRevisions = Dictionary(
            result.map { ($0.id, startGroupRevisions[$0.id] ?? feed.groupRevision($0.id)) },
            uniquingKeysWith: { first, _ in first }
        )
        if let read {
            overviews = read
            overviewsAreStale = false
        } else {
            // Keep the figures already read this week for the groups still listed.
            let listed = Set(result.map(\.id))
            overviews = overviewsWeekStart == weekStart ? overviews.filter { listed.contains($0.key) } : [:]
            overviewsAreStale = true
        }
        overviewsWeekStart = weekStart
        loadState = .loaded
    }

    /// The overviews of `groups` by group id, nil when the read failed; nothing is read without groups.
    private func readOverviews(of groups: [GroupSummary], weekStart: Date) async -> [UUID: GroupOverview]? {
        guard !groups.isEmpty else { return [:] }
        do {
            let read = try await session.services.groups.overviews(groupIds: groups.map(\.id), doneSince: weekStart)
            return Dictionary(read.map { ($0.groupId, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            return nil
        }
    }

    private func handleLoadFailure(_ error: any Error) {
        guard let state = ErrorState(from: error) else {
            if loadState == .loading { loadState = .idle }
            return
        }
        if loadState == .loaded {
            self.error = state
        } else {
            loadState = .failed(state.message)
        }
    }
}
