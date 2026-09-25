import SwiftUI
import TeamTasksCore

/// Root of the « Groupes » tab (docs/DESIGN-V2.md §7.2): under the large title the summary (« 3 groupes · 11 tâches
/// à faire »), then a card per group, most recently active first (`GroupCard`: tile, members, the week's progress),
/// and the dashed « Rejoindre un groupe » card. « + » opens a menu: « Créer un groupe », « Rejoindre un groupe ».
///
/// The tab owns the `NavigationStack(path: $router.groupsPath)` and its
/// `.navigationDestination(for: AppRoute.self) { GroupsDestinationView(route: $0, session: session) }`;
/// cards push `AppRoute.group(id)`.
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
        ScrollView {
            content
                .padding(.horizontal, Theme.Spacing.pageDense)
                .padding(.bottom, 24)
        }
        .accessibilityIdentifier(AccessibilityID.Groups.list)
        .navigationTitle("Groupes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                addMenu
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
        .shellErrorAlert(model)
    }

    @ViewBuilder private var content: some View {
        if model.isEmpty {
            emptyState
                .padding(.top, 32)
        } else if !model.loadState.isLoaded {
            GroupsLoadStateView(loadState: model.loadState) {
                Task { await model.reload() }
            }
            .padding(.top, 48)
        } else {
            cards
        }
    }

    private var cards: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if let header = model.headerText {
                Text(header)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.Groups.headerSummary)
            }
            ForEach(model.groups) { summary in
                NavigationLink(value: AppRoute.group(summary.id)) {
                    GroupCard(summary: summary, overview: model.overview(of: summary.id))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier(AccessibilityID.Groups.row(summary.group.name))
            }
            JoinGroupCard {
                activeSheet = .join
            }
            .accessibilityIdentifier(AccessibilityID.Groups.joinButton)
        }
    }

    /// « + »: « Créer un groupe », « Rejoindre un groupe ».
    private var addMenu: some View {
        Menu {
            Button {
                activeSheet = .create
            } label: {
                Label("Créer un groupe", systemImage: "plus")
            }
            .accessibilityIdentifier(AccessibilityID.Groups.createButton)
            Button {
                activeSheet = .join
            } label: {
                Label("Rejoindre un groupe", systemImage: "key.fill")
            }
            .accessibilityIdentifier(AccessibilityID.Groups.menuJoinButton)
        } label: {
            Label("Créer ou rejoindre un groupe", systemImage: "plus")
        }
        .accessibilityIdentifier(AccessibilityID.Groups.addMenu)
    }

    /// No group yet: « Créer un groupe » and « Rejoindre avec un code ».
    private var emptyState: some View {
        GroupsStateView(
            systemImage: "person.2.fill",
            title: GroupsListViewModel.emptyTitle,
            message: GroupsListViewModel.emptyMessage
        ) {
            PrimaryButton("Créer un groupe", systemImage: "plus") {
                activeSheet = .create
            }
            .accessibilityIdentifier(AccessibilityID.Groups.emptyCreateButton)
            Button {
                activeSheet = .join
            } label: {
                Label("Rejoindre avec un code", systemImage: "key.fill")
            }
            .buttonStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.Groups.emptyJoinButton)
        }
        .accessibilityIdentifier(AccessibilityID.Groups.emptyState)
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
