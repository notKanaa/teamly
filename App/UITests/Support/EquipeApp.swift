import XCTest

// Helpers shared by the UI tests: launch on the in-memory mock backend, robust queries (identifiers first),
// waits that never sleep blindly (existence / predicate expectations, or short polling with a deadline),
// scrolling, dialogs and screenshots. The screens' identifiers come from App/Sources/Shared (compiled into this
// target); the demo data from TeamTasksMocks `DemoData` is repeated in `UITestDemo`.

/// Launch scenarios of the in-memory backend (`-mockScenario`, see App/Sources/Environment/AppEnvironment.swift).
enum UITestScenario: String {
    /// Demo data, no session: the login screen.
    case signedOut
    /// Demo data, signed in as Camille.
    case populated
    /// Signed in as a user of no group.
    case emptyGroups
}

/// Demo data of the in-memory backend (TeamTasksMocks `DemoData`, identical to supabase/seed.sql). The UI test
/// target cannot import the package: the values the tests rely on are repeated here. Dates are never checked.
enum UITestDemo {
    static let password = "motdepasse123"
    static let camilleEmail = "camille@example.com"
    static let inesEmail = "ines@example.com"

    static let camilleName = "Camille Martin"
    static let lucasName = "Lucas Bernard"
    static let inesName = "Inès Dubois"

    /// Camille is admin, Lucas and Inès are members.
    static let lilasGroup = "Coloc' rue des Lilas"
    /// Lucas is admin, Camille is a member.
    static let sportGroup = "Projet Asso Sport"
    /// Invite code of « Coloc' rue des Lilas » (`LYLAS234`) as displayed.
    static let lilasInviteCode = "LYLA-S234"

    // Tasks of « Coloc' rue des Lilas ».
    /// Created by Camille, assigned to Inès only.
    static let payerLoyer = "Payer le loyer"
    /// Created by Camille, assigned to Camille.
    static let sortirPoubelles = "Sortir les poubelles"
    /// Created by Lucas, assigned to Lucas and Camille, due tomorrow (never overdue).
    static let faireCourses = "Faire les courses"
    /// Created by Inès, unassigned.
    static let reparerFuite = "Réparer la fuite du lavabo"

    // Task of « Projet Asso Sport ».
    /// Created by Lucas, assigned to Camille.
    static let reserverGymnase = "Réserver le gymnase"
}

/// Timeouts: generous, CI simulators are slow (above all for the first launch of a run).
enum UITestTimeout {
    static let long: TimeInterval = 30
    static let medium: TimeInterval = 10
    static let short: TimeInterval = 5
}

/// The launched app and the actions of the tests.
@MainActor
final class EquipeApp {
    let app: XCUIApplication
    private let testCase: XCTestCase

    private init(app: XCUIApplication, testCase: XCTestCase) {
        self.app = app
        self.testCase = testCase
    }

    /// Launches the app on the in-memory backend in `scenario`, in French. Stops the test at the first failure.
    /// - Parameter notifications: initial permission of the in-app notification fake
    ///   (`notDetermined` by default, which the app's request grants without any system prompt).
    static func launch(
        _ scenario: UITestScenario,
        notifications: String? = nil,
        for testCase: XCTestCase
    ) -> EquipeApp {
        testCase.continueAfterFailure = false
        let app = XCUIApplication()
        var arguments = [
            "-uiTestMockBackend",
            "-mockScenario", scenario.rawValue,
            "-AppleLanguages", "(fr)",
            "-AppleLocale", "fr_FR",
        ]
        if let notifications {
            arguments += ["-mockNotifications", notifications]
        }
        app.launchArguments = arguments
        app.launch()
        return EquipeApp(app: app, testCase: testCase)
    }

    // MARK: - Queries

    /// Any element with this accessibility identifier (the first one in the tree).
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func button(_ identifier: String) -> XCUIElement {
        app.buttons.matching(identifier: identifier).firstMatch
    }

