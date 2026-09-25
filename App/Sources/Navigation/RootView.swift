import Combine
import SwiftUI
import TeamTasksCore
import UIKit

/// Follows `AppModel.phase`: splash while the stored session is restored, authentication screens, the
/// « Nouveau mot de passe » screen of a password recovery, or the signed-in tabs (one `MainTabView` identity per
/// session, so nothing survives a change of account).
///
/// Also forwards the app events to the model: `equipe://` links, return to foreground, significant time change,
/// and requests the next background refresh when the app leaves the screen.
struct RootView: View {
    let appModel: AppModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var hasBeenInBackground = false

    var body: some View {
        ZStack {
            switch appModel.phase {
            case .launching:
                ShellSplashView()
                    .transition(.opacity)
            case .signedOut:
                AuthFlowView(appModel: appModel)
                    .transition(.opacity)
            case let .passwordRecovery(model):
                NavigationStack {
                    PasswordResetView(model: model)
                }
                .transition(.opacity)
            case let .signedIn(session):
                MainTabView(session: session)
                    .id(session.id)
                    .transition(.opacity)
            case let .onboarding(model):
                // v2 onboarding (docs/CONTRACTS-V2.md §9): its screens draw `model`; until they exist, the tabs of
                // the same session.
                MainTabView(session: model.session)
                    .id(model.session.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appModel.phase)
        .environment(appModel)
        .environment(appModel.router)
        .task {
            appModel.start()
        }
        .onOpenURL { url in
            _ = appModel.open(url: url)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                hasBeenInBackground = true
                BackgroundRefresh.schedule()
            case .active:
                // Only a real return from the background: the first activation at launch is covered by the
                // session's own start.
                guard hasBeenInBackground else { return }
                hasBeenInBackground = false
                Task {
                    await appModel.handleForeground()
                }
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            Task {
                await appModel.handleSignificantTimeChange()
            }
        }
    }
}
