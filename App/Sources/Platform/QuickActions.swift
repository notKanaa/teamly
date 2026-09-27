import Observation
import TeamTasksCore
import UIKit

/// The home-screen quick actions (a long press on the app icon), declared in Info.plist (`UIApplicationShortcutItems`,
/// project.yml): « Nouvelle tâche », « Mes tâches », « Rejoindre un groupe ».
enum QuickAction: String, CaseIterable, Sendable {
    case newTask
    case myTasks
    case joinGroup

    /// The action of a shortcut item (its `type`), nil for an unknown one.
    @MainActor
    init?(shortcutItem: UIApplicationShortcutItem) {
        self.init(rawValue: shortcutItem.type)
    }
}

/// Keeps the quick action the user chose until the signed-in tabs can perform it (`MainTabView`): at once when the app
/// runs signed in, otherwise once the session starts (after launch, or after signing in).
///
/// Fed by `AppDelegate` (a launch from a quick action) and `QuickActionSceneDelegate` (the app was already running).
@MainActor
@Observable
final class QuickActionCenter {
    static let shared = QuickActionCenter()

    /// The action waiting to be performed.
    private(set) var pending: QuickAction?

    private init() {}

    /// Keeps the action of `shortcutItem`. Returns false for an unknown item.
    @discardableResult
    func receive(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard let action = QuickAction(shortcutItem: shortcutItem) else { return false }
        pending = action
        return true
    }

    /// Takes the waiting action (it is performed once).
    func take() -> QuickAction? {
        defer { pending = nil }
        return pending
    }
}

/// The scene delegate of the SwiftUI window (set by `AppDelegate`): only the quick actions chosen while the app runs.
/// The window itself stays SwiftUI's.
@MainActor
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        QuickActionCenter.shared.receive(shortcutItem)
    }
}
