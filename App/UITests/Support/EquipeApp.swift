import XCTest

// Helpers shared by the UI tests: launch on the in-memory mock backend, queries by identifier, waits with deadlines
// (existence expectations or short polling, never a blind sleep), scrolling, taps, text entry, dialogs and
// screenshots. The screens' identifiers come from App/Sources/Shared (compiled into this target); the demo data from
// TeamTasksMocks `DemoData` is repeated in `UITestDemo`.
//
// Rules imposed by iOS 26 (Xcode 26), where the first version of these helpers failed:
// - `isHittable` is never evaluated, neither in a predicate nor directly: for some elements (Liquid Glass toolbar
//   items, secure fields, form rows, off-screen copies) it raises « Failed to determine hittability … Activation
//   point invalid », which fails the test instead of returning false. Whether an element can be tapped is read from
//   its snapshot: it exists, its frame is not empty and meets the app window, and the tap point is not under the
//   keyboard or the tab bar. Reading a snapshot never raises: it throws, and the element is skipped.
// - A query may match several elements (toolbars and sheets keep hidden, zero-size or off-screen copies): every
//   match is looked at and the first one on screen is used, never a blind `firstMatch`.
// - Taps are coordinate taps inside the chosen element (`coordinate(withNormalizedOffset:)`, the center when the
//   whole element is reachable), once the element is on screen and its frame has settled (same frame in two
//   consecutive polls: the push / sheet / scroll animation is over). A tap that should open or close something
//   checks that it happened, and tries again (3 times at most, on the next copy of the element if there are several).
// - Text entry: tap the field, wait for the keyboard, type through the app, then check the field's value.

/// Launch scenarios of the in-memory backend (`-mockScenario`, see App/Sources/Environment/AppEnvironment.swift).
enum UITestScenario: String {
    /// Demo data, no session: the login screen.
    case signedOut
    /// Demo data, signed in as Camille.
    case populated
    /// Signed in as a user of no group.
    case emptyGroups
    /// `populated` plus the v2 content of TeamTasksMocks `DemoData.Showcase` (v2 screenshots): « Sortir les poubelles »
    /// weekly and à tour de rôle (Camille's turn), a half-done checklist on « Faire les courses », an activity feed, and
    /// a podium with Inès first on a 3-week streak.
    case showcase
}

/// Appearance of the launched app (`-uiTestColorScheme`, `-UIPreferredContentSizeCategoryName`): the design checks.
enum UITestAppearance {
    /// Dark mode.
    case dark
    /// The largest accessibility text size (AX5).
    case largestText

    var launchArguments: [String] {
        switch self {
        case .dark:
            ["-uiTestColorScheme", "dark"]
        case .largestText:
            ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
    }
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

    /// A well-formed invite code (8 characters of the code alphabet, letters only: no switch of keyboard layout while
    /// typing it) that belongs to no group (the demo codes are `LYLAS234` and `SPRT5678`).
    static let unknownInviteCode = "ZZZZZZZZ"
    /// `unknownInviteCode` as the « Rejoindre un groupe » field formats it live.
    static let unknownInviteCodeDisplayed = "ZZZZ-ZZZZ"
    /// Message of `AppError.invalidCode` (TeamTasksCore): the server knows no such code.
    static let invalidCodeMessage = "Code d’invitation invalide."

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

    // v2 pickers (TeamTasksCore `EmojiChoices`).
    /// First avatar emoji.
    static let foxEmoji = "\u{1F98A}"
    /// First group emoji.
    static let houseEmoji = "\u{1F3E0}"
}

/// Navigation titles of the screens the tests leave with « back ».
enum UITestScreen {
    /// Task screen (TaskDetailView).
    static let task = "Tâche"
    /// « Assigner à », pushed from the task editor (TaskEditorAssigneePicker).
    static let assignees = "Assigner à"
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
    /// What a tap is expected to cause: `tap` checks it and tries again (3 taps at most) until it happens.
    enum Outcome {
        /// An element of this query exists (a sheet's field, the content of a pushed screen…).
        case shows(XCUIElementQuery)
        /// No element of this query is on screen any more (a sheet, an alert).
        case hides(XCUIElementQuery)
        /// An element of this query is selected (a status option, an assignee).
        case selects(XCUIElementQuery)
    }

    enum ScrollDirection {
        /// Moves the content up to show what is below.
        case towardsBottom
        /// Moves the content down to show what is above.
        case towardsTop
    }

    let app: XCUIApplication
    private let testCase: XCTestCase
    /// System UI drawn over the app (notification banners, system alerts). Creating it does not launch anything.
    private let springboard: XCUIApplication
    private var knownWindowFrame: CGRect?

    private static let unnamed = "the expected element"

