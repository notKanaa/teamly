import SwiftUI
import TeamTasksCore

/// Root of the « Groupes » tab (docs/DESIGN-V2.md §7.2): under the large title the summary (« 3 groupes · 11 tâches
/// à faire »), then a card per group, the pinned ones first, then the most recently active (`GroupCard`: tile, members,
/// the week's progress), and the dashed « Rejoindre un groupe » card. « + » opens a menu: « Créer un groupe »,
/// « Rejoindre un groupe ».
///
/// Shortcuts on a card (v3), also VoiceOver actions: swipe right « Épingler » / « Désépingler » (stored on this device,
/// `PinnedGroups`); swipe left « Supprimer » (admins) or « Quitter » (members), each confirmed by an alert; a long press
/// opens « Ouvrir », « Inviter » and « Apparence » (admins), « Épingler », « Quitter » or « Supprimer ».
///
/// The tab owns the `NavigationStack(path: $router.groupsPath)` and its
/// `.navigationDestination(for: AppRoute.self) { GroupsDestinationView(route: $0, session: session) }`;
/// cards push `AppRoute.group(id)`.
struct GroupsListView: View {
    let session: SessionModel

    @State private var model: GroupsListViewModel
    @State private var activeSheet: GroupsListSheet?
    /// The pinned groups, the most recently pinned first.
    @State private var pinnedIds: [UUID]
    /// The group whose « Quitter » / « Supprimer » waits for its confirmation.
    @State private var pendingRemoval: GroupSummary?
    @State private var appearanceEditor: GroupAppearanceViewModel?
    @Environment(AppModel.self) private var appModel

