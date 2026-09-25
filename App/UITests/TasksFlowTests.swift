import XCTest

/// v2 flows of the task screens on the in-memory backend (docs/DESIGN-V2.md §7.3, §7.6, §7.7). They also take the
/// screenshots 18 to 20 of the CI artifact on their way (scripts/ci/export-screenshots.sh).
final class TasksFlowTests: XCTestCase {
    /// Showcase, signed in as Camille: « Mes tâches » (screenshot 18), then « Faire les courses » and its half-done
    /// checklist (« 2 sur 4 », screenshot 19). Checking « Lessive » shows « 3 sur 4 » at once, and « Mes tâches » shows
    /// the new progress on the task's card.
    @MainActor
    func testCheckingAChecklistItemUpdatesTheProgress() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", for: self)
        ui.openMyTasks()
        ui.waitForContent(ui.elements(AccessibilityID.MyTasks.daySummary), "« Ta journée »")
        ui.waitForContent(ui.elements(AccessibilityID.Tasks.row(UITestDemo.sortirPoubelles)), "« Sortir les poubelles »")
        ui.waitForContent(ui.elements(AccessibilityID.Tasks.row(UITestDemo.faireCourses)), "« Faire les courses »")
        ui.capture("18-mes-taches-vitrine")

        ui.openTask(UITestDemo.faireCourses)
        let progress = ui.elements(AccessibilityID.Tasks.checklistProgress)
        ui.waitForText(UITestShowcase.progressBefore, of: progress)
        // The whole checklist card on screen (a list only builds its rows once they are near).
        ui.reveal(ui.elements(AccessibilityID.Tasks.checklistAddField), "« Ajouter un élément »")
        let item = ui.elements(AccessibilityID.Tasks.checklistItem(UITestShowcase.uncheckedItem))
        ui.waitForContent(item, "« \(UITestShowcase.uncheckedItem) »")
        ui.capture("19-tache-checklist")

        ui.tap(item, "« \(UITestShowcase.uncheckedItem) »", until: .selects(item))
        ui.waitForText(UITestShowcase.progressAfter, of: progress)

        // The card of « Mes tâches » reads « …, checklist 3 sur 4, … ».
        ui.goBack(from: UITestScreen.task)
        ui.waitFor(
            ui.elements(labelContaining: UITestDemo.faireCourses, UITestShowcase.progressAfter),
            "« \(UITestDemo.faireCourses) » with « \(UITestShowcase.progressAfter) » in « Mes tâches »"
        )
    }

    /// Camille (admin) creates « Arroser les plantes » in « Coloc' rue des Lilas »: every week, à tour de rôle, Inès
    /// moved first (screenshot 20). The group lists it, and its screen shows the repetition and the turn order.
    @MainActor
    func testCreatingAWeeklyTaskDoneInTurn() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)

        let titleField = ui.elements(AccessibilityID.Tasks.titleField)
        ui.tap(ui.addTaskButton, "« + »", until: .shows(titleField))
        let typedTitle = ui.typeText("Arroser les plantes", into: titleField, "the title field")
        // The title as it will be saved (the keyboard may correct a word once the field loses the focus).
        let title = ui.currentText(of: titleField) ?? typedTitle

        // « Semaine »: the due date turns on, the weekday circles show.
        let weekly = ui.buttons(AccessibilityID.Tasks.repeatOption("weekly"))
        ui.tap(weekly, "« Semaine »", until: .selects(weekly))
        ui.waitFor(ui.buttons(AccessibilityID.Tasks.weekday(1)), "the weekday circles")

        // « À tour de rôle »: every member, by name (Camille, Inès, Lucas); Inès moves first and starts.
        let ines = UITestDemo.inesName
        ui.turnOn(
            AccessibilityID.Tasks.rotationToggle, "« À tour de rôle »",
            until: ui.elements(AccessibilityID.Tasks.rotationMember(ines))
        )
        let inesStarts = ui.elements(AccessibilityID.Tasks.rotationMember(ines), value: "Position 1, Commence")
        ui.tap(ui.buttons(AccessibilityID.Tasks.rotationMoveUp(ines)), "« Monter » for Inès", until: .shows(inesStarts))
        ui.waitFor(
            ui.elements(AccessibilityID.Tasks.rotationMember(UITestDemo.camilleName), value: "Position 2"),
            "Camille second"
        )

        // The repetition and the rotation together, for the screenshot.
        ui.scrollToTop(until: titleField)
        ui.scroll(.towardsBottom)
        ui.waitForContent(ui.elements(AccessibilityID.Tasks.repeatHint), "the repetition's hint")
        ui.capture("20-nouvelle-tache-repetition")

        ui.tapWhenEnabled(
            ui.buttons(AccessibilityID.Tasks.saveButton), "« Créer » of the editor",
            until: .hides(ui.buttons(AccessibilityID.Tasks.cancelButton))
        )
        ui.waitForDisappearance(titleField, "the « Nouvelle tâche » sheet")

        // The group lists the task « à tour de rôle » (its title as saved: see FlowTests.testCreateTaskAssignedToMember);
        // its card reads « …, à tour de rôle, … » (Inès's turn, not Camille's « ton tour »).
        let firstWord = String(title.prefix { $0 != " " })
        let savedTitle = ui.taskTitle(startingWith: firstWord) ?? title
        ui.reveal(
            ui.elements(AccessibilityID.Tasks.row(savedTitle), labelContaining: "à tour de rôle"),
            "« \(savedTitle) » à tour de rôle in the group"
        )

        ui.openTask(savedTitle)
        ui.reveal(
            ui.elements(AccessibilityID.Tasks.recurrenceInfo, labelContaining: "Chaque semaine"),
            "« Se répète : Chaque semaine »"
        )
        ui.reveal(
            ui.elements(AccessibilityID.Tasks.rotationInfo, labelContaining: "Inès"),
            "« À tour de rôle », Inès first"
        )
        ui.reveal(ui.elements(labelContaining: ines), "Inès, the only assignee")
    }
}
