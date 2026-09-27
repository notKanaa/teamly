import XCTest

/// v3 « Réglages » on the in-memory backend (docs/CONTRACTS-V3.md §9): the theme, the quiet hours. They also take the
/// screenshots 21 and 22 of the CI artifact on their way (scripts/ci/export-screenshots.sh).
final class SettingsFlowTests: XCTestCase {
    /// Réglages → « Apparence » (screenshot 21): « Sombre » turns the app dark at once, « Clair » light, and « Auto »
    /// is selected back.
    @MainActor
    func testThemeSwitch() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", for: self)
        ui.openSettings()
        let themeTitle = ui.elements(AccessibilityID.Settings.themeTitle)
        ui.tap(ui.buttons(AccessibilityID.Settings.appearanceRow), "« Apparence »", until: .shows(themeTitle))
        let auto = ui.buttons(AccessibilityID.Settings.themeOption("auto"))
        ui.waitForContent(auto, "« Auto »")
        ui.waitForContent(ui.buttons(AccessibilityID.Settings.iconOption("checkedCard")), "the app icons")
        XCTAssertTrue(ui.waitUntilSelected(auto), "« Auto » is not the theme at first")
        ui.capture("21-reglages-apparence")

        ui.select(ui.buttons(AccessibilityID.Settings.themeOption("dark")), "« Sombre »")
        ui.waitForText("Sombre", of: themeTitle)
        ui.capture("reglages-apparence-sombre")

        ui.select(ui.buttons(AccessibilityID.Settings.themeOption("light")), "« Clair »")
        ui.waitForText("Clair", of: themeTitle)

        ui.select(auto, "« Auto »")
    }

    /// Réglages → « Heures calmes » (screenshot 22): on, 22:00 → 8:00 by default; « OK » closes the sheet and the tile
    /// shows the window.
    @MainActor
    func testQuietHoursSheet() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", for: self)
        ui.openSettings()
        let tile = ui.buttons(AccessibilityID.Settings.quietHoursTile)
        ui.waitForText("Désactivées", of: tile)

        let toggle = ui.app.switches.matching(identifier: AccessibilityID.Settings.quietHoursToggle)
        ui.tap(tile, "« Heures calmes »", until: .shows(toggle))
        let start = ui.elements(AccessibilityID.Settings.quietHoursStart)
        ui.turnOn(AccessibilityID.Settings.quietHoursToggle, "« Heures calmes »", until: start)
        ui.waitForContent(ui.elements(AccessibilityID.Settings.quietHoursEnd), "« Fin »")
        ui.capture("22-heures-calmes")

        let done = ui.buttons(AccessibilityID.Settings.quietHoursDone, orLabel: "OK")
        ui.tap(done, "« OK »", until: .hides(toggle))
        ui.waitForDisappearance(toggle, "the « Heures calmes » sheet")
        ui.waitForText("22:00\u{00A0}→ 8:00", of: tile)
    }
}

/// v3 shortcuts of the lists: swipe actions on the group cards and the task cards.
final class ShortcutsFlowTests: XCTestCase {
    /// Camille, a member of « Projet Asso Sport »: swipe left on its card → « Quitter » → the alert's « Quitter »; the
    /// group leaves the list, « Coloc' rue des Lilas » stays.
    @MainActor
    func testSwipeToLeaveAGroup() {
        let ui = EquipeApp.launch(.populated, for: self)
        ui.waitForDemoGroups()

        let group = UITestDemo.sportGroup
        let leave = ui.buttons(AccessibilityID.Shortcuts.groupLeave(group))
        ui.swipeCard(AccessibilityID.Groups.row(group), "the card of « \(group) »", towards: .left, until: leave)
        ui.tap(leave, "« Quitter »", until: .shows(ui.app.alerts))
        ui.waitForAlert(containing: "Quitter le groupe")
        ui.tapAlertButton("Quitter")

        ui.waitForDisappearance(ui.elements(AccessibilityID.Groups.row(group)), "the card of « \(group) »")
        ui.waitForContent(ui.elements(AccessibilityID.Groups.row(UITestDemo.lilasGroup)), "the other group")
    }

    /// « Mes tâches »: swipe right on « Sortir les poubelles » → « Terminer »; it joins today's done tasks, where it reads
    /// « Terminée ».
    @MainActor
    func testSwipeToCompleteATask() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", for: self)
        ui.openMyTasks()

        let title = UITestDemo.sortirPoubelles
        ui.waitForContent(ui.elements(AccessibilityID.Tasks.row(title)), "« \(title) »")
        let complete = ui.buttons(AccessibilityID.Shortcuts.taskToggleDone(title))
        ui.swipeCard(AccessibilityID.Tasks.row(title), "the card of « \(title) »", towards: .right, until: complete)
        let doneToday = ui.buttons(AccessibilityID.MyTasks.doneTodayButton)
        ui.tap(complete, "« Terminer »", until: .shows(doneToday))

        let done = ui.elements(labelContaining: title, "Terminée")
        ui.tap(doneToday, "« 1 tâche terminée aujourd’hui »", until: .shows(done))
        ui.waitForContent(done, "« \(title) » done")
    }
}
