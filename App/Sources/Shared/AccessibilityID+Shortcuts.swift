// Accessibility identifiers of the shortcuts of the lists (v3): the actions revealed by swiping a card
// (`.cardSwipeActions`), the long-press menu of a group card, and their confirmations. Compiled into the app and the UI
// test target: plain strings only, no imports.
extension AccessibilityID {
    enum Shortcuts {
        // MARK: Groups list (by group name)

        /// Swipe right: « Épingler » / « Désépingler ».
        static func groupPin(_ name: String) -> String { "shortcuts.group.pin.\(name)" }
        /// Swipe left (members): « Quitter ».
        static func groupLeave(_ name: String) -> String { "shortcuts.group.leave.\(name)" }
        /// Swipe left (admins): « Supprimer ».
        static func groupDelete(_ name: String) -> String { "shortcuts.group.delete.\(name)" }
        /// The long-press menu of a group card.
        static let groupMenuOpen = "shortcuts.group.menu.open"
        static let groupMenuInvite = "shortcuts.group.menu.invite"
        static let groupMenuAppearance = "shortcuts.group.menu.appearance"
        static let groupMenuPin = "shortcuts.group.menu.pin"
        static let groupMenuLeave = "shortcuts.group.menu.leave"
        static let groupMenuDelete = "shortcuts.group.menu.delete"
        /// The buttons of the confirmation alerts: « Quitter », « Supprimer ».
        static let groupLeaveConfirm = "shortcuts.group.leaveConfirm"
        static let groupDeleteConfirm = "shortcuts.group.deleteConfirm"

        // MARK: Task cards of the group screen and « Mes tâches » (by task title)

        /// Swipe right: « Terminer », or « Rouvrir » on a done task.
        static func taskToggleDone(_ title: String) -> String { "shortcuts.task.done.\(title)" }
        /// Swipe left: « Supprimer ».
        static func taskDelete(_ title: String) -> String { "shortcuts.task.delete.\(title)" }
        /// Swipe left (« Mes tâches »): « Reporter » (the due date one day later).
        static func taskPostpone(_ title: String) -> String { "shortcuts.task.postpone.\(title)" }
        /// « Supprimer » of the confirmation of « Mes tâches » (the group screen has `Groups.deleteTaskConfirmButton`).
        static let taskDeleteConfirm = "shortcuts.task.deleteConfirm"
    }
}
