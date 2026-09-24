import SwiftUI
import TeamTasksCore

/// Root of the « Groupes » tab: the groups of the user (most recently active first) with their role, and the
/// « Créer » / « Rejoindre » sheets.
///
/// The tab owns the `NavigationStack(path: $router.groupsPath)` and its
/// `.navigationDestination(for: AppRoute.self) { GroupsDestinationView(route: $0, session: session) }`;
/// rows push `AppRoute.group(id)`.
struct GroupsListView: View {
    let session: SessionModel

    @State private var model: GroupsListViewModel
    @State private var activeSheet: GroupsListSheet?
    @Environment(AppModel.self) private var appModel

    init(session: SessionModel) {
        self.session = session
        _model = State(initialValue: GroupsListViewModel(session: session))
    }

    var body: some View {
        let now = session.platform.now()
        List {
            ForEach(model.groups) { summary in
                NavigationLink(value: AppRoute.group(summary.id)) {
                    GroupsListRow(summary: summary, activityText: activityText(for: summary, now: now))
                }
                .accessibilityIdentifier(AccessibilityID.Groups.row(summary.group.name))
            }
        }
        .accessibilityIdentifier(AccessibilityID.Groups.list)
        .overlay {
            overlay
        }
        .navigationTitle("Groupes")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Rejoindre") {
                    activeSheet = .join
                }
                .accessibilityHint("Rejoindre un groupe avec un code d’invitation")
                .accessibilityIdentifier(AccessibilityID.Groups.joinButton)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    activeSheet = .create
                } label: {
                    Label("Créer", systemImage: "plus")
                }
                .accessibilityHint("Créer un nouveau groupe")
                .accessibilityIdentifier(AccessibilityID.Groups.createButton)
            }
        }
        .task(id: model.refreshKey) {
            await model.load()
        }
        .refreshable {
            await model.reload()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .create:
                CreateGroupSheet(session: session) { group in
                    openGroup(group.id)
                }
            case .join:
                JoinGroupSheet(session: session) { groupId in
                    openGroup(groupId)
                }
            }
        }
        .alert("Erreur", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if model.isEmpty {
            ContentUnavailableView {
                Label(GroupsListViewModel.emptyTitle, systemImage: "person.3")
            } description: {
                Text(GroupsListViewModel.emptyMessage)
            } actions: {
                Button {
                    activeSheet = .create
                } label: {
                    Label("Créer un groupe", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AccessibilityID.Groups.emptyCreateButton)
                Button {
                    activeSheet = .join
                } label: {
                    Label("Rejoindre avec un code", systemImage: "ticket")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.Groups.emptyJoinButton)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Groups.emptyState)
        } else if !model.loadState.isLoaded {
            GroupsLoadStateView(loadState: model.loadState) {
                Task { await model.reload() }
            }
        }
    }

    /// « Dernière activité : hier à 18:00 ».
    private func activityText(for summary: GroupSummary, now: Date) -> String {
        let when = DateText.relativeLowercase(summary.group.lastActivityAt, now: now, calendar: session.platform.calendar)
        return "Dernière activité\u{00A0}: \(when)"
    }

    /// A group was created or joined: close the sheet and show it.
    private func openGroup(_ groupId: UUID) {
        activeSheet = nil
        appModel.router.showGroup(groupId)
    }
}

/// Sheets of the groups list.
private enum GroupsListSheet: String, Identifiable {
    case create
    case join

    var id: String { rawValue }
}
