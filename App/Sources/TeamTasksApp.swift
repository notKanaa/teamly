import SwiftUI
import TeamTasksCore

/// « Équipe »: the backend is chosen once at launch (`AppContainer` / `AppEnvironment`), then `RootView` follows
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
private struct AppLaunchView: View {
    let container: AppContainer

    var body: some View {
        switch container.launch {
        case let .ready(appModel, environment):
            RootView(appModel: appModel)
                .environment(\.isUITesting, environment.isMock)
                // UI tests only (`-uiTestColorScheme dark`): the design checks in dark mode.
                .preferredColorScheme(environment.isMock ? AppEnvironment.forcedColorScheme() : nil)
        case let .misconfigured(issue):
            ShellConfigurationMissingView(issue: issue)
        }
    }
}

extension AppEnvironment {
    static let colorSchemeArgument = "-uiTestColorScheme"

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
