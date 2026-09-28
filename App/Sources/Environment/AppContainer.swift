import Foundation
import TeamTasksCore

/// Process-wide owner of the root `AppModel`, created once at launch.
///
/// A singleton because three entry points need the same model: the SwiftUI scene (`TeamTasksApp`), the
/// notification delegate (`AppDelegate`, taps → `Router`) and the background refresh task, which can run when the
/// app was launched in the background and no view exists yet.
@MainActor
final class AppContainer {
    enum Launch {
        /// The backend is configured: the app runs with this model.
        case ready(AppModel, AppEnvironment)
        /// No usable Supabase settings: the « Configuration manquante » screen is shown.
        case misconfigured(ConfigurationIssue)
    }

    static let shared = AppContainer()

    let launch: Launch
    /// The per-device settings of « Réglages » (theme, effects, quiet hours, icon), in the launch's store.
    let preferences: DevicePreferences

    private init() {
        switch AppEnvironment.resolve() {
        case let .success(environment):
            let appModel = AppModel(services: environment.services, platform: environment.platform)
            launch = .ready(appModel, environment)
            preferences = DevicePreferences(store: environment.platform.store)
        case let .failure(issue):
            launch = .misconfigured(issue)
            preferences = DevicePreferences(store: UserDefaultsKeyValueStore())
        }
    }

    /// The root model, nil when the app is misconfigured.
    var appModel: AppModel? {
        if case let .ready(appModel, _) = launch { return appModel }
        return nil
    }

    /// The launch environment, nil when the app is misconfigured.
    var environment: AppEnvironment? {
        if case let .ready(_, environment) = launch { return environment }
        return nil
    }
}
