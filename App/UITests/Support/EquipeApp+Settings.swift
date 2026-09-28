import XCTest

// Helpers of the v3 « Réglages » and of the list shortcuts (swipe actions). They only build on the public helpers of
// EquipeApp.swift: queries by identifier, `reveal` (never `isHittable`), coordinate drags checked by their effect.

/// The side a card is swiped towards: `.right` reveals its leading actions, `.left` its trailing ones.
enum UITestSwipe {
    case right
    case left
}

@MainActor
extension EquipeApp {
    /// Opens « Réglages » and waits for the loaded profile (the name of the profile card).
    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        openTab(AccessibilityID.Tabs.settingsTitle, identifier: AccessibilityID.Tabs.settings, file: file, line: line)
        waitForContent(elements(AccessibilityID.Settings.profileName), "the loaded profile", file: file, line: line)
    }

    /// Swipes the card `identifier` towards `direction` (a controlled drag across most of its width, at mid-height,
    /// starting away from its status button) until an element of `outcome` shows (the revealed action). 3 tries.
    func swipeCard(
        _ identifier: String,
        _ description: String,
        towards direction: UITestSwipe,
        until outcome: XCUIElementQuery,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<3 {
            guard let card = reveal(elements(identifier), description, file: file, line: line) else { return }
            if outcome.firstMatch.exists {
                return
            }
            let from: CGFloat = direction == .right ? 0.25 : 0.8
            let to: CGFloat = direction == .right ? 0.9 : 0.1
            let start = card.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
            let end = card.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            if outcome.firstMatch.waitForExistence(timeout: UITestTimeout.short) {
                return
            }
        }
        XCTFail("Swiping \(description) revealed nothing: \(outcome.debugDescription)", file: file, line: line)
    }
}
