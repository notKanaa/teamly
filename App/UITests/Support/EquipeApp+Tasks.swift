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
    /// `Toggle` spans its row, which may be taller than the screen at accessibility text sizes: the tap goes to the
    /// switch itself (the row's inner switch, or its trailing side at mid-height), once that point is on screen.
    func turnOn(
        _ identifier: String,
        _ description: String,
        until outcome: XCUIElementQuery,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toggles = app.switches.matching(identifier: identifier)
        for _ in 0..<3 {
            // A short wait: a row far down a form only exists once scrolled near, and `reveal` scrolls after it.
            let revealed = reveal(toggles, description, timeout: UITestTimeout.short, file: file, line: line)
            guard let toggle = revealed else { return }
            if outcome.firstMatch.exists {
                return
            }
            let isOn = (try? toggle.snapshot())?.value as? String == "1"
            if !isOn, let point = switchPoint(of: toggle) {
                point.tap()
            }
            if outcome.firstMatch.waitForExistence(timeout: UITestTimeout.short) {
                return
            }
        }
        XCTFail("Turning \(description) on had no effect: \(outcome.debugDescription)", file: file, line: line)
    }

    /// Where to tap the switch of a `Toggle` row: its inner switch when it exposes one, else the trailing side of the
    /// row at mid-height. Scrolls (5 times at most) until that point is on screen, clear of the bars at the top and of
    /// the keyboard (with its toolbar) or the home indicator at the bottom. Nil when the row is gone.
    private func switchPoint(of toggle: XCUIElement) -> XCUICoordinate? {
        for _ in 0..<5 {
            guard let row = try? toggle.snapshot().frame else { return nil }
            let target = innerSwitchCenter(of: toggle, rowWidth: row.width)
                ?? CGPoint(x: row.minX + row.width * 0.92, y: row.midY)
            let screen = app.frame
            var bottom = screen.maxY - 40
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists, let frame = try? keyboard.snapshot().frame, frame.height >= 1 {
                bottom = min(bottom, frame.minY - 56)
            }
            let top = screen.minY + 120
            if target.y > bottom {
                scroll(.towardsBottom)
            } else if target.y < top {
                scroll(.towardsTop)
            } else {
                let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                return origin.withOffset(CGVector(dx: target.x, dy: target.y))
            }
        }
        return nil
    }

    /// The center of the switch drawn inside a `Toggle` row (a descendant switch narrower than the row), if any.
    private func innerSwitchCenter(of toggle: XCUIElement, rowWidth: CGFloat) -> CGPoint? {
        let inner = toggle.switches.firstMatch
        guard inner.exists, let frame = try? inner.snapshot().frame,
              frame.width >= 1, frame.height >= 1, frame.width < rowWidth * 0.5
        else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}
