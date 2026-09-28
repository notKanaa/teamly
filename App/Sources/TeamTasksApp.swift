import SwiftUI
import TeamTasksCore

/// « Teamly »: the backend is chosen once at launch (`AppContainer` / `AppEnvironment`), then `RootView` follows
/// `AppModel.phase`.
@main
struct TeamTasksApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppLaunchView(container: AppContainer.shared)
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await BackgroundRefresh.perform()
        }
    }
}

/// Configured app, or the « Configuration manquante » screen.
///
/// v3 (docs/CONTRACTS-V3.md §9): the theme chosen in Réglages › Apparence applies to the whole app, the haptics follow
/// « Vibrations », and the confetti of a completed task are drawn over everything.
private struct AppLaunchView: View {
    let container: AppContainer

    @State private var celebrations = CelebrationCenter()

    init(container: AppContainer) {
        self.container = container
    }

    var body: some View {
        let preferences = container.preferences
        switch container.launch {
        case let .ready(appModel, environment):
            Group {
                if environment.isMock && AppEnvironment.showsDesignGallery() {
                    // UI tests only (`-uiTestDesignGallery`): every component of the design system.
                    DesignGalleryView()
                } else {
                    RootView(appModel: appModel)
                }
            }
            .environment(\.isUITesting, environment.isMock)
            .environment(preferences)
            .environment(\.hapticsEnabled, preferences.isHapticsEnabled)
            .environment(\.celebrate, CelebrateAction { [celebrations] in
                if preferences.isConfettiEnabled {
                    celebrations.celebrate()
                }
            })
            .overlay {
                ConfettiBurst(trigger: celebrations.burst)
                    .ignoresSafeArea()
            }
            // UI tests only (`-uiTestColorScheme dark`): the design checks in dark mode; otherwise the chosen theme.
            .preferredColorScheme(forcedColorScheme(isMock: environment.isMock) ?? preferences.colorScheme)
        case let .misconfigured(issue):
            ShellConfigurationMissingView(issue: issue)
        }
    }

    private func forcedColorScheme(isMock: Bool) -> ColorScheme? {
        isMock ? AppEnvironment.forcedColorScheme() : nil
    }
}

extension AppEnvironment {
    static let designGalleryArgument = "-uiTestDesignGallery"
    static let colorSchemeArgument = "-uiTestColorScheme"

    /// `-uiTestDesignGallery`: the gallery of the design system instead of the app (with the mock backend only).
    static func showsDesignGallery(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(designGalleryArgument)
    }

    /// `-uiTestColorScheme <light|dark>`: the appearance forced by a UI test; nil (the system's) otherwise.
    static func forcedColorScheme(arguments: [String] = ProcessInfo.processInfo.arguments) -> ColorScheme? {
        guard let index = arguments.firstIndex(of: colorSchemeArgument), arguments.indices.contains(index + 1) else {
            return nil
        }
        switch arguments[index + 1] {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}
