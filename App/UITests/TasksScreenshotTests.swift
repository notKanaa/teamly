import XCTest

/// Screenshots and design checks of the v2 task screens (docs/DESIGN-V2.md §7.3, §7.6, §7.7): « Mes tâches » in dark
/// mode (07-mes-taches-sombre, one of the CI captures), then the task screens and the editor in dark mode and at the
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

    /// Showcase in dark mode: « Mes tâches », « Sortir les poubelles » (every week, à tour de rôle), « Faire les
    /// courses » (the checklist), and the editor of a weekly task.
    @MainActor
    func testTaskScreensInDarkMode() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", appearance: .dark, for: self)
        captureTaskScreens(ui, suffix: "sombre", scrolls: 1)
    }

    /// Showcase at the largest accessibility text size (AX5): the same screens, from their top down.
    @MainActor
    func testTaskScreensAtTheLargestTextSize() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", appearance: .largestText, for: self)
        captureTaskScreens(ui, suffix: "ax", scrolls: 3)
    }

    /// « Mes tâches », two task screens and the editor, each captured at its top then after each of `scrolls` scrolls.
    @MainActor
    private func captureTaskScreens(_ ui: EquipeApp, suffix: String, scrolls: Int) {
        ui.openMyTasks()
        ui.waitForContent(ui.elements(AccessibilityID.MyTasks.daySummary), "« Ta journée »")
        ui.capture("mes-taches-\(suffix)")
        scrollAndCapture(ui, "mes-taches-\(suffix)", scrolls: scrolls)
        ui.scrollToTop(until: ui.elements(AccessibilityID.MyTasks.daySummary))

        ui.openTask(UITestDemo.sortirPoubelles)
        ui.waitForContent(ui.elements(AccessibilityID.Tasks.statusOption("todo")), "the status")
        ui.capture("tache-rotation-\(suffix)")
        scrollAndCapture(ui, "tache-rotation-\(suffix)", scrolls: scrolls)
        ui.goBack(from: UITestScreen.task)

        ui.openTask(UITestDemo.faireCourses)
        ui.waitForContent(ui.elements(AccessibilityID.Tasks.statusOption("todo")), "the status")
        ui.capture("tache-checklist-\(suffix)")
        scrollAndCapture(ui, "tache-checklist-\(suffix)", scrolls: scrolls)

        ui.openTab(AccessibilityID.Tabs.groupsTitle, identifier: AccessibilityID.Tabs.groups)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        let titleField = ui.elements(AccessibilityID.Tasks.titleField)
        ui.tap(ui.addTaskButton, "« + »", until: .shows(titleField))
        let weekly = ui.buttons(AccessibilityID.Tasks.repeatOption("weekly"))
        ui.tap(weekly, "« Semaine »", until: .selects(weekly))
        // Best effort: the rotation's rows (the scrolls also put the keyboard away).
        ui.scroll(.towardsBottom)
        ui.scroll(.towardsBottom)
        ui.switchOn(AccessibilityID.Tasks.rotationToggle)
        ui.scrollToTop(until: titleField)
        ui.capture("nouvelle-tache-\(suffix)")
        scrollAndCapture(ui, "nouvelle-tache-\(suffix)", scrolls: scrolls + 1)
    }

    /// Captures `name-1`, `name-2`… after each of `scrolls` scrolls (two drags each) towards the bottom.
    @MainActor
    private func scrollAndCapture(_ ui: EquipeApp, _ name: String, scrolls: Int) {
        for index in 1...max(scrolls, 1) {
            ui.scroll(.towardsBottom)
            ui.scroll(.towardsBottom)
            ui.capture("\(name)-\(index)")
        }
    }
}