    func textField(_ identifier: String) -> XCUIElement {
        app.textFields.matching(identifier: identifier).firstMatch
    }

    /// Any element whose accessibility label contains every one of `fragments`.
    func element(labelContaining fragments: String...) -> XCUIElement {
        let predicates = fragments.map { NSPredicate(format: "label CONTAINS %@", $0) }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    // MARK: - Waiting

    /// Waits until `element` exists; fails the test otherwise.
    @discardableResult
    func waitFor(
        _ element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.long,
        _ description: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let exists = element.waitForExistence(timeout: timeout)
        if !exists {
            XCTFail("Timed out after \(Int(timeout)) s waiting for \(description ?? element.description)", file: file, line: line)
        }
        return element
    }

    /// Waits until `element` exists (fails otherwise), then until it is on screen and the app is idle (end of the
    /// push / sheet animations): what a screenshot needs.
    @discardableResult
    func waitForContent(
        _ element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.long,
        _ description: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        waitFor(element, timeout: timeout, description, file: file, line: line)
        // Best effort: containers are not always reported as hittable; reading the property waits for idle.
        _ = waitUntilHittable(element, timeout: UITestTimeout.short)
        return element
    }

    /// True as soon as `predicate` holds for `element`, false after `timeout`.
    func wait(for element: XCUIElement, toMatch predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        wait(for: element, toMatch: NSPredicate(format: "exists == true AND isHittable == true"), timeout: timeout)
    }

    func waitUntilSelected(_ element: XCUIElement, timeout: TimeInterval = UITestTimeout.medium) -> Bool {
        wait(for: element, toMatch: NSPredicate(format: "isSelected == true"), timeout: timeout)
    }

    /// Waits until `element` is gone; fails the test otherwise.
    func waitForDisappearance(
        _ element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.long,
        _ description: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !wait(for: element, toMatch: NSPredicate(format: "exists == false"), timeout: timeout) {
            XCTFail("\(description ?? element.description) is still shown after \(Int(timeout)) s", file: file, line: line)
        }
    }

    /// Waits until the label (or the value) of `element` is `text`; fails the test otherwise.
    func waitForText(
        _ text: String,
        of element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.medium,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitFor(element, timeout: timeout, file: file, line: line)
        let predicate = NSPredicate(format: "label == %@ OR value == %@", text, text)
        if !wait(for: element, toMatch: predicate, timeout: timeout) {
            XCTFail("Expected « \(text) », found « \(element.label) »", file: file, line: line)
        }
    }

    /// Fails if `element` appears within `timeout` (a bounded wait, for things that must stay hidden).
    func assertNotShown(
        _ element: XCUIElement,
        within timeout: TimeInterval = 2,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let appeared = element.waitForExistence(timeout: timeout)
        XCTAssertFalse(appeared, message, file: file, line: line)
    }

    /// The first of `elements` that exists, polling until `timeout` (nil if none showed up).
    func firstExisting(_ elements: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = elements.first(where: { $0.exists }) {
                return found
            }
            pollingPause()
        } while Date() < deadline
        return nil
    }

    /// Short run-loop turn between two polls of a condition that has a deadline (not a blind wait for content).
    private func pollingPause() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    // MARK: - Scrolling

    enum ScrollDirection {
        /// Moves the content up to show what is below.
        case towardsBottom
        /// Moves the content down to show what is above.
        case towardsTop
    }

