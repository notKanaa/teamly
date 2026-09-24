import SwiftUI
import TeamTasksCore

/// The signed-in app: « Groupes », « Mes tâches » (badge = new assignments) and « Réglages », each tab with its
/// own navigation stack driven by the `Router` (deep links, notification taps).
///
/// Environment provided to every screen below: `AppModel` and `Router` (from `RootView`), and `SessionModel`.
struct MainTabView: View {
    let session: SessionModel

    @Environment(AppModel.self) private var appModel
    /// Owned here (and handed to the « Mes tâches » screen) so that the tab badge stays live on every tab.
    @State private var myTasks: MyTasksViewModel

    init(session: SessionModel) {
        self.session = session
        _myTasks = State(initialValue: MyTasksViewModel(session: session))
    }

    var body: some View {
        @Bindable var router = appModel.router

        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.groupsPath) {
                GroupsListView(session: session)
                    .navigationDestination(for: AppRoute.self) { route in
                        GroupsDestinationView(route: route, session: session)
                    }
            }
            .tabItem {
                Label(AppTab.groups.title, systemImage: AppTab.groups.systemImage)
                    .accessibilityIdentifier(AccessibilityID.Tabs.groups)
            }
            .tag(AppTab.groups)

            // MyTasksView is the stack's root (no NavigationStack inside); it marks the « Nouveau » tasks as seen
            // when it disappears. Its rows push `.task` routes; the group screen may push `.members` here too.
            NavigationStack(path: $router.myTasksPath) {
                MyTasksView(model: myTasks)
                    .navigationDestination(for: AppRoute.self) { route in
                        GroupsDestinationView(route: route, session: session)
                    }
            }
            .tabItem {
                Label(AppTab.myTasks.title, systemImage: AppTab.myTasks.systemImage)
                    .accessibilityIdentifier(AccessibilityID.Tabs.myTasks)
            }
            .badge(myTasks.newCount)
            .tag(AppTab.myTasks)

            NavigationStack {
                SettingsView(session: session)
            }
            .tabItem {
                Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage)
                    .accessibilityIdentifier(AccessibilityID.Tabs.settings)
            }
            .tag(AppTab.settings)
        }
        .environment(session)
        // Keeps the badge current even before « Mes tâches » is opened (realtime signals, own changes, return to
        // foreground). `load()` is a no-op when the list is current.
        .task(id: myTasks.refreshKey) {
            await myTasks.load()
        }
        // Asks for the notification permission once, after sign-in (no-op once answered).
        .task {
            await session.requestNotificationAuthorizationIfNeeded()
        }
    }
}
