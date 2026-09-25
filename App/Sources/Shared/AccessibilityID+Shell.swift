// Accessibility identifiers of the app shell (launch and configuration screens).
// The signed-in state is best detected with `app.tabBars.firstMatch` (see `AccessibilityID.Tabs`).
extension AccessibilityID {
    enum Shell {
        /// Splash screen shown while the stored session is restored.
        static let splash = "shell.splash"
        /// « Configuration manquante » screen (no Supabase settings in Info.plist).
        static let configurationMissing = "shell.configurationMissing"
        /// Buttons pinned at the bottom of a screen, over its scrolling content (the onboarding's): the UI tests treat
        /// them like the tab bar (what lies under them cannot be tapped).
        static let pinnedBottomBar = "shell.pinnedBottomBar"
    }
}
