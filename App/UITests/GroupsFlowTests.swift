import XCTest

/// Flows of the v2 group screen on the in-memory backend: the admins' « Apparence » sheet, and the « Activité » tab.
final class GroupsFlowTests: XCTestCase {
    /// Camille (admin of « Coloc' rue des Lilas », 🏠 on coral) → « … » → « Apparence »: 🎉 on violet, « Enregistrer »;
    /// the sheet closes and the group's hero shows the new look.
    @MainActor
    func testAppearanceEditorChangesTheGroupLook() {
        let ui = EquipeApp.launch(.populated, for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        ui.waitForText("\u{1F3E0}, corail", of: ui.elements(AccessibilityID.Groups.detailTitle))

        ui.openGroupAppearance()
        ui.select(ui.buttons(AccessibilityID.Picker.emoji(UITestDemo.partyEmoji)), "the party emoji")
        ui.select(ui.buttons(AccessibilityID.Picker.color("violet")), "the violet swatch")
        let look = "\(UITestDemo.partyEmoji), violet"
        ui.waitForText(look, of: ui.elements(AccessibilityID.Groups.appearancePreview))

        let save = ui.buttons(AccessibilityID.Groups.appearanceSaveButton, orLabel: "Enregistrer")
        ui.tapWhenEnabled(save, "« Enregistrer »", until: .hides(save))
        ui.waitForDisappearance(save, "the « Apparence » sheet")
        ui.waitForText(look, of: ui.elements(AccessibilityID.Groups.detailTitle))
    }

    /// The status circle of a card tapped twice on the group screen, without leaving it (the second tap used to spin
    /// forever, the card showing « Terminée » only once the screen was left and opened again): « En cours », then
    /// « Terminée », each shown at once; afterwards no card of the task still reads « En cours ». The done card, under
    /// « Terminées », is captured under `debug/`.
    @MainActor
    func testStatusTappedTwiceOnTheGroupScreen() {
        let ui = EquipeApp.launch(.populated, for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)

        let title = UITestDemo.reparerFuite
        ui.waitForContent(ui.elements(labelContaining: title, "À faire"), "« \(title) » to do")
        ui.tapTaskStatus(title, until: "En cours")
        ui.tapTaskStatus(title, until: "Terminée")
        ui.assertNotShown(
            ui.elements(labelContaining: title, "En cours"), within: 2,
            "A card of « \(title) » still reads « En cours » after the second tap"
        )

        // Still on the group screen: the done card is there, under « Terminées ».
        ui.waitForGroupScreen(UITestDemo.lilasGroup)
        ui.reveal(ui.elements(AccessibilityID.Tasks.row(title)), "the done card of « \(title) »")
        ui.waitFor(ui.elements(labelContaining: title, "Terminée"), "« \(title) » done")
        ui.capture("groupe-tache-terminee")
    }

    /// `showcase`: « Activité » shows the week's recap with the podium (Inès 1re, on a 3-week streak) and the feed.
    @MainActor
    func testActivityTabShowsPodiumAndFeed() {
        let ui = EquipeApp.launch(.showcase, for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)

        ui.showGroupTab("activity")
        ui.waitForContent(ui.elements(AccessibilityID.Groups.activityPodium), "the podium")
        ui.waitFor(ui.elements(labelContaining: "Inès", "1re"), "Inès first on the podium")
        ui.waitFor(ui.elements(AccessibilityID.Groups.activityStreak), "the streak line")
        ui.reveal(ui.elements(labelContaining: "Inès a terminé"), "a task completed by Inès in the feed")

        // Back to the tasks (the switch is at the top, under the pinned hero): the floating « + » is there again.
        let tasksTab = ui.buttons(AccessibilityID.Groups.tab("tasks"))
        ui.scrollToTop(until: tasksTab)
        ui.showGroupTab("tasks")
        ui.waitForContent(ui.addTaskButton, "the « + » of the tasks")
    }
}
