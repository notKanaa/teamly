import XCTest

/// Screenshots and design checks of the v2 task screens (docs/DESIGN-V2.md §7.3, §7.6, §7.7): « Mes tâches » in dark
/// mode (07-mes-taches-sombre, one of the CI captures), then the parts of the task screens that change the most at the
/// largest accessibility text size, captured under `debug/` to be looked at. The light captures 18 to 20 are taken by
/// `TasksFlowTests`.
final class TasksScreenshotTests: XCTestCase {
    /// 07-mes-taches in dark mode: the same demo data as ScreenshotTests.test07MyTasks.
    @MainActor
    func test07MyTasksDark() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", appearance: .dark, for: self)
        ui.openMyTasks()
        ui.waitForContent(ui.elements(AccessibilityID.MyTasks.daySummary), "« Ta journée »")
        ui.waitForContent(ui.elements(AccessibilityID.Tasks.row(UITestDemo.faireCourses)), "« \(UITestDemo.faireCourses) »")
        ui.waitForContent(
            ui.elements(AccessibilityID.Tasks.row(UITestDemo.reserverGymnase)), "« \(UITestDemo.reserverGymnase) »"
        )
        ui.capture("07-mes-taches-sombre")
    }

    /// Showcase at the largest accessibility text size (AX5): the checklist card of « Faire les courses » (its title
    /// and « 2 sur 4 » stack), then the editor of a weekly task with « Assigner à » (the names under the title), and
    /// with « À tour de rôle » and its order.
    @MainActor
    func testTaskScreensAtTheLargestTextSize() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", appearance: .largestText, for: self)
        ui.openMyTasks()
        ui.waitForContent(ui.elements(AccessibilityID.MyTasks.daySummary), "« Ta journée »")

        ui.openTask(UITestDemo.faireCourses)
        ui.reveal(ui.elements(AccessibilityID.Tasks.checklistProgress), "« 2 sur 4 »")
        ui.capture("tache-checklist-ax")

        // `openGroup` scrolls to the group's card if needed (the cards are tall at this size).
        ui.openTab(AccessibilityID.Tabs.groupsTitle, identifier: AccessibilityID.Tabs.groups)
        ui.openGroup(UITestDemo.lilasGroup)
        let titleField = ui.elements(AccessibilityID.Tasks.titleField)
        ui.tap(ui.addTaskButton, "« + »", until: .shows(titleField))
        // The due date first: a frequency would turn it on and insert its (tall, at AX5) row above « Répéter », moving
        // the pill away from under the finger.
        ui.turnOn(
            AccessibilityID.Tasks.dueDateToggle, "« Échéance »",
            until: ui.elements(AccessibilityID.Tasks.dueDatePicker)
        )
        let weekly = ui.buttons(AccessibilityID.Tasks.repeatOption("weekly"))
        ui.tap(weekly, "« Semaine »", until: .selects(weekly))

        ui.reveal(ui.elements(AccessibilityID.Tasks.assigneesButton), "« Assigner à »")
        ui.capture("nouvelle-tache-assigner-ax")

        let ines = ui.elements(AccessibilityID.Tasks.rotationMember(UITestDemo.inesName))
        ui.turnOn(AccessibilityID.Tasks.rotationToggle, "« À tour de rôle »", until: ines)
        ui.reveal(ines, "Inès in the rotation")
        ui.capture("nouvelle-tache-rotation-ax")
    }
}
