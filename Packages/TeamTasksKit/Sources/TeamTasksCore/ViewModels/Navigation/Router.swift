import Foundation
import Observation

/// Tabs of the signed-in app.
public enum AppTab: String, Sendable, Hashable, CaseIterable, Identifiable {
    case groups
    case myTasks
    case settings

    public var id: String { rawValue }

    /// Tab title (French).
    public var title: String {
        switch self {
        case .groups: "Groupes"
        case .myTasks: "Mes tâches"
        case .settings: "Réglages"
        }
    }

    /// SF Symbols name of the tab icon.
    public var systemImage: String {
        switch self {
        case .groups: "person.3"
        case .myTasks: "checklist"
        case .settings: "gearshape"
        }
    }
}

/// Destinations pushed on a tab's `NavigationStack(path:)`. Only ids: every screen loads its own data.
public enum AppRoute: Sendable, Hashable {
    case group(UUID)
    case task(groupId: UUID, taskId: UUID)
    case members(groupId: UUID)

    /// The group this destination belongs to.
    public var groupId: UUID {
        switch self {
        case let .group(groupId): groupId
        case let .task(groupId, _): groupId
        case let .members(groupId): groupId
        }
    }
}

/// An external request to show something: `equipe://task/<groupId>/<taskId>` links (ntfy `Click` header) and
/// taps on local notifications (docs/CONTRACTS.md §7).
public enum DeepLink: Sendable, Hashable {
    case task(groupId: UUID, taskId: UUID)
    case group(UUID)
    /// « Mes tâches » (e.g. a grouped notification about several groups).
    case myTasks

    public static let scheme = "equipe"

    /// Parses `equipe://task/<groupId>/<taskId>` (also `equipe://group/<groupId>` and `equipe://mytasks`).
    /// Scheme and host are case-insensitive; a trailing slash is accepted. Returns nil for anything else.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == DeepLink.scheme,
              let host = components.host?.lowercased()
        else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch host {
        case "task":
            guard parts.count == 2, let groupId = UUID(uuidString: parts[0]), let taskId = UUID(uuidString: parts[1]) else {
                return nil
            }
            self = .task(groupId: groupId, taskId: taskId)
        case "group":
            guard parts.count == 1, let groupId = UUID(uuidString: parts[0]) else { return nil }
            self = .group(groupId)
        case "mytasks":
            guard parts.isEmpty else { return nil }
            self = .myTasks
        default:
            return nil
        }
    }

    /// Routing of a tapped local notification from its `userInfo` (`taskId`, `groupId` as UUID strings):
    /// both → the task; only `groupId` (grouped summary of one group) → the group; otherwise « Mes tâches ».
    /// Nonisolated: parse in the notification delegate, then hand the (Sendable) link to the main actor.
    public init(notificationUserInfo userInfo: [AnyHashable: Any]) {
        let groupId = (userInfo["groupId"] as? String).flatMap(UUID.init(uuidString:))
        let taskId = (userInfo["taskId"] as? String).flatMap(UUID.init(uuidString:))
        switch (groupId, taskId) {
        case let (groupId?, taskId?): self = .task(groupId: groupId, taskId: taskId)
        case let (groupId?, nil): self = .group(groupId)
        default: self = .myTasks
        }
    }

    /// The `equipe://` URL of this link.
    public var url: URL {
        let path: String
        switch self {
        case let .task(groupId, taskId): path = "task/\(groupId.uuidString)/\(taskId.uuidString)"
        case let .group(groupId): path = "group/\(groupId.uuidString)"
        case .myTasks: path = "mytasks"
        }
        // Only UUIDs and fixed words: always a valid URL.
        return URL(string: "\(DeepLink.scheme)://\(path)") ?? URL(fileURLWithPath: "/")
    }
}

