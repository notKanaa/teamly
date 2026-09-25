import XCTest

// Helpers of the task screens' UI tests (« Mes tâches », the task screen, the editor). They only build on the public
// helpers of EquipeApp.swift: queries by identifier, `reveal` (never `isHittable`), coordinate taps, outcomes.

/// The checklist of « Faire les courses » in the showcase (TeamTasksMocks `DemoData.Showcase.coursesChecklist`): « Lait »
/// and « Pâtes » are checked.
enum UITestShowcase {
    static let uncheckedItem = "Lessive"
    static let progressBefore = "2 sur 4"
    static let progressAfter = "3 sur 4"
}

extension EquipeApp {
    /// Opens « Mes tâches » and waits for its list.
    func openMyTasks(file: StaticString = #filePath, line: UInt = #line) {
        openTab(AccessibilityID.Tabs.myTasksTitle, identifier: AccessibilityID.Tabs.myTasks, file: file, line: line)
        waitFor(elements(AccessibilityID.MyTasks.list), "the « Mes tâches » list", file: file, line: line)
    }

    /// Every element with this identifier whose label contains `text`.
    func elements(_ identifier: String, labelContaining text: String) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", identifier, text))
    }

    /// Every element with this identifier and this accessibility value.
    func elements(_ identifier: String, value: String) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", identifier, value))
    }

    /// Brings the switch `identifier` on screen and turns it on, until `outcome` shows (3 tries at most). A SwiftUI
    /// `Toggle` spans its row: the tap goes to the switch, on the trailing side.
    func turnOn(
        _ identifier: String,
        _ description: String,
        until outcome: XCUIElementQuery,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toggles = app.switches.matching(identifier: identifier)
        for attempt in 0..<3 {
            // A short wait: a row far down a form only exists once scrolled near, and `reveal` scrolls after it.
            let revealed = reveal(toggles, description, timeout: UITestTimeout.short, file: file, line: line)
            guard let toggle = revealed else { return }
            let isOn = (try? toggle.snapshot())?.value as? String == "1"
            if !isOn {
                // The switch on the trailing side of the row; on a retry, the inner switch element when there is one.
                let inner = toggle.switches.firstMatch
                if attempt > 0, inner.exists, inner.frame.width >= 1 {
                    inner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                } else {
                    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
                }
            }
            if outcome.firstMatch.waitForExistence(timeout: UITestTimeout.short) {
                return
            }
        }
        XCTFail("Turning \(description) on had no effect: \(outcome.debugDescription)", file: file, line: line)
    }
}