    /// One controlled drag (no flick), above the keyboard when it is shown, near the leading edge: in the margin of
    /// the inset lists, where no control (segmented picker, switch) would keep the touch from scrolling.
    func scroll(_ direction: ScrollDirection) {
        let from: CGFloat = direction == .towardsBottom ? 0.45 : 0.3
        let to: CGFloat = direction == .towardsBottom ? 0.2 : 0.55
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: from))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Waits for `element`, then scrolls down until it is on screen and not covered (keyboard, tab bar).
    @discardableResult
    func reveal(
        _ element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.long,
        maxScrolls: Int = 6,
        _ description: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        if element.waitForExistence(timeout: timeout), waitUntilHittable(element, timeout: 2) {
            return element
        }
        for _ in 0..<maxScrolls {
            scroll(.towardsBottom)
            if element.waitForExistence(timeout: 2), waitUntilHittable(element, timeout: 1) {
                return element
            }
        }
        XCTFail("Could not bring \(description ?? element.description) on screen", file: file, line: line)
        return element
    }

    /// Scrolls up (at most `maxScrolls` times) until `element` is on screen.
    func scrollToTop(until element: XCUIElement, maxScrolls: Int = 3) {
        var scrolls = 0
        while !(element.exists && element.isHittable) && scrolls < maxScrolls {
            scroll(.towardsTop)
            scrolls += 1
        }
    }

    // MARK: - Actions

    /// Waits for `element`, brings it on screen and taps it.
    func tap(
        _ element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.long,
        _ description: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        reveal(element, timeout: timeout, description, file: file, line: line)
        element.tap()
    }

    /// Waits until `element` is enabled (e.g. a « Créer » button waiting for valid input), then taps it.
    func tapWhenEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.long,
        _ description: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        reveal(element, timeout: timeout, description, file: file, line: line)
        if !wait(for: element, toMatch: NSPredicate(format: "isEnabled == true"), timeout: UITestTimeout.medium) {
            XCTFail("\(description ?? element.description) stays disabled", file: file, line: line)
        }
        element.tap()
    }

    /// Taps a list row (`NavigationLink`) by identifier, away from the status button of task rows (on the left):
    /// the tap lands on the cell holding the identifier, whatever element SwiftUI gives it to.
    func tapRow(
        _ identifier: String,
        timeout: TimeInterval = UITestTimeout.long,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        reveal(element(identifier), timeout: timeout, identifier, file: file, line: line)
        rowTarget(identifier).coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
    }

    private func rowTarget(_ identifier: String) -> XCUIElement {
        let cell = app.cells.matching(identifier: identifier).firstMatch
        if cell.exists {
            return cell
        }
        let container = app.cells.containing(.any, identifier: identifier).firstMatch
        if container.exists {
            return container
        }
        // No cell: the widest element holding the identifier (the row rather than a button inside it).
        let matches = app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex
        return matches.max { $0.frame.width < $1.frame.width } ?? element(identifier)
    }

    /// Taps `field` and types `text`. Returns the resulting text (as corrected by the keyboard, if ever).
    @discardableResult
    func typeText(
        _ text: String,
        into field: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        reveal(field, file: file, line: line)
        field.tap()
        field.typeText(text)
        if let value = field.value as? String, !value.isEmpty {
            return value
        }
        return text
    }

    /// Taps the button `label` of the confirmation dialog opened by `source` (an action sheet, or an anchored
    /// dialog on recent iOS versions), found by identifier when SwiftUI forwards it, by label otherwise.
    func confirm(
        _ label: String,
        identifier: String,
        openedFrom source: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Read now: the source may leave the accessibility tree while the dialog is shown.
        let sourceExists = source.exists
        let sourceFrame = sourceExists ? source.frame : .zero
        let sourceIdentifier = sourceExists ? source.identifier : ""
        let byIdentifier = button(identifier)
        let byLabel = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let deadline = Date().addingTimeInterval(UITestTimeout.medium)
        repeat {
            if byIdentifier.exists, byIdentifier.isHittable {
                byIdentifier.tap()
                return
            }
            let candidates = byLabel.allElementsBoundByIndex.filter { candidate in
                candidate.isHittable
                    && (sourceIdentifier.isEmpty || candidate.identifier != sourceIdentifier)
                    && candidate.frame != sourceFrame
            }
            if let dialogButton = candidates.last {
                dialogButton.tap()
                return
            }
            pollingPause()
        } while Date() < deadline
        XCTFail("No « \(label) » button in the confirmation dialog", file: file, line: line)
    }

    /// Waits for an alert and checks that its texts contain `fragment`; returns it.
    @discardableResult
    func waitForAlert(
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let alert = waitFor(app.alerts.firstMatch, timeout: UITestTimeout.medium, "an alert", file: file, line: line)
        let text = alert.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
            .firstMatch
        if !text.waitForExistence(timeout: UITestTimeout.short) {
            XCTFail("The alert « \(alert.label) » does not mention « \(fragment) »", file: file, line: line)
        }
        return alert
    }

    // MARK: - Navigation

    /// The ways to find a tab button, best first: in the tab bar by title, then by identifier (set on the tab item's
    /// label, not always forwarded by SwiftUI), then anywhere by title.
    func tabButtonCandidates(_ title: String, identifier: String) -> [XCUIElement] {
        let byTitle = NSPredicate(format: "label == %@", title)
        return [
            app.tabBars.buttons.matching(byTitle).firstMatch,
            app.tabBars.buttons.matching(identifier: identifier).firstMatch,
            app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch,
            app.buttons.matching(identifier: identifier).firstMatch,
            app.buttons.matching(byTitle).firstMatch,
        ]
    }

    /// Waits for the signed-in app (its tab bar, or the « Mes tâches » tab).
    func waitForTabBar(
        timeout: TimeInterval = UITestTimeout.long,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let candidates = [app.tabBars.firstMatch]
            + tabButtonCandidates(AccessibilityID.Tabs.myTasksTitle, identifier: AccessibilityID.Tabs.myTasks)
        if firstExisting(candidates, timeout: timeout) == nil {
            XCTFail("Timed out after \(Int(timeout)) s waiting for the tab bar", file: file, line: line)
        }
    }

    /// Selects a tab by title (`AccessibilityID.Tabs.*Title`), by identifier as a fallback.
    func openTab(
        _ title: String,
        identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForTabBar(file: file, line: line)
        guard let tab = firstExisting(tabButtonCandidates(title, identifier: identifier), timeout: UITestTimeout.short) else {
            XCTFail("No « \(title) » tab", file: file, line: line)
            return
        }
        tab.tap()
    }

    /// Waits until a navigation bar shows `title`.
    func waitForNavigationTitle(
        _ title: String,
        timeout: TimeInterval = UITestTimeout.long,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let candidates = [
            app.navigationBars.matching(NSPredicate(format: "identifier == %@", title)).firstMatch,
            app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch,
        ]
        if firstExisting(candidates, timeout: timeout) == nil {
            XCTFail("No navigation bar titled « \(title) »", file: file, line: line)
        }
    }

    /// Taps the back button: the one of the navigation bar titled `title` when given, otherwise the top-most one.
    func goBack(
        from title: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(UITestTimeout.medium)
        repeat {
            if let back = backButton(from: title) {
                back.tap()
                return
            }
            pollingPause()
        } while Date() < deadline
        XCTFail("No back button", file: file, line: line)
    }

    private func backButton(from title: String?) -> XCUIElement? {
        if let title {
            let bar = app.navigationBars.matching(NSPredicate(format: "identifier == %@", title)).firstMatch
            if bar.exists {
                let back = bar.buttons.matching(identifier: "BackButton").firstMatch
                if back.exists, back.isHittable {
                    return back
                }
                let first = bar.buttons.element(boundBy: 0)
                if first.exists, first.isHittable {
                    return first
                }
            }
        }
        // The last hittable one: a sheet's bar comes after the bars of the screen below it.
        return app.navigationBars.buttons.matching(identifier: "BackButton").allElementsBoundByIndex.last { $0.isHittable }
    }

    // MARK: - Screens

    /// Fills the login form and signs in; waits for the signed-in app.
    func signIn(
        email: String,
        password: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitFor(element(AccessibilityID.Auth.loginScreen), "the login screen", file: file, line: line)
        typeText(email, into: textField(AccessibilityID.Auth.email), file: file, line: line)
        let passwordField = app.secureTextFields.matching(identifier: AccessibilityID.Auth.password).firstMatch
        typeText(password, into: passwordField, file: file, line: line)
        let signInButton = button(AccessibilityID.Auth.signInButton)
        if signInButton.isHittable, signInButton.isEnabled {
            signInButton.tap()
        } else {
            // Hidden by the keyboard: « Aller » submits the form as well.
            passwordField.typeText("\n")
        }
        waitForTabBar(file: file, line: line)
    }

    /// Waits for the groups list with the two demo groups (signed in as Camille).
    func waitForDemoGroups(file: StaticString = #filePath, line: UInt = #line) {
        waitForTabBar(file: file, line: line)
        waitForContent(element(AccessibilityID.Groups.row(UITestDemo.lilasGroup)), file: file, line: line)
        waitForContent(element(AccessibilityID.Groups.row(UITestDemo.sportGroup)), file: file, line: line)
    }

    /// Opens a group from the groups list and waits until its screen is loaded (« + » shown).
    func openGroup(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        tapRow(AccessibilityID.Groups.row(name), file: file, line: line)
        waitForContent(button(AccessibilityID.Tasks.addButton), "the « + » button of « \(name) »", file: file, line: line)
    }

    /// Opens a task from the group screen and waits for its detail.
    func openTask(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        tapRow(AccessibilityID.Tasks.row(title), file: file, line: line)
        waitForText(title, of: element(AccessibilityID.Tasks.detailTitle), timeout: UITestTimeout.long, file: file, line: line)
    }

    /// In the task editor: « Assigner à » → selects `name` → back to the editor.
    func assign(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        tapRow(AccessibilityID.Tasks.assigneesButton, file: file, line: line)
        let row = element(AccessibilityID.Tasks.assigneeRow(name))
        tap(row, "the assignee « \(name) »", file: file, line: line)
        if !waitUntilSelected(row) {
            XCTFail("« \(name) » is not selected", file: file, line: line)
        }
        goBack(from: "Assigner à", file: file, line: line)
        waitForContent(element(AccessibilityID.Tasks.assigneesButton), "the editor", file: file, line: line)
    }

    /// Best effort (screenshot polish): selects the segment `title` of the segmented picker `identifier`.
    func selectSegment(_ title: String, of identifier: String) {
        let control = app.segmentedControls.matching(identifier: identifier).firstMatch
        let segment = control.exists
            ? control.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
            : app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        guard segment.waitForExistence(timeout: UITestTimeout.short) else { return }
        if !segment.isHittable {
            scroll(.towardsBottom)
        }
        if segment.isHittable {
            segment.tap()
        }
    }

    /// Best effort (screenshot polish): turns the switch `identifier` on. Returns whether it is on.
    @discardableResult
    func switchOn(_ identifier: String) -> Bool {
        let toggle = app.switches.matching(identifier: identifier).firstMatch
        guard toggle.waitForExistence(timeout: UITestTimeout.short) else { return false }
        if !toggle.isHittable {
            scroll(.towardsBottom)
        }
        let isOn = NSPredicate(format: "value == %@", "1")
        if isOn.evaluate(with: toggle) {
            return true
        }
        // A SwiftUI Toggle's element spans the row: tap the switch itself, on the trailing side.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        if wait(for: toggle, toMatch: isOn, timeout: UITestTimeout.short) {
            return true
        }
        let inner = toggle.switches.firstMatch
        if inner.exists, inner.isHittable {
            inner.tap()
        }
        return wait(for: toggle, toMatch: isOn, timeout: UITestTimeout.short)
    }

    // MARK: - Screenshots

    /// Attaches a screenshot of the whole screen, kept even when the test passes (the CI exports it by name).
    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}