/// Navigation state of the signed-in app: selected tab and the `NavigationStack` paths of the « Groupes » and
/// « Mes tâches » tabs.
///
/// Deep links received while no session is active (launch from a notification, signed out) are kept in
/// `pendingDeepLink` and applied by `activate()` when a session starts (`AppModel` does it).
///
/// Views: `TabView(selection: $router.selectedTab)`, `NavigationStack(path: $router.groupsPath)` with
/// `.navigationDestination(for: AppRoute.self)`, `NavigationLink(value: AppRoute.task(groupId:taskId:))`.
@MainActor
@Observable
public final class Router {
    public var selectedTab: AppTab = .groups
    /// Path of the « Groupes » tab: group detail, task detail, members.
    public var groupsPath: [AppRoute] = []
    /// Path of the « Mes tâches » tab (task details).
    public var myTasksPath: [AppRoute] = []
    /// A deep link waiting for a session.
    public private(set) var pendingDeepLink: DeepLink?
    /// True while a session is active (deep links are applied immediately).
    public private(set) var isActive = false

    public init() {}

    // MARK: - Deep links

    /// Shows `link` now if a session is active, otherwise keeps it for `activate()`.
    public func open(_ link: DeepLink) {
        guard isActive else {
            pendingDeepLink = link
            return
        }
        apply(link)
    }

    /// Opens an `equipe://` URL. Returns false (and does nothing) when the URL is not one of ours.
    @discardableResult
    public func open(url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        open(link)
        return true
    }

    /// Opens the destination of a tapped notification (see `DeepLink.init(notificationUserInfo:)`).
    public func openNotification(userInfo: [String: String]) {
        open(DeepLink(notificationUserInfo: userInfo))
    }

    // MARK: - Navigation helpers

    /// « Groupes » tab, showing the group.
    public func showGroup(_ groupId: UUID) {
        selectedTab = .groups
        groupsPath = [.group(groupId)]
    }

    /// « Groupes » tab, showing the task above its group (so « retour » goes to the group).
    public func showTask(groupId: UUID, taskId: UUID) {
        selectedTab = .groups
        groupsPath = [.group(groupId), .task(groupId: groupId, taskId: taskId)]
    }

    /// « Groupes » tab, showing the members above their group.
    public func showMembers(groupId: UUID) {
        selectedTab = .groups
        groupsPath = [.group(groupId), .members(groupId: groupId)]
    }

    /// « Mes tâches » tab, at its root.
    public func showMyTasks() {
        selectedTab = .myTasks
        myTasksPath = []
    }

    /// Pops the given tab (the selected one by default) to its root.
    public func popToRoot(of tab: AppTab? = nil) {
        switch tab ?? selectedTab {
        case .groups: groupsPath = []
        case .myTasks: myTasksPath = []
        case .settings: break
        }
    }

    /// Removes every destination of a group that no longer exists or was left (and what is above it).
    public func removeRoutes(forGroup groupId: UUID) {
        if let index = groupsPath.firstIndex(where: { $0.groupId == groupId }) {
            groupsPath.removeSubrange(index...)
        }
        if let index = myTasksPath.firstIndex(where: { $0.groupId == groupId }) {
            myTasksPath.removeSubrange(index...)
        }
    }

    /// Removes a deleted task's screen (and what is above it).
    public func removeRoutes(forTask taskId: UUID) {
        let isTask: (AppRoute) -> Bool = { route in
            if case let .task(_, id) = route { return id == taskId }
            return false
        }
        if let index = groupsPath.firstIndex(where: isTask) {
            groupsPath.removeSubrange(index...)
        }
        if let index = myTasksPath.firstIndex(where: isTask) {
            myTasksPath.removeSubrange(index...)
        }
    }

    // MARK: - Session lifecycle (called by AppModel)

    /// A session started: applies the pending deep link, if any.
    public func activate() {
        isActive = true
        if let link = pendingDeepLink {
            pendingDeepLink = nil
            apply(link)
        }
    }

    /// The session ended: back to the first tab with empty paths. A deep link received afterwards waits for
    /// the next session.
    public func deactivate() {
        isActive = false
        reset()
    }

    /// First tab, empty paths (the pending deep link is kept).
    public func reset() {
        selectedTab = .groups
        groupsPath = []
        myTasksPath = []
    }

    private func apply(_ link: DeepLink) {
        switch link {
        case let .task(groupId, taskId): showTask(groupId: groupId, taskId: taskId)
        case let .group(groupId): showGroup(groupId)
        case .myTasks: showMyTasks()
        }
    }
}
