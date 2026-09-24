import Foundation
import Observation

/// « Groupes » tab root: the groups of the current user, most recently active first.
///
/// Reloads when the memberships revision changes (joined, left, removed, role changed, group created or
/// deleted) and when one of the listed groups has activity (renamed, reordered by `last_activity_at`).
/// View: `.task(id: model.refreshKey) { await model.load() }` and `.refreshable { await model.reload() }`.
@MainActor
@Observable
public final class GroupsListViewModel: ErrorPresenting {
    public static let emptyTitle = "Aucun groupe"
    public static let emptyMessage = "Créez un groupe ou rejoignez-en un avec un code d’invitation."

    public private(set) var groups: [GroupSummary] = []
    public private(set) var loadState: LoadState = .idle
    public var error: ErrorState?

    public let session: SessionModel
    private let runner = LoadRunner()
    private var loadedMemberships: Int?
    private var loadedGroupRevisions: [UUID: Int] = [:]
    /// Revisions read when the fetch in progress started.
    private var fetchingMemberships: Int?

    public init(session: SessionModel) {
        self.session = session
    }

    /// Loaded, and the user belongs to no group: show the empty state.
    public var isEmpty: Bool { loadState == .loaded && groups.isEmpty }

    public var refreshKey: RefreshKey {
        let feed = session.feed
        let revision = groups.reduce(feed.membershipsRevision) { $0 &+ feed.groupRevision($1.id) }
        return RefreshKey(revision: revision)
    }

    /// True when the content is older than the latest change signals.
    public var needsRefresh: Bool {
        let feed = session.feed
        guard loadState == .loaded, loadedMemberships == feed.membershipsRevision else { return true }
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

    private func fetch() async {
        let feed = session.feed
        let startMemberships = feed.membershipsRevision
        let startGroupRevisions = Dictionary(groups.map { ($0.id, feed.groupRevision($0.id)) }, uniquingKeysWith: { first, _ in first })
        fetchingMemberships = startMemberships
        defer { fetchingMemberships = nil }
        if loadState != .loaded { loadState = .loading }
        do {
            let result = try await session.services.groups.myGroups()
            groups = result
            loadedMemberships = startMemberships
            // Groups new to the list: their revision at the end of the fetch (their data is at least that recent).
            loadedGroupRevisions = Dictionary(
                result.map { ($0.id, startGroupRevisions[$0.id] ?? feed.groupRevision($0.id)) },
                uniquingKeysWith: { first, _ in first }
            )
            loadState = .loaded
        } catch {
            handleLoadFailure(error)
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