    init(session: SessionModel) {
        self.session = session
        _model = State(initialValue: GroupsListViewModel(session: session))
        _pinnedIds = State(initialValue: PinnedGroups(store: session.platform.store, userId: session.userId).load())
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
            case let .invite(groupId):
                InviteCodeSheet(session: session, groupId: groupId)
            }
        }
        .sheet(isPresented: isShowingAppearanceEditor) {
            if let appearanceEditor {
                GroupAppearanceSheet(model: appearanceEditor) { _ in
                    // The group's cards read the new look at the next load (the save bumped the group).
                }
            }
        }
        .alert(
            removalTitle,
            isPresented: isConfirmingRemoval,
            presenting: pendingRemoval
        ) { summary in
            if summary.myRole == .admin {
                Button("Supprimer", role: .destructive) {
                    remove(summary)
                }
                .accessibilityIdentifier(AccessibilityID.Shortcuts.groupDeleteConfirm)
            } else {
                Button("Quitter", role: .destructive) {
                    remove(summary)
                }
                .accessibilityIdentifier(AccessibilityID.Shortcuts.groupLeaveConfirm)
            }
            Button("Annuler", role: .cancel) {}
        } message: { summary in
            Text(removalMessage(summary))
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
            ForEach(PinnedGroups.sorted(model.groups, pinned: pinnedIds)) { summary in
                groupCard(summary)
            }
            JoinGroupCard {
                activeSheet = .join
            }
            .accessibilityIdentifier(AccessibilityID.Groups.joinButton)
        }
    }

    /// A group's card: the group on tap, the shortcuts on a swipe or a long press.
    private func groupCard(_ summary: GroupSummary) -> some View {
        let isPinned = pinnedIds.contains(summary.id)
        return NavigationLink(value: AppRoute.group(summary.id)) {
            GroupCard(summary: summary, overview: model.overview(of: summary.id))
                .overlay(alignment: .topTrailing) {
                    if isPinned {
                        pinBadge
                    }
                }
        }
        .buttonStyle(.pressable)
        .accessibilityValue(isPinned ? "Épinglé" : "")
        .accessibilityIdentifier(AccessibilityID.Groups.row(summary.group.name))
        .cardSwipeActions(
            leading: [pinAction(summary, isPinned: isPinned)],
            trailing: [removalAction(summary)],
            cornerRadius: Theme.Radius.card
        )
        .contextMenu {
            groupMenu(summary, isPinned: isPinned)
        }
    }

    /// A small pin on the corner of a pinned group's card.
    private var pinBadge: some View {
        Image(systemName: "pin.fill")
            .font(Font.caption2.weight(.heavy))
            .foregroundStyle(Theme.onFill)
            .frame(width: 22, height: 22)
            .background(Theme.accentFill, in: Circle())
            .offset(x: 4, y: -4)
            .accessibilityHidden(true)
    }

    // MARK: - Shortcuts

    private func pinAction(_ summary: GroupSummary, isPinned: Bool) -> CardSwipeAction {
        CardSwipeAction(
            isPinned ? "Désépingler" : "Épingler",
            systemImage: isPinned ? "pin.slash.fill" : "pin.fill",
            tint: ColorKey.amber.fill,
            identifier: AccessibilityID.Shortcuts.groupPin(summary.group.name)
        ) {
            setPinned(!isPinned, summary)
        }
    }

    private func removalAction(_ summary: GroupSummary) -> CardSwipeAction {
        let isAdmin = GroupPermissions.canDelete(role: summary.myRole)
        return CardSwipeAction(
            isAdmin ? "Supprimer" : "Quitter",
            systemImage: isAdmin ? "trash.fill" : "rectangle.portrait.and.arrow.right",
            tint: SoftTone.danger.fill,
            identifier: isAdmin
                ? AccessibilityID.Shortcuts.groupDelete(summary.group.name)
                : AccessibilityID.Shortcuts.groupLeave(summary.group.name)
        ) {
            pendingRemoval = summary
        }
    }

    /// The long-press menu of a card.
    @ViewBuilder
    private func groupMenu(_ summary: GroupSummary, isPinned: Bool) -> some View {
        Button {
            appModel.router.showGroup(summary.id)
        } label: {
            Label("Ouvrir", systemImage: "arrow.up.right.square")
        }
        .accessibilityIdentifier(AccessibilityID.Shortcuts.groupMenuOpen)
        if GroupPermissions.canSeeInviteCode(role: summary.myRole) {
            Button {
                activeSheet = .invite(summary.id)
            } label: {
                Label("Inviter", systemImage: "person.badge.plus")
            }
            .accessibilityIdentifier(AccessibilityID.Shortcuts.groupMenuInvite)
        }
        if GroupPermissions.canSetAppearance(role: summary.myRole) {
            Button {
                appearanceEditor = GroupAppearanceViewModel(session: session, group: summary.group)
            } label: {
                Label(GroupAppearanceViewModel.title, systemImage: "paintpalette")
            }
            .accessibilityIdentifier(AccessibilityID.Shortcuts.groupMenuAppearance)
        }
        Button {
            setPinned(!isPinned, summary)
        } label: {
            Label(isPinned ? "Désépingler" : "Épingler", systemImage: isPinned ? "pin.slash" : "pin")
        }
        .accessibilityIdentifier(AccessibilityID.Shortcuts.groupMenuPin)
        if GroupPermissions.canDelete(role: summary.myRole) {
            Button(role: .destructive) {
                pendingRemoval = summary
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
            .accessibilityIdentifier(AccessibilityID.Shortcuts.groupMenuDelete)
        } else {
            Button(role: .destructive) {
                pendingRemoval = summary
            } label: {
                Label("Quitter", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier(AccessibilityID.Shortcuts.groupMenuLeave)
        }
    }

    private func setPinned(_ isPinned: Bool, _ summary: GroupSummary) {
        let pinned = PinnedGroups(store: session.platform.store, userId: session.userId)
        withAnimation(.snappy) {
            pinnedIds = pinned.setPinned(isPinned, groupId: summary.id)
        }
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isShown in
                if !isShown {
                    pendingRemoval = nil
                }
            }
        )
    }

    private var removalTitle: String {
        guard let pendingRemoval else { return "" }
        return pendingRemoval.myRole == .admin ? "Supprimer le groupe\u{00A0}?" : "Quitter le groupe\u{00A0}?"
    }

    private func removalMessage(_ summary: GroupSummary) -> String {
        let name = FrenchText.quoted(summary.group.name)
        if summary.myRole == .admin {
            return "Le groupe \(name) et toutes ses tâches seront supprimés pour tous ses membres. Cette action est définitive."
        }
        return "Tu ne verras plus les tâches de \(name). Pour y revenir, il te faudra un nouveau code d’invitation."
    }

    /// Deletes the group (admins) or leaves it (members); the list reloads without it.
    private func remove(_ summary: GroupSummary) {
        let groups = session.services.groups
        let groupId = summary.id
        let isAdmin = summary.myRole == .admin
        Task {
            do {
                if isAdmin {
                    try await groups.deleteGroup(groupId: groupId)
                } else {
                    try await groups.leave(groupId: groupId)
                }
            } catch {
                model.error = ErrorState(from: error)
                return
            }
            if pinnedIds.contains(groupId) {
                setPinned(false, summary)
            }
            appModel.router.removeRoutes(forGroup: groupId)
            session.feed.bumpMemberships()
            session.feed.bumpMyTasks()
            session.feed.bump(groupId: groupId)
        }
    }

    private var isShowingAppearanceEditor: Binding<Bool> {
        Binding(
            get: { appearanceEditor != nil },
            set: { isShown in
                if !isShown {
                    appearanceEditor = nil
                }
            }
        )
    }

    // MARK: - Menu and empty state

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
private enum GroupsListSheet: Identifiable {
    case create
    case join
    /// The invite code of a group (admins, from the long-press menu).
    case invite(UUID)

    var id: String {
        switch self {
        case .create: "create"
        case .join: "join"
        case let .invite(groupId): "invite-\(groupId.uuidString)"
        }
    }
}
