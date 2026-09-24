import SwiftUI

private struct UITestingEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the app runs on the in-memory mock backend (`-uiTestMockBackend`). Screens use it to avoid
    /// system features that get in the way of UI tests (e.g. the « mot de passe fort » AutoFill overlay).
    var isUITesting: Bool {
        get { self[UITestingEnvironmentKey.self] }
        set { self[UITestingEnvironmentKey.self] = newValue }
    }
}