    private init(app: XCUIApplication, testCase: XCTestCase) {
        self.app = app
        self.testCase = testCase
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    /// Launches the app on the in-memory backend in `scenario`, in French. Stops the test at the first failure.
    /// - Parameters:
    ///   - notifications: initial permission of the in-app notification fake (`notDetermined` by default, which the
    ///     app's request grants without any system prompt).
    ///   - appearance: dark mode or the largest text size (design checks); the system's otherwise.
    ///   - arguments: more launch arguments (`-uiTestDesignGallery`).
    static func launch(
        _ scenario: UITestScenario,
        notifications: String? = nil,
        appearance: UITestAppearance? = nil,
        arguments extraArguments: [String] = [],
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
        if let appearance {
            arguments += appearance.launchArguments
        }
        arguments += extraArguments
        app.launchArguments = arguments
        app.launch()
        return EquipeApp(app: app, testCase: testCase)
    }

    // MARK: - Queries

    /// Every element with this accessibility identifier, whatever its type.
    func elements(_ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    /// Every element whose accessibility label contains each one of `fragments`.
    func elements(labelContaining fragments: String...) -> XCUIElementQuery {
        let predicates = fragments.map { NSPredicate(format: "label CONTAINS %@", $0) }
        return app.descendants(matching: .any).matching(NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
    }

    func buttons(_ identifier: String) -> XCUIElementQuery {
        app.buttons.matching(identifier: identifier)
    }

    /// Buttons with this identifier or this label: toolbar buttons, whose identifier iOS 26 may keep on another copy.
    func buttons(_ identifier: String, orLabel label: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label))
    }

    func textFields(_ identifier: String) -> XCUIElementQuery {
        app.textFields.matching(identifier: identifier)
    }

    func secureTextFields(_ identifier: String) -> XCUIElementQuery {
        app.secureTextFields.matching(identifier: identifier)
    }

    /// « Créer » (a « + » icon) in the toolbar of the groups list.
    var createGroupButton: XCUIElementQuery {
        buttons(AccessibilityID.Groups.createButton, orLabel: "Créer")
    }

    /// « Rejoindre » in the toolbar of the groups list.
    var joinGroupButton: XCUIElementQuery {
        buttons(AccessibilityID.Groups.joinButton, orLabel: "Rejoindre")
    }

    /// « + » (« Nouvelle tâche ») in the toolbar of the group screen.
    var addTaskButton: XCUIElementQuery {
        buttons(AccessibilityID.Tasks.addButton, orLabel: "Nouvelle tâche")
    }

    /// The text shown by a field of `query`, nil when it is empty or shows its placeholder.
    func currentText(of query: XCUIElementQuery) -> String? {
        for match in currentMatches(query, reachability: false) {
            if let value = match.value, !value.isEmpty, value != match.placeholder {
                return value
            }
        }
        return nil
    }

    // MARK: - Waiting

    /// Waits until an element of `query` exists; fails the test otherwise.
    @discardableResult
    func waitFor(
        _ query: XCUIElementQuery,
        _ description: String? = nil,
        timeout: TimeInterval = UITestTimeout.long,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        if query.firstMatch.waitForExistence(timeout: timeout) {
            return true
        }
        fail("Timed out after \(Int(timeout)) s waiting for \(description ?? Self.unnamed)", file: file, line: line)
        return false
    }

    /// Waits until an element of `query` exists (fails otherwise), then, best effort, until one is on screen with a
    /// settled frame (end of the push / sheet animations): what a screenshot needs.
    func waitForContent(
        _ query: XCUIElementQuery,
        _ description: String? = nil,
        timeout: TimeInterval = UITestTimeout.long,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard waitFor(query, description, timeout: timeout, file: file, line: line) else { return }
        _ = settledMatch(query, timeout: UITestTimeout.short, reachability: false) { matches in
            matches.first { $0.visible != nil }
        }
    }

    /// True as soon as an element of `query` is selected, false after `timeout`.
    func waitUntilSelected(_ query: XCUIElementQuery, timeout: TimeInterval = UITestTimeout.medium) -> Bool {
        waitUntil(timeout: timeout) {
            currentMatches(query, reachability: false).contains { $0.isSelected }
        }
    }

    /// True as soon as an element of `query` is on screen and enabled, false after `timeout`.
    func waitUntilEnabled(_ query: XCUIElementQuery, timeout: TimeInterval = UITestTimeout.medium) -> Bool {
        waitUntil(timeout: timeout) {
            currentMatches(query, reachability: false).contains { $0.visible != nil && $0.isEnabled }
        }
    }

    /// Waits until no element of `query` is on screen (gone, or moved off screen); fails the test otherwise.
    func waitForDisappearance(
        _ query: XCUIElementQuery,
        _ description: String? = nil,
        timeout: TimeInterval = UITestTimeout.long,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !waitUntil(timeout: timeout, { !isOnScreen(query) }) {
            fail(
                "\(description ?? Self.unnamed) is still shown after \(Int(timeout)) s",
                showing: query, file: file, line: line
            )
        }
    }

    /// Waits until the label (or the value) of an element of `query` is `text`; fails the test otherwise.
    func waitForText(
        _ text: String,
        of query: XCUIElementQuery,
        timeout: TimeInterval = UITestTimeout.medium,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard waitFor(query, "« \(text) »", timeout: timeout, file: file, line: line) else { return }
        let shown = waitUntil(timeout: timeout) {
            currentMatches(query, reachability: false).contains { $0.label == text || $0.value == text }
        }
        if !shown {
            let found = currentMatches(query, reachability: false)
                .map { "« \($0.value ?? $0.label) »" }
                .joined(separator: ", ")
            fail("Expected « \(text) », found \(found)", file: file, line: line)
        }
    }

    /// Fails if an element of `query` appears within `timeout` (a bounded wait, for things that must stay hidden).
    func assertNotShown(
        _ query: XCUIElementQuery,
        within timeout: TimeInterval = 2,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let appeared = query.firstMatch.waitForExistence(timeout: timeout)
        XCTAssertFalse(appeared, message, file: file, line: line)
    }

    /// The first of `queries` that has an element, polling until `timeout` (nil if none showed up).
    func firstExisting(_ queries: [XCUIElementQuery], timeout: TimeInterval) -> XCUIElementQuery? {
        poll(timeout: timeout) {
            queries.first { $0.firstMatch.exists }
        }
    }

    // MARK: - Scrolling

    /// One controlled drag (no flick), above the keyboard when it is shown, near the leading edge: in the margin of
    /// the inset lists, where no control (segmented picker, switch) would keep the touch from scrolling.
    func scroll(_ direction: ScrollDirection) {
        let from: CGFloat = direction == .towardsBottom ? 0.45 : 0.3
        let to: CGFloat = direction == .towardsBottom ? 0.2 : 0.55
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: from))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Waits for an element of `query`, then scrolls (down, or up when it is above the screen) until one is on
    /// screen, reachable (not under the keyboard or the tab bar) and settled. Fails the test otherwise.
    @discardableResult
    func reveal(
        _ query: XCUIElementQuery,
        _ description: String? = nil,
        timeout: TimeInterval = UITestTimeout.long,
        maxScrolls: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement? {
        let match = revealMatch(
            query, description ?? Self.unnamed, timeout: timeout, maxScrolls: maxScrolls,
            choose: { matches in matches.first { $0.reachable != nil } },
            file: file, line: line
        )
        return match?.element
    }

    /// Scrolls up until the content is at its top: an element of `query` on screen, at the same place after one more
    /// drag. At most `maxScrolls` drags; best effort (screenshot polish).
    func scrollToTop(until query: XCUIElementQuery, maxScrolls: Int = 4) {
        var previousFrame: CGRect?
        for _ in 0..<maxScrolls {
            scroll(.towardsTop)
            let current = settledMatch(query, timeout: 3, reachability: false) { matches in
                matches.first { $0.visible != nil }
            }
            if let frame = current?.frame, let before = previousFrame, frame.isClose(to: before) {
                return
            }
            previousFrame = current?.frame
        }
    }

    // MARK: - Actions

    /// Waits for an element of `query`, brings it on screen and taps it. With `outcome`, checks that the tap had its
    /// effect and taps again when it did not (a tap lost during an animation, or on a stale copy of a toolbar item).
    func tap(
        _ query: XCUIElementQuery,
        _ description: String? = nil,
        timeout: TimeInterval = UITestTimeout.long,
        until outcome: Outcome? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        performTap(query, description ?? Self.unnamed, timeout: timeout, until: outcome, file: file, line: line)
    }

    /// Like `tap`, once an element of `query` is enabled (e.g. a « Créer » button waiting for valid input).
    func tapWhenEnabled(
        _ query: XCUIElementQuery,
        _ description: String? = nil,
        timeout: TimeInterval = UITestTimeout.long,
        until outcome: Outcome? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        performTap(
            query, description ?? Self.unnamed, timeout: timeout, enabledOnly: true, until: outcome,
            file: file, line: line
        )
    }

    /// Taps a list row (`NavigationLink`) by identifier: the widest element holding it (the cell, whatever element
    /// SwiftUI gives the identifier to), at 60 % of its width, away from the status button of task rows (on the left).
    func tapRow(
        _ identifier: String,
        _ description: String? = nil,
        timeout: TimeInterval = UITestTimeout.long,
        until outcome: Outcome? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        performTap(
            elements(identifier), description ?? identifier, timeout: timeout, at: 0.6, widest: true,
            until: outcome, file: file, line: line
        )
    }

    /// Taps a field of `query`, waits for the keyboard and types `text` (through the app: typing into the element
    /// itself may make XCTest check its hit point, which can fail like `isHittable` for secure fields on iOS 26).
    /// Returns the text the field shows (as corrected by the keyboard, if ever).
    /// - Parameter expected: the exact text the field must show (formatted fields, fields without autocorrection).
    ///   When the first typing does not give it, the field is cleared and typed again one key at a time, each key
    ///   once the previous one shows (a field reformatting its text may drop keys typed in one go). Without it, the
    ///   field must only show something.
    @discardableResult
    func typeText(
        _ text: String,
        into query: XCUIElementQuery,
        _ description: String? = nil,
        expecting expected: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let name = description ?? Self.unnamed
        guard let field = revealMatch(
            query, name, timeout: UITestTimeout.long,
            choose: { matches in matches.first { $0.reachable != nil } },
            file: file, line: line
        ) else {
            return text
        }
        tap(field)
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: UITestTimeout.short) {
            // No keyboard: tap lost (sheet or keyboard animation), or a hardware keyboard. Once more; typing then
            // fails clearly if nothing has the focus, and the value check below catches a wrong field.
            let again = settledMatch(query, timeout: 3) { matches in matches.first { $0.reachable != nil } }
            if let again {
                tap(again)
            }
            _ = keyboard.waitForExistence(timeout: UITestTimeout.short)
        }
        app.typeText(text)

        var value = currentText(of: query)
        if let expected, value != expected {
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (value ?? "").count + 2))
            _ = waitUntil(timeout: UITestTimeout.short) { currentText(of: query) == nil }
            for character in text {
                let before = currentText(of: query)
                app.typeText(String(character))
                _ = waitUntil(timeout: 2) { currentText(of: query) != before }
            }
            value = currentText(of: query)
            if value != expected {
                fail(
                    "Typed « \(text) » into \(name), which shows « \(value ?? "") » instead of « \(expected) »",
                    showing: query, file: file, line: line
                )
            }
        } else if value == nil {
            fail("Typed « \(text) » into \(name), which stays empty", showing: query, file: file, line: line)
        }
        return value ?? text
    }

    /// Taps the button `label` of the confirmation dialog opened by the button `sourceIdentifier` (an action sheet,
    /// or a dialog anchored to the source on recent iOS versions), found by identifier when SwiftUI forwards it, by
    /// label otherwise (never the source itself, which may have the same label). Opens the dialog again once if it
    /// did not show up (lost tap).
    func confirm(
        _ label: String,
        identifier: String,
        openedFrom sourceIdentifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Read now: the source may leave the accessibility tree while the dialog is shown.
        let sourceFrames = currentMatches(elements(sourceIdentifier), reachability: false).map(\.frame)
        var target = poll(timeout: UITestTimeout.short) {
            confirmationButton(label, identifier: identifier, sourceIdentifier: sourceIdentifier, sourceFrames: sourceFrames)
        }
        if target == nil {
            performTap(
                buttons(sourceIdentifier), "the button opening « \(label) »", timeout: UITestTimeout.short,
                until: nil, file: file, line: line
            )
            target = poll(timeout: UITestTimeout.medium) {
                confirmationButton(label, identifier: identifier, sourceIdentifier: sourceIdentifier, sourceFrames: sourceFrames)
            }
        }
        guard let button = target else {
            fail(
                "No « \(label) » button in the confirmation dialog",
                showing: app.buttons.matching(NSPredicate(format: "label == %@", label)), file: file, line: line
            )
            return
        }
        tap(button, onTop: true)
    }

    /// Waits for an alert and checks that its texts contain `fragment`; returns it.
    @discardableResult
    func waitForAlert(
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let alert = app.alerts.firstMatch
        guard waitFor(app.alerts, "an alert", timeout: UITestTimeout.medium, file: file, line: line) else {
            return alert
        }
        let text = alert.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
            .firstMatch
        if !text.waitForExistence(timeout: UITestTimeout.short) {
            let texts = currentMatches(alert.staticTexts, reachability: false)
                .map { "« \($0.label) »" }
                .joined(separator: " ")
            fail("The alert (\(texts)) does not mention « \(fragment) »", file: file, line: line)
        }
        return alert
    }

    /// Taps the button `label` of the shown alert and waits until the alert is gone (taps again if it stays).
    func tapAlertButton(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let alertButtons = app.alerts.buttons.matching(NSPredicate(format: "label == %@", label))
        for _ in 0..<3 {
            let found = settledMatch(alertButtons, timeout: UITestTimeout.medium, reachability: false) { matches in
                matches.first { $0.visible != nil }
            }
            guard let button = found else {
                fail("No « \(label) » button in the alert", showing: app.alerts, file: file, line: line)
                return
            }
            tap(button, onTop: true)
            if waitUntil(timeout: UITestTimeout.short, { !isOnScreen(app.alerts) }) {
                return
            }
        }
        fail("The alert is still shown after « \(label) »", showing: app.alerts, file: file, line: line)
    }

    // MARK: - Navigation

    /// The ways to find a tab button, best first: in the tab bar by title, then by identifier (set on the tab item's
    /// label, not always forwarded by SwiftUI), then anywhere by title.
    func tabButtonCandidates(_ title: String, identifier: String) -> [XCUIElementQuery] {
        let byTitle = NSPredicate(format: "label == %@", title)
        return [
            app.tabBars.buttons.matching(byTitle),
            app.tabBars.buttons.matching(identifier: identifier),
            app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)),
            app.buttons.matching(identifier: identifier),
            app.buttons.matching(byTitle),
        ]
    }

    /// Waits for the signed-in app (its tab bar, or the « Mes tâches » tab).
    func waitForTabBar(
        timeout: TimeInterval = UITestTimeout.long,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let candidates = [app.tabBars]
            + tabButtonCandidates(AccessibilityID.Tabs.myTasksTitle, identifier: AccessibilityID.Tabs.myTasks)
        if firstExisting(candidates, timeout: timeout) == nil {
            fail("Timed out after \(Int(timeout)) s waiting for the tab bar", file: file, line: line)
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
        let candidates = tabButtonCandidates(title, identifier: identifier)
        guard let tab = firstExisting(candidates, timeout: UITestTimeout.short) else {
            fail("No « \(title) » tab", file: file, line: line)
            return
        }
        performTap(tab, "the « \(title) » tab", timeout: UITestTimeout.short, until: nil, file: file, line: line)
        if !waitUntilSelected(tab, timeout: UITestTimeout.short) {
            // Not reported as selected (or the tap was lost): once more; the screen's own wait decides.
            performTap(tab, "the « \(title) » tab", timeout: UITestTimeout.short, until: nil, file: file, line: line)
        }
    }

    /// Waits until a navigation bar shows `title`.
    func waitForNavigationTitle(
        _ title: String,
        timeout: TimeInterval = UITestTimeout.long,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if firstExisting([navigationBars(titled: title), navigationTitleTexts(title)], timeout: timeout) == nil {
            fail("No navigation bar titled « \(title) »", file: file, line: line)
        }
    }

    /// Leaves the screen titled `title` with its back button (the back swipe as a last resort), and checks that the
    /// screen is gone.
    func goBack(from title: String, file: StaticString = #filePath, line: UInt = #line) {
        for attempt in 0..<3 {
            var back: Match?
            if attempt < 2 {
                back = poll(timeout: attempt == 0 ? UITestTimeout.medium : UITestTimeout.short) {
                    backButton(from: title)
                }
            }
            if let back {
                tap(back)
            } else {
                swipeBack()
            }
            if waitUntil(timeout: UITestTimeout.short, { !isShowingNavigationTitle(title) }) {
                return
            }
        }
        fail("Still on « \(title) » after going back", showing: navigationBars(titled: title), file: file, line: line)
    }

    // MARK: - Screens

    /// Fills the login form and signs in; waits for the signed-in app.
    func signIn(
        email: String,
        password: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitFor(elements(AccessibilityID.Auth.loginScreen), "the login screen", file: file, line: line)
        typeText(
            email, into: textFields(AccessibilityID.Auth.email), "the e-mail field", expecting: email,
            file: file, line: line
        )
        typeText(
            password, into: secureTextFields(AccessibilityID.Auth.password), "the password field",
            file: file, line: line
        )
        let signInButton = buttons(AccessibilityID.Auth.signInButton)
        submitForm(signInButton, isRetry: false)
        let signedIn = [app.tabBars]
            + tabButtonCandidates(AccessibilityID.Tabs.myTasksTitle, identifier: AccessibilityID.Tabs.myTasks)
        if firstExisting(signedIn, timeout: UITestTimeout.medium) == nil {
            if app.alerts.firstMatch.exists {
                fail("Signing in as \(email) was refused", showing: app.alerts.staticTexts, file: file, line: line)
                return
            }
            // Still on the form and no error: the submission was lost (keyboard animation). Once more.
            submitForm(signInButton, isRetry: true)
        }
        waitForTabBar(file: file, line: line)
        // Best effort: the login screen fades out and its keyboard goes down; the next taps wait for the end.
        _ = waitUntil(timeout: UITestTimeout.medium) {
            !app.keyboards.firstMatch.exists && !isOnScreen(elements(AccessibilityID.Auth.loginScreen))
        }
    }

    /// From the login screen: « Créer un compte », fills the form and creates the account (the in-memory backend opens
    /// the session at once), then waits for the onboarding of the new account.
    func signUp(
        name: String,
        email: String,
        password: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitFor(elements(AccessibilityID.Auth.loginScreen), "the login screen", file: file, line: line)
        tap(
            buttons(AccessibilityID.Auth.goToSignUp), "« Créer un compte »",
            until: .shows(elements(AccessibilityID.Auth.signUpScreen)), file: file, line: line
        )
        typeText(name, into: textFields(AccessibilityID.Auth.displayName), "the name field", file: file, line: line)
        typeText(
            email, into: textFields(AccessibilityID.Auth.email), "the e-mail field", expecting: email,
            file: file, line: line
        )
        typeText(
            password, into: secureTextFields(AccessibilityID.Auth.password), "the password field",
            file: file, line: line
        )
        let signUpButton = buttons(AccessibilityID.Auth.signUpButton)
        let onboarding = elements(AccessibilityID.Onboarding.screen)
        submitForm(signUpButton, isRetry: false)
        if firstExisting([onboarding], timeout: UITestTimeout.medium) == nil {
            if app.alerts.firstMatch.exists {
                fail("Creating the account \(email) was refused", showing: app.alerts.staticTexts, file: file, line: line)
                return
            }
            submitForm(signUpButton, isRetry: true)
        }
        waitFor(onboarding, "the onboarding of the new account", file: file, line: line)
        // Best effort: the sign-up keyboard goes down with its screen.
        _ = waitUntil(timeout: UITestTimeout.medium) { !app.keyboards.firstMatch.exists }
    }

    /// Submits a form whose last field was just typed into: the keyboard's return key while the keyboard is shown
    /// (« Aller », « Rejoindre »: the field submits the form; the button may lie under the keyboard or its bars), the
    /// button otherwise, when a finger can reach it and it is enabled.
    private func submitForm(_ button: XCUIElementQuery, isRetry: Bool) {
        if app.keyboards.firstMatch.exists {
            app.typeText("\n")
            return
        }
        let reachableButton = settledMatch(button, timeout: isRetry ? UITestTimeout.short : 3) { matches in
            matches.first { $0.reachable != nil && $0.isEnabled }
        }
        if let reachableButton {
            tap(reachableButton)
        }
    }

    // MARK: - Onboarding

    /// The content of an onboarding step, by `OnboardingStep.rawValue` (`welcome`, `avatar`, `firstGroup`,
    /// `notifications`).
    func onboardingStep(_ step: String) -> XCUIElementQuery {
        elements(AccessibilityID.Onboarding.step(step))
    }

    /// The primary button of the onboarding (« C’est parti », « Continuer », « Créer le groupe »…).
    var onboardingPrimaryButton: XCUIElementQuery {
        buttons(AccessibilityID.Onboarding.primaryButton)
    }

    /// Taps the onboarding's primary button once it is enabled, until the step `next` shows (the tab bar when nil:
    /// the onboarding ended).
    func advanceOnboarding(
        _ description: String,
        to next: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let outcome = next.map { Outcome.shows(onboardingStep($0)) } ?? Outcome.shows(app.tabBars)
        tapWhenEnabled(onboardingPrimaryButton, description, until: outcome, file: file, line: line)
    }

    /// Taps a picker option (a swatch, an emoji) until it is selected.
    func select(_ query: XCUIElementQuery, _ description: String, file: StaticString = #filePath, line: UInt = #line) {
        tap(query, description, until: .selects(query), file: file, line: line)
    }

    /// Best effort: closes the keyboard with its return key (the focused single-line field resigns).
    func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        app.typeText("\n")
        _ = waitUntil(timeout: UITestTimeout.short) { !app.keyboards.firstMatch.exists }
    }

    /// Waits for the groups list with the two demo groups (signed in as Camille).
    func waitForDemoGroups(file: StaticString = #filePath, line: UInt = #line) {
        waitForTabBar(file: file, line: line)
        waitForContent(elements(AccessibilityID.Groups.row(UITestDemo.lilasGroup)), UITestDemo.lilasGroup, file: file, line: line)
        waitForContent(elements(AccessibilityID.Groups.row(UITestDemo.sportGroup)), UITestDemo.sportGroup, file: file, line: line)
    }

    /// Opens a group from the groups list and waits until its screen is loaded (« + » shown).
    func openGroup(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        tapRow(
            AccessibilityID.Groups.row(name), "the group « \(name) »", until: .shows(addTaskButton),
            file: file, line: line
        )
        waitForContent(addTaskButton, "the « + » button of « \(name) »", file: file, line: line)
    }

    /// The title of a task row of the shown list whose title starts with `prefix` (the title as saved, whatever the
    /// keyboard corrected once the field was read), nil when none shows up within `timeout`.
    func taskTitle(startingWith prefix: String, timeout: TimeInterval = UITestTimeout.medium) -> String? {
        let rowPrefix = AccessibilityID.Tasks.row("")
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", rowPrefix + prefix))
        guard rows.firstMatch.waitForExistence(timeout: timeout) else { return nil }
        return currentMatches(rows, reachability: false).first.map { String($0.identifier.dropFirst(rowPrefix.count)) }
    }

    /// Opens a task from the group screen and waits for its detail.
    func openTask(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let detailTitle = elements(AccessibilityID.Tasks.detailTitle)
        tapRow(AccessibilityID.Tasks.row(title), "the task « \(title) »", until: .shows(detailTitle), file: file, line: line)
        waitForText(title, of: detailTitle, timeout: UITestTimeout.long, file: file, line: line)
    }

    /// In the task editor: « Assigner à » → selects `name` → back to the editor.
    func assign(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        tapRow(
            AccessibilityID.Tasks.assigneesButton, "« Assigner à »",
            until: .shows(elements(AccessibilityID.Tasks.assigneeList)), file: file, line: line
        )
        let row = elements(AccessibilityID.Tasks.assigneeRow(name))
        tap(row, "the assignee « \(name) »", until: .selects(row), file: file, line: line)
        goBack(from: UITestScreen.assignees, file: file, line: line)
        waitForContent(elements(AccessibilityID.Tasks.assigneesButton), "the editor", file: file, line: line)
    }

    /// Best effort (screenshot polish): selects the segment `title` of the segmented picker `identifier`.
    func selectSegment(_ title: String, of identifier: String) {
        let control = app.segmentedControls.matching(identifier: identifier).firstMatch
        let byTitle = NSPredicate(format: "label == %@", title)
        let segment = control.exists ? control.buttons.matching(byTitle) : app.buttons.matching(byTitle)
        guard segment.firstMatch.waitForExistence(timeout: UITestTimeout.short) else { return }
        var match = settledMatch(segment, timeout: 3) { matches in matches.first { $0.reachable != nil } }
        if match == nil {
            scroll(.towardsBottom)
            match = settledMatch(segment, timeout: 3) { matches in matches.first { $0.reachable != nil } }
        }
        if let match {
            tap(match)
        }
    }

    /// Best effort (screenshot polish): turns the switch `identifier` on. Returns whether it is on.
    @discardableResult
    func switchOn(_ identifier: String) -> Bool {
        let toggles = app.switches.matching(identifier: identifier)
        guard toggles.firstMatch.waitForExistence(timeout: UITestTimeout.short) else { return false }
        if isSwitchedOn(toggles) {
            return true
        }
        var match = settledMatch(toggles, timeout: 3) { matches in matches.first { $0.reachable != nil } }
        if match == nil {
            scroll(.towardsBottom)
            match = settledMatch(toggles, timeout: 3) { matches in matches.first { $0.reachable != nil } }
        }
        guard let toggle = match else { return false }
        // A SwiftUI Toggle's element spans the row: tap the switch itself, on the trailing side.
        tap(toggle, at: 0.9)
        if waitUntil(timeout: UITestTimeout.short, { isSwitchedOn(toggles) }) {
            return true
        }
        let inner = settledMatch(toggles.firstMatch.switches, timeout: 3) { matches in
            matches.first { $0.reachable != nil }
        }
        if let inner {
            tap(inner)
        }
        return waitUntil(timeout: UITestTimeout.short) { isSwitchedOn(toggles) }
    }

    // MARK: - Screenshots

    /// Attaches a screenshot of the whole screen, kept even when the test passes (the CI exports it by name).
    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    // MARK: - Matches (snapshots, never `isHittable`)

    /// One element of a query, read from a single snapshot.
    private struct Match {
        let element: XCUIElement
        let elementType: UInt
        let identifier: String
        let label: String
        let value: String?
        let placeholder: String?
        let isEnabled: Bool
        let isSelected: Bool
        let frame: CGRect
        /// The part of `frame` inside the app window (nil: none, or an empty frame).
        let visible: CGRect?
        /// The part of `visible` a finger can reach: not under the keyboard or the tab bar (nil: none).
        let reachable: CGRect?

        var summary: String {
            var text = "type \(elementType) id '\(identifier)' label '\(label)' frame \(frame)"
            if !isEnabled {
                text += " disabled"
            }
            if isSelected {
                text += " selected"
            }
            if reachable != nil {
                text += " reachable"
            } else if visible != nil {
                text += " covered"
            } else {
                text += " off screen"
            }
            return text
        }
    }

    /// The keyboard or the tab bar: what lies under it cannot be tapped, except its own elements (a tab button).
    private struct Obstruction {
        let frame: CGRect
        let ownFrames: [CGRect]
    }

    /// Elements whose bottom is this far above the bottom of the window are never under the keyboard (the tallest
    /// iPhone keyboard with its suggestion bar is about 390 points high) nor under the tab bar.
    private static let bottomBarsReach: CGFloat = 460

    /// Frame of the app window (the screen: portrait only), read once.
    private var windowFrame: CGRect {
        if let knownWindowFrame {
            return knownWindowFrame
        }
        // Reading `frame` never raises (unlike `isHittable`); `exists` first, as reading a missing element fails.
        // The larger of the application's frame (the screen) and its first window's: never a smaller secondary
        // window (keyboard, overlay) that would make everything else look off screen.
        var frame = app.frame
        let window = app.windows.firstMatch
        if window.exists {
            let first = window.frame
            if first.width * first.height > frame.width * frame.height {
                frame = first
            }
        }
        if frame.width >= 1, frame.height >= 1 {
            knownWindowFrame = frame
            return frame
        }
        // Not readable yet: the largest iPhone screen, not remembered.
        return CGRect(x: 0, y: 0, width: 440, height: 956)
    }

    /// Every element of `query` that still exists, in the query's order, with its visible and reachable parts.
    private func currentMatches(_ query: XCUIElementQuery, reachability: Bool = true) -> [Match] {
        let elements = query.allElementsBoundByIndex
        guard !elements.isEmpty else { return [] }
        // Read only when a match reaches the bottom of the screen (each read is one more snapshot).
        var obstructions: [Obstruction]?
        var matches: [Match] = []
        for element in elements {
            guard let snapshot = try? element.snapshot() else { continue }
            let frame = snapshot.frame
            let visible = visibleArea(of: frame)
            var reachable: CGRect?
            if reachability, let visible {
                if visible.maxY <= windowFrame.maxY - Self.bottomBarsReach {
                    reachable = visible
                } else {
                    let bars = obstructions ?? currentObstructions()
                    obstructions = bars
                    reachable = reachableArea(of: frame, visible: visible, obstructions: bars)
                }
            }
            matches.append(Match(
                element: element,
                elementType: snapshot.elementType.rawValue,
                identifier: snapshot.identifier,
                label: snapshot.label,
                value: snapshot.value as? String,
                placeholder: snapshot.placeholderValue,
                isEnabled: snapshot.isEnabled,
                isSelected: snapshot.isSelected,
                frame: frame,
                visible: visible,
                reachable: reachable
            ))
        }
        return matches
    }

    private func currentObstructions() -> [Obstruction] {
        var obstructions: [Obstruction] = []
        if let keyboard = try? app.keyboards.firstMatch.snapshot(), visibleArea(of: keyboard.frame) != nil {
            obstructions.append(Obstruction(frame: keyboardFrame(from: keyboard.frame), ownFrames: []))
        }
        // The tab bar, and the buttons a screen pins at its bottom (the onboarding's): the content scrolls under them.
        let bottomBars = app.tabBars.allElementsBoundByIndex
            + elements(AccessibilityID.Shell.pinnedBottomBar).allElementsBoundByIndex
        for bar in bottomBars {
            if let snapshot = try? bar.snapshot(), visibleArea(of: snapshot.frame) != nil {
                obstructions.append(Obstruction(frame: snapshot.frame, ownFrames: descendantFrames(of: snapshot)))
            }
        }
        return obstructions
    }

    /// The keyboard with what sits on top of it: its input assistant (the predictions or « Passwords » bar, in the
    /// keyboard's own window: `SystemInputAssistantView`, inside `inputView`) and the toolbar of the screen (the « OK »
    /// bar of the task editor), which may be a separate element touching it or floating a few points above. A tap
    /// there would hit the bar, not what lies under it (it did: the « Passwords » bar took the taps meant for
    /// « Créer mon compte » and for the e-mail field of the sign-up screen).
    private func keyboardFrame(from keyboard: CGRect) -> CGRect {
        var frame = keyboard
        let assistants = elements("SystemInputAssistantView").allElementsBoundByIndex
            + elements("inputView").allElementsBoundByIndex
        for assistant in assistants {
            guard let snapshot = try? assistant.snapshot() else { continue }
            let area = snapshot.frame
            let touchesKeyboard = area.maxY >= frame.minY - 12 && area.minY < frame.maxY
            if area.width >= 1, area.height >= 1, touchesKeyboard, area.minX < frame.maxX, area.maxX > frame.minX {
                frame = frame.union(area)
            }
        }
        for toolbar in app.toolbars.allElementsBoundByIndex {
            guard let snapshot = try? toolbar.snapshot() else { continue }
            let bar = snapshot.frame
            let isOnTop = bar.minY < frame.minY && bar.maxY >= frame.minY - 12
            if bar.width >= 1, bar.height >= 1, isOnTop, bar.minX < frame.maxX, bar.maxX > frame.minX {
                frame = frame.union(bar)
            }
        }
        return frame
    }

    private func descendantFrames(of snapshot: any XCUIElementSnapshot) -> [CGRect] {
        snapshot.children.flatMap { child in [child.frame] + descendantFrames(of: child) }
    }

    private func visibleArea(of frame: CGRect) -> CGRect? {
        guard frame.width >= 1, frame.height >= 1 else { return nil }
        let area = frame.intersection(windowFrame)
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        return area
    }

    private func reachableArea(of frame: CGRect, visible: CGRect?, obstructions: [Obstruction]) -> CGRect? {
        guard var area = visible else { return nil }
        for obstruction in obstructions where !obstruction.ownFrames.contains(where: { $0.isClose(to: frame) }) {
            guard area.intersects(obstruction.frame) else { continue }
            // The keyboard and the tab bar are at the bottom of the screen: keep what is above them.
            let bottom = min(area.maxY, obstruction.frame.minY)
            guard bottom - area.minY >= 1 else { return nil }
            area = CGRect(x: area.minX, y: area.minY, width: area.width, height: bottom - area.minY)
        }
        return area
    }

    private func isOnScreen(_ query: XCUIElementQuery) -> Bool {
        currentMatches(query, reachability: false).contains { $0.visible != nil }
    }

    /// Among the reachable (and, with `enabledOnly`, enabled) matches: the widest, or the next copy at each attempt.
    private func pick(_ matches: [Match], attempt: Int, widest: Bool, enabledOnly: Bool) -> Match? {
        let candidates = matches.filter { $0.reachable != nil && (!enabledOnly || $0.isEnabled) }
        guard !candidates.isEmpty else { return nil }
        if widest {
            return candidates.max { $0.frame.width < $1.frame.width }
        }
        return candidates[attempt % candidates.count]
    }

    /// The match `choose` picks, once its frame is the same in two consecutive polls; nil after `timeout`.
    /// A candidate always gets its second look, even past the deadline: near the bottom of the screen one poll reads
    /// the keyboard, tab bar and toolbars too, and can outlast a short timeout on a CI simulator (it did: 4–5 s
    /// polls made every `settledMatch(timeout: 3)` after a scroll return nil although the element was reachable).
    private func settledMatch(
        _ query: XCUIElementQuery,
        timeout: TimeInterval,
        reachability: Bool = true,
        choose: ([Match]) -> Match?
    ) -> Match? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFrame: CGRect?
        while true {
            let found = choose(currentMatches(query, reachability: reachability))
            if let match = found, let settledFrom = lastFrame, match.frame.isClose(to: settledFrom) {
                return match
            }
            let isFirstLookAtCandidate = found != nil && lastFrame == nil
            lastFrame = found?.frame
            if Date() >= deadline && !isFirstLookAtCandidate {
                return nil
            }
            pollingPause()
        }
    }

    /// Waits for an element of `query`, then scrolls until `choose` finds a settled match. Fails the test otherwise.
    private func revealMatch(
        _ query: XCUIElementQuery,
        _ description: String,
        timeout: TimeInterval,
        maxScrolls: Int = 6,
        choose: ([Match]) -> Match?,
        file: StaticString,
        line: UInt
    ) -> Match? {
        var scrolls = 0
        // The screen may still be loading; lazily built rows only exist once scrolled near.
        if !query.firstMatch.waitForExistence(timeout: timeout) {
            while scrolls < maxScrolls, !query.firstMatch.exists {
                scroll(.towardsBottom)
                scrolls += 1
                _ = query.firstMatch.waitForExistence(timeout: 2)
            }
        }
        // Several polls are needed (a settled frame is seen twice) and each one reads snapshots: not too short.
        if let match = settledMatch(query, timeout: UITestTimeout.short, choose: choose) {
            return match
        }
        while scrolls < maxScrolls {
            scroll(scrollDirection(towards: query))
            scrolls += 1
            if let match = settledMatch(query, timeout: 3, choose: choose) {
                return match
            }
        }
        fail("Could not bring \(description) on screen", showing: query, file: file, line: line)
        return nil
    }

    /// Towards the top only when the element is above the screen.
    private func scrollDirection(towards query: XCUIElementQuery) -> ScrollDirection {
        let frames = currentMatches(query, reachability: false)
            .map(\.frame)
            .filter { $0.width >= 1 && $0.height >= 1 }
        guard let frame = frames.first else { return .towardsBottom }
        return frame.maxY <= windowFrame.minY ? .towardsTop : .towardsBottom
    }

    private func performTap(
        _ query: XCUIElementQuery,
        _ description: String,
        timeout: TimeInterval,
        at dx: CGFloat = 0.5,
        widest: Bool = false,
        enabledOnly: Bool = false,
        until outcome: Outcome?,
        file: StaticString,
        line: UInt
    ) {
        let attempts = outcome == nil ? 1 : 3
        var taps = 0
        for attempt in 0..<attempts {
            if attempt > 0, let outcome {
                // A late effect: never tap again once it happened (a second tap would undo a selection, or land on
                // the new screen). When the element tapped left the screen (pushed away, covered by a new screen),
                // give the effect more time instead of tapping — or scrolling — on whatever replaced it.
                if hasHappened(outcome) {
                    return
                }
                if !isOnScreen(query) {
                    if happened(outcome, within: UITestTimeout.medium) {
                        return
                    }
                    break
                }
            }
            let revealed = revealMatch(
                query, description, timeout: attempt == 0 ? timeout : UITestTimeout.short,
                choose: { matches in pick(matches, attempt: attempt, widest: widest, enabledOnly: false) },
                file: file, line: line
            )
            guard var target = revealed else { return }
            if enabledOnly {
                let enabled = settledMatch(query, timeout: UITestTimeout.medium) { matches in
                    pick(matches, attempt: attempt, widest: widest, enabledOnly: true)
                }
                guard let enabledTarget = enabled else {
                    fail("\(description) stays disabled", showing: query, file: file, line: line)
                    return
                }
                target = enabledTarget
            }
            tap(target, at: dx)
            taps += 1
            guard let outcome else { return }
            if happened(outcome, within: UITestTimeout.short) {
                return
            }
        }
        if let outcome {
            fail(
                "Tapping \(description) (\(taps) tap(s)) had no effect: \(summary(of: outcome))",
                showing: query, file: file, line: line
            )
        }
    }

    /// Whether `outcome` holds now (one check, no wait).
    private func hasHappened(_ outcome: Outcome) -> Bool {
        switch outcome {
        case let .shows(query):
            return query.firstMatch.exists
        case let .hides(query):
            return !isOnScreen(query)
        case let .selects(query):
            return currentMatches(query, reachability: false).contains { $0.isSelected }
        }
    }

    private func happened(_ outcome: Outcome, within timeout: TimeInterval) -> Bool {
        if case let .shows(query) = outcome {
            return query.firstMatch.waitForExistence(timeout: timeout)
        }
        return waitUntil(timeout: timeout) { hasHappened(outcome) }
    }

    private func summary(of outcome: Outcome) -> String {
        switch outcome {
        case let .shows(query):
            return "nothing showed up for \(query.debugDescription)"
        case let .hides(query):
            return "still shown: \(query.debugDescription)"
        case let .selects(query):
            return "not selected: \(query.debugDescription)"
        }
    }

    /// Taps inside `match`: at `dx` of its width (kept inside the reachable part) and in the middle of the reachable
    /// part's height; the element's center when it is wholly reachable. `onTop`: the element is drawn above the
    /// keyboard and the tab bar (alert, dialog), its whole visible part counts.
    private func tap(_ match: Match, at dx: CGFloat = 0.5, onTop: Bool = false) {
        guard let area = onTop ? match.visible : match.reachable else { return }
        let frame = match.frame
        let x = area.width >= 2 ? min(max(frame.minX + frame.width * dx, area.minX + 1), area.maxX - 1) : area.midX
        let y = area.midY
        waitForSystemBanners(before: y)
        let offset = CGVector(dx: (x - frame.minX) / frame.width, dy: (y - frame.minY) / frame.height)
        match.element.coordinate(withNormalizedOffset: offset).tap()
    }

    /// A system notification banner covers the top of the screen for a few seconds, and a tap there would open it:
    /// before tapping near the top, waits (bounded) until no banner is shown.
    private func waitForSystemBanners(before y: CGFloat) {
        guard y < windowFrame.minY + 200 else { return }
        let banners = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR identifier == %@", "NotificationShortLookView", "BannerNotification")
        )
        // Only a banner on screen blocks (SpringBoard may keep off-screen copies, e.g. in the notification center).
        guard banners.firstMatch.exists else { return }
        _ = waitUntil(timeout: UITestTimeout.medium) { !isOnScreen(banners) }
    }

    private func confirmationButton(
        _ label: String,
        identifier: String,
        sourceIdentifier: String,
        sourceFrames: [CGRect]
    ) -> Match? {
        if let byIdentifier = currentMatches(buttons(identifier), reachability: false).first(where: { $0.visible != nil }) {
            return byIdentifier
        }
        let byLabel = currentMatches(app.buttons.matching(NSPredicate(format: "label == %@", label)), reachability: false)
        return byLabel.last { candidate in
            candidate.visible != nil
                && candidate.identifier != sourceIdentifier
                && !sourceFrames.contains { $0.isClose(to: candidate.frame) }
        }
    }

    private func isSwitchedOn(_ toggles: XCUIElementQuery) -> Bool {
        currentMatches(toggles, reachability: false).contains { $0.value == "1" }
    }

    // MARK: - Navigation bars

    private func navigationBars(titled title: String) -> XCUIElementQuery {
        app.navigationBars.matching(NSPredicate(format: "identifier == %@", title))
    }

    private func navigationTitleTexts(_ title: String) -> XCUIElementQuery {
        app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", title))
    }

    private func isShowingNavigationTitle(_ title: String) -> Bool {
        isOnScreen(navigationBars(titled: title)) || isOnScreen(navigationTitleTexts(title))
    }

    /// The back button of the bar titled `title`: « BackButton », else its leading button (never a trailing one such
    /// as « Tout retirer »); else the last reachable « BackButton » (a sheet's bar comes after the screen's).
    private func backButton(from title: String) -> Match? {
        let bar = navigationBars(titled: title).firstMatch
        if bar.exists {
            let back = currentMatches(bar.buttons.matching(identifier: "BackButton")).first { $0.reachable != nil }
            if let back {
                return back
            }
            let leading = currentMatches(bar.buttons).first { $0.reachable != nil }
            if let leading, let area = leading.reachable, area.midX < windowFrame.midX {
                return leading
            }
        }
        return currentMatches(app.navigationBars.buttons.matching(identifier: "BackButton")).last { $0.reachable != nil }
    }

    /// The interactive « back » gesture, from the leading edge.
    private func swipeBack() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    // MARK: - Polling and failures

    /// Polls `condition` until it returns a value, nil after `timeout` (short run-loop turns between two polls: not
    /// a blind wait for content).
    private func poll<T>(timeout: TimeInterval, _ condition: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let value = condition() {
                return value
            }
            if Date() >= deadline {
                return nil
            }
            pollingPause()
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        poll(timeout: timeout) { condition() ? true : nil } ?? false
    }

    private func pollingPause() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    /// Fails the test with what the query matches (frames, states), the window frame and any system alert, and
    /// attaches the app's element tree.
    private func fail(
        _ message: String,
        showing query: XCUIElementQuery? = nil,
        file: StaticString,
        line: UInt
    ) {
        var details = message
        if let query {
            let matches = currentMatches(query)
            if matches.isEmpty {
                details += " — no matching element"
            } else {
                details += " — matches: " + matches.map(\.summary).joined(separator: " | ")
            }
        }
        details += " — window \(windowFrame)"
        if let systemAlert = try? springboard.alerts.firstMatch.snapshot() {
            details += " — system alert shown: « \(systemAlert.label) »"
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "ui-hierarchy"
        hierarchy.lifetime = .keepAlways
        testCase.add(hierarchy)
        XCTFail(details, file: file, line: line)
    }
}

private extension CGRect {
    /// Same rectangle, give or take `tolerance` points on each coordinate.
    func isClose(to other: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
