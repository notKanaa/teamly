import XCTest

// Helpers of the v2 groups screens: the « + » menu of the groups list, the group hero (its title, its back button,
// its « … »), the « Tâches » / « Activité » switch and the « Apparence » sheet. Same rules as EquipeApp.swift: waits
// with deadlines, taps checked by their effect, queries by identifier or label (iOS 26 may keep the identifier of a
// menu item or a toolbar item on another copy).

extension UITestDemo {
    /// A group emoji of TeamTasksCore `EmojiChoices.groups`: 🎉 (the « Apparence » test and screenshot).
    static let partyEmoji = "\u{1F389}"
    /// A group emoji of TeamTasksCore `EmojiChoices.groups`: 📚 (the « Nouveau groupe » screenshot).
    static let booksEmoji = "\u{1F4DA}"
}

@MainActor
extension EquipeApp {
    /// « + » of the groups list: a menu with « Créer un groupe » and « Rejoindre un groupe ».
    var groupsAddMenu: XCUIElementQuery {
        buttons(AccessibilityID.Groups.addMenu, orLabel: "Créer ou rejoindre un groupe")
    }

    /// « + » → « Créer un groupe »: returns once the name field of « Nouveau groupe » shows.
    func openCreateGroupSheet(file: StaticString = #filePath, line: UInt = #line) {
        let create = buttons(AccessibilityID.Groups.createButton, orLabel: "Créer un groupe")
        tap(groupsAddMenu, "« + »", until: .shows(create), file: file, line: line)
        tap(
            create, "« Créer un groupe »",
            until: .shows(textFields(AccessibilityID.Groups.nameField)), file: file, line: line
        )
    }

    /// Waits for the group screen of `name` (the title of its hero; the navigation bar is hidden).
    func waitForGroupScreen(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        waitForText(
            name, of: elements(AccessibilityID.Groups.detailTitle), timeout: UITestTimeout.long,
            file: file, line: line
        )
    }

    /// Leaves the group screen with the back button of its hero, and checks that it is gone.
    func leaveGroupScreen(file: StaticString = #filePath, line: UInt = #line) {
        let title = elements(AccessibilityID.Groups.detailTitle)
        tap(
            buttons(AccessibilityID.Groups.backButton, orLabel: "Retour"), "« Retour »",
            until: .hides(title), file: file, line: line
        )
        waitForDisappearance(title, "the group screen", file: file, line: line)
    }

    /// Selects the « Tâches » (`tasks`) or « Activité » (`activity`) tab of the group screen.
    func showGroupTab(_ rawValue: String, file: StaticString = #filePath, line: UInt = #line) {
        select(buttons(AccessibilityID.Groups.tab(rawValue)), "the « \(rawValue) » tab", file: file, line: line)
    }

    /// « … » of the group hero → « Apparence » (admins): returns once the sheet's preview shows.
    func openGroupAppearance(file: StaticString = #filePath, line: UInt = #line) {
        let item = buttons(AccessibilityID.Groups.appearanceButton, orLabel: "Apparence")
        tap(
            buttons(AccessibilityID.Groups.detailMenu, orLabel: "Options du groupe"), "« … »",
            until: .shows(item), file: file, line: line
        )
        let preview = elements(AccessibilityID.Groups.appearancePreview)
        tap(item, "« Apparence »", until: .shows(preview), file: file, line: line)
        waitForContent(preview, "the appearance preview", file: file, line: line)
    }
}
