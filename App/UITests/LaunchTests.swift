import XCTest

// Phase 0 smoke test — the screenshot and flow tests are added in phase 4.
final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestMockBackend", "-mockScenario", "signedOut"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
