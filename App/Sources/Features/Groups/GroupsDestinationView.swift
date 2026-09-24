import SwiftUI
import TeamTasksCore

/// Screen of a route pushed on the « Groupes » or « Mes tâches » tab (`MainTabView`):
/// `.navigationDestination(for: AppRoute.self) { route in GroupsDestinationView(route: route, session: session) }`.
struct GroupsDestinationView: View {
    let route: AppRoute
    let session: SessionModel

    var body: some View {
        // `.id(route)`: a different group or task always gets a fresh screen (and view model).
        switch route {
        case let .group(groupId):
            GroupDetailView(groupId: groupId, session: session)
                .id(route)
        case let .task(groupId, taskId):
            TaskDetailView(groupId: groupId, taskId: taskId, session: session)
                .id(route)
        case let .members(groupId):
            MembersView(groupId: groupId, session: session)
                .id(route)
        }
    }
}
