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
        case let .misconfigured(issue):
            ShellConfigurationMissingView(issue: issue)
        }
    }
}
