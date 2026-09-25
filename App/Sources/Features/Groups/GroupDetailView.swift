import SwiftUI
import TeamTasksCore

/// Group screen (docs/DESIGN-V2.md §7.4, §7.5). A hero in the group's color: its top bar — back, « Inviter » (admins),
/// « … » — stays pinned while the rest scrolls under it; below it the white tile, the name and the members (they open
/// « Membres »). Then the « Tâches » / « Activité » switch:
/// - « Tâches »: « À qui le tour ? » (the rotating tasks), the filter chips with their counts, the task cards (tap:
///   the task; long press: its status, « Modifier », « Supprimer »), and the floating « + » (the task editor);
/// - « Activité » (`GroupActivityContent`): the week's recap and the feed; the hero is then compact (tile and name in
///   the pinned bar).
///
/// « … » holds the sort, the old done tasks, « Membres », the invite code, and for admins « Apparence » (the color and
/// emoji sheet), « Renommer » and « Supprimer ». The navigation bar is hidden (the edge swipe still goes back:
/// `GroupsSwipeBackEnabler`). Leaves the group's screens when the group is gone (deleted, left, removed).
struct GroupDetailView: View {
    let session: SessionModel

    @State private var model: GroupDetailViewModel
    @State private var editorRequest: GroupsEditorRequest?
    @State private var appearanceEditor: GroupAppearanceViewModel?
    @State private var isShowingInviteCode = false
    @State private var isShowingRename = false
    @State private var renameText = ""
    @State private var isConfirmingGroupDeletion = false
    @State private var isConfirmingTaskDeletion = false
    @State private var taskPendingDeletion: TaskItem?
    /// The hero's identity has scrolled away: the pinned bar shows the group's name.
    @State private var isHeroCollapsed = false
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(groupId: UUID, session: SessionModel) {
        self.session = session
        _model = State(initialValue: GroupDetailViewModel(session: session, groupId: groupId))
    }

    var body: some View {
        screen
            .navigationTitle(model.title)
            .toolbar(.hidden, for: .navigationBar)
            .background {
                GroupsSwipeBackEnabler()
            }
            .task(id: model.refreshKey) {
                await model.load()
            }
            .onChange(of: model.isGone, initial: true) { _, isGone in
                if isGone {
                    appModel.router.removeRoutes(forGroup: model.groupId)
                }
            }
            .onChange(of: model.activity.isGone) { _, isGone in
                if isGone {
                    appModel.router.removeRoutes(forGroup: model.groupId)
                }
            }
            .sheet(item: $editorRequest) { request in
                // The loaded members spare the assignee picker a request; the saved task shows at once.
                TaskEditorView(
                    mode: request.mode,
                    session: session,
                    members: model.members.isEmpty ? nil : model.members
                ) { saved in
                    model.apply(saved)
                }
            }
            .sheet(isPresented: $isShowingInviteCode) {
                InviteCodeSheet(session: session, groupId: model.groupId)
            }
            .sheet(isPresented: isShowingAppearanceEditor) {
                if let appearanceEditor {
                    GroupAppearanceSheet(model: appearanceEditor) { saved in
                        model.apply(group: saved)
                    }
                }
            }
            .alert("Renommer le groupe", isPresented: $isShowingRename) {
                TextField("Nom du groupe", text: $renameText)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier(AccessibilityID.Groups.renameField)
                Button("Annuler", role: .cancel) {}
                Button("Renommer") {
                    let name = renameText
                    Task { await model.rename(to: name) }
                }
                .accessibilityIdentifier(AccessibilityID.Groups.renameConfirmButton)
            } message: {
                Text("Le nouveau nom sera visible par tous les membres (\(CreateGroupViewModel.maxNameLength) caractères au maximum).")
            }
            .confirmationDialog("Supprimer le groupe\u{00A0}?", isPresented: $isConfirmingGroupDeletion, titleVisibility: .visible) {
                Button("Supprimer le groupe", role: .destructive) {
                    Task { await model.deleteGroup() }
                }
                .accessibilityIdentifier(AccessibilityID.Groups.deleteConfirmButton)
                Button("Annuler", role: .cancel) {}
            } message: {
                Text(model.deleteGroupConfirmationMessage)
            }
            .confirmationDialog(
                "Supprimer cette tâche\u{00A0}?",
                isPresented: $isConfirmingTaskDeletion,
                titleVisibility: .visible,
                presenting: taskPendingDeletion
            ) { task in
                Button("Supprimer la tâche", role: .destructive) {
                    Task { await model.delete(task) }
                }
                .accessibilityIdentifier(AccessibilityID.Groups.deleteTaskConfirmButton)
                Button("Annuler", role: .cancel) {}
            } message: { task in
                Text("«\u{00A0}\(task.title)\u{00A0}» sera supprimée pour tous les membres du groupe.")
            }
            .shellErrorAlert(model)
    }

    // MARK: - Screen

    @ViewBuilder private var screen: some View {
        if let appearance = model.appearance, model.loadState.isLoaded, !model.isGone {
            loadedScreen(appearance)
        } else {
            placeholderScreen
        }
    }

    /// Before the first load (or when it failed, or when the group is gone): a plain back button and the state.
    private var placeholderScreen: some View {
        ScrollView {
            Group {
                if model.isGone {
                    GroupsStateView(
                        systemImage: "person.2.slash",
                        tone: .neutral,
                        title: "Groupe indisponible",
                        message: GroupDetailViewModel.goneMessage
                    )
                } else {
                    GroupsLoadStateView(loadState: model.loadState) {
                        Task { await model.reload() }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.top, 48)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                CircleIconButton(systemImage: "chevron.left", accessibilityLabel: "Retour") {
                    dismiss()
                }
                .accessibilityIdentifier(AccessibilityID.Groups.backButton)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, 6)
        }
    }

    private func loadedScreen(_ appearance: AvatarAppearance) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                if model.tab == .tasks {
                    heroIdentity(appearance)
                        .transition(.opacity)
                }
                VStack(alignment: .leading, spacing: 18) {
                    tabPill
                    switch model.tab {
                    case .tasks:
                        tasksContent(appearance)
                    case .activity:
                        GroupActivityContent(
                            model: model.activity,
                            groupId: model.groupId,
                            openableTaskIds: Set(model.tasks.map(\.id))
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Tasks.list)
        .refreshable {
            if model.tab == .activity {
                await model.activity.reload()
            } else {
                await model.reload()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            heroBar(appearance)
        }
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            addButton
        }
        .animation(reduceMotion ? nil : .snappy, value: model.tab)
    }

    // MARK: - Hero

    /// The pinned top bar in the group's fill: back, then « Inviter » (admins) and « … ». On « Activité » it also shows
    /// the tile and the name, with rounded bottom corners; on « Tâches » it shows them (on one line) once the hero's
    /// identity has scrolled away (iOS 18).
    private func heroBar(_ appearance: AvatarAppearance) -> some View {
        let isActivity = model.tab == .activity
        let showsTitle = isActivity || isHeroCollapsed
        return HStack(alignment: .center, spacing: 10) {
            CircleIconButton(systemImage: "chevron.left", accessibilityLabel: "Retour", style: .translucent) {
                dismiss()
            }
            .accessibilityIdentifier(AccessibilityID.Groups.backButton)
            if showsTitle {
                GroupTile(appearance, size: 40, style: .onColor)
                heroTitle(appearance, font: .rounded(.title3))
                    .lineLimit(isActivity ? nil : 1)
                    // On « Tâches » the name is already read in the hero's identity.
                    .accessibilityHidden(!isActivity)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
                if model.canSeeInviteCode {
                    inviteButton(appearance)
                }
            }
            optionsMenu
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, 6)
        .padding(.bottom, isActivity ? 18 : 6)
        .background {
            UnevenRoundedRectangle(
                bottomLeadingRadius: isActivity ? 28 : 0,
                bottomTrailingRadius: isActivity ? 28 : 0,
                style: .continuous
            )
            .fill(appearance.color.fill)
            .ignoresSafeArea(edges: .top)
        }
        .animation(reduceMotion ? nil : .snappy, value: showsTitle)
    }

    /// The white tile, the name and the members (a link to « Membres »), on the group's fill with rounded bottom
    /// corners. Its color reaches far above, so that pulling the content down never shows the ground.
    private func heroIdentity(_ appearance: AvatarAppearance) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        return layout {
            GroupTile(appearance, size: 64, style: .onColor)
            VStack(alignment: .leading, spacing: 6) {
                heroTitle(appearance, font: .rounded(.title2))
                membersLink(appearance)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, 4)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            UnevenRoundedRectangle(bottomLeadingRadius: 32, bottomTrailingRadius: 32, style: .continuous)
                .fill(appearance.color.fill)
                .padding(.top, -600)
        }
        .modifier(GroupHeroVisibilityTracker(isCollapsed: $isHeroCollapsed))
    }

    /// The group's name, white on its fill. Its value says the group's look (« 🏠, corail »).
    private func heroTitle(_ appearance: AvatarAppearance, font: Font) -> some View {
        Text(model.title)
            .font(font)
            .foregroundStyle(Theme.onFill)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(GroupAppearanceText.describe(appearance))
            .accessibilityIdentifier(AccessibilityID.Groups.detailTitle)
    }

    /// The members' avatars and « 3 membres · Tu es admin »: opens « Membres ».
    private func membersLink(_ appearance: AvatarAppearance) -> some View {
        NavigationLink(value: AppRoute.members(groupId: model.groupId)) {
            HStack(alignment: .center, spacing: 8) {
                AvatarStack(people: model.memberBadges, limit: 3, size: 26, surface: appearance.color.fill)
                Text(model.membersSummary)
                    .font(Font.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onFill)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right")
                    .font(Font.caption.weight(.heavy))
                    .foregroundStyle(Theme.onFill.opacity(0.85))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Membres, \(model.membersSummary)")
        .accessibilityHint("Affiche les membres du groupe")
        .accessibilityIdentifier(AccessibilityID.Groups.membersButton)
    }

    /// « Inviter »: a white capsule, its text in the group's fill (≥ 4.5:1 on white). Opens the invite code.
    private func inviteButton(_ appearance: AvatarAppearance) -> some View {
        Button {
            isShowingInviteCode = true
        } label: {
            Label("Inviter", systemImage: "person.badge.plus")
                .labelStyle(.titleAndIcon)
                .font(Font.subheadline.weight(.heavy))
                // A bar button: it grows with the text like the round buttons next to it, then the large content
                // viewer shows it (long press).
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(appearance.color.fill)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Color.white, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityShowsLargeContentViewer()
        .accessibilityLabel("Inviter avec un code")
        .accessibilityIdentifier(AccessibilityID.Groups.inviteButton)
    }

    /// « … »: the sort, the old done tasks, the filters; « Membres », the invite code, « Apparence », « Renommer »;
    /// « Supprimer le groupe ».
    private var optionsMenu: some View {
        Menu {
            Section {
                Picker(selection: $model.sort) {
                    ForEach(TaskSort.allCases) { sort in
                        Text(sort.label).tag(sort)
                    }
                } label: {
                    Label("Trier par", systemImage: "arrow.up.arrow.down")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier(AccessibilityID.Groups.sortPicker)
                Toggle(isOn: $model.includeOldDone) {
                    Label("Terminées depuis plus de 30 jours", systemImage: "archivebox")
                }
                .accessibilityIdentifier(AccessibilityID.Groups.includeOldDoneToggle)
                if model.hasActiveFilter {
                    Button {
                        model.resetFilter()
                    } label: {
                        Label("Réinitialiser les filtres", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            Section {
                Button {
                    showMembers()
                } label: {
                    Label("Membres", systemImage: "person.2")
                }
                .accessibilityIdentifier(AccessibilityID.Groups.menuMembersButton)
                if model.canSeeInviteCode {
                    Button {
                        isShowingInviteCode = true
                    } label: {
                        Label("Code d’invitation", systemImage: "qrcode")
                    }
                    .accessibilityIdentifier(AccessibilityID.Groups.menuInviteButton)
                }
                if model.canSetAppearance {
                    Button {
                        appearanceEditor = model.makeAppearanceEditor()
                    } label: {
                        Label(GroupAppearanceViewModel.title, systemImage: "paintpalette")
                    }
                    .accessibilityIdentifier(AccessibilityID.Groups.appearanceButton)
                }
                if model.canRename {
                    Button {
                        renameText = model.group?.name ?? model.title
                        isShowingRename = true
                    } label: {
                        Label("Renommer le groupe", systemImage: "pencil")
                    }
                    .accessibilityIdentifier(AccessibilityID.Groups.renameButton)
                }
            }
            if model.canDeleteGroup {
                Section {
                    Button(role: .destructive) {
                        isConfirmingGroupDeletion = true
                    } label: {
                        Label("Supprimer le groupe", systemImage: "trash")
                    }
                    .accessibilityIdentifier(AccessibilityID.Groups.deleteButton)
                }
            }
        } label: {
            GroupHeroCircleLabel(systemImage: "ellipsis")
        }
        .disabled(model.isUpdatingGroup)
        .accessibilityLabel("Options du groupe")
        .accessibilityIdentifier(AccessibilityID.Groups.detailMenu)
    }

    private var tabPill: some View {
        SegmentedPill(
            GroupDetailViewModel.Tab.allCases,
            selection: $model.tab,
            identifier: { AccessibilityID.Groups.tab($0.rawValue) }
        ) { tab in
            tab.label
        }
    }

    // MARK: - Tâches

    @ViewBuilder
    private func tasksContent(_ appearance: AvatarAppearance) -> some View {
        let turnCards = model.turnCards
        if !turnCards.isEmpty {
            turnSection(turnCards, tone: appearance.color.tone)
        }
        if !model.isEmpty {
            filterBar
        }
        let rows = model.rows
        if rows.isEmpty {
            emptyTasks
        } else {
            LazyVStack(spacing: 10) {
                ForEach(rows) { row in
                    taskCard(row, tint: appearance.color.accent)
                }
            }
        }
    }

    /// « À qui le tour ? »: the rotating tasks as horizontal cards, bleeding to the screen's edges.
    private func turnSection(_ cards: [TurnCard], tone: SoftTone) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(GroupDetailViewModel.turnCardsTitle, size: .large, trailing: model.turnCardsSubtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(cards) { card in
                        NavigationLink(value: AppRoute.task(groupId: model.groupId, taskId: card.id)) {
                            GroupTurnCardView(card: card, tone: tone)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier(AccessibilityID.Groups.turnCard(card.title))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .padding(.horizontal, -Theme.Spacing.page)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Groups.turnCards)
        }
    }

    /// The filter chips with their counts (« À faire · 4 »), scrolling sideways to the screen's edges.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.filterChips) { chip in
                    FilterChipButton(chip.countedLabel, isSelected: chip.isSelected) {
                        withAnimation(reduceMotion ? nil : .snappy) {
                            model.toggleFilterChip(chip.kind)
                        }
                    }
                    .accessibilityHint("Filtre de la liste des tâches")
                    .accessibilityIdentifier(AccessibilityID.Groups.filterChip(Self.filterKey(chip.kind)))
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
        }
        .scrollClipDisabled()
        .padding(.horizontal, -Theme.Spacing.page)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Tasks.filterPicker)
    }

    /// A task card: the task on tap, the status cycle on its ring, the actions on a long press.
    private func taskCard(_ row: TaskRow, tint: Color) -> some View {
        NavigationLink(value: AppRoute.task(groupId: model.groupId, taskId: row.id)) {
            TaskRowCard(row: row, tint: tint, isBusy: model.busyTaskIds.contains(row.id)) {
                Task { await model.setStatus(row.status.next, for: row.task) }
            }
        }
        .buttonStyle(.pressable)
        // Same identifier as the cards of « Mes tâches ».
        .accessibilityIdentifier(AccessibilityID.Tasks.row(row.title))
        .contextMenu {
            taskActions(row)
        }
    }

    @ViewBuilder
    private func taskActions(_ row: TaskRow) -> some View {
        if row.canChangeStatus {
            Section("Statut") {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Button {
                        Task { await model.setStatus(status, for: row.task) }
                    } label: {
                        Label(status.label, systemImage: status.systemImage)
                    }
                    .disabled(status == row.status)
                }
            }
        }
        if row.canEdit {
            Button {
                editorRequest = GroupsEditorRequest(mode: .edit(row.task))
            } label: {
                Label("Modifier", systemImage: "pencil")
            }
        }
        if row.canDelete {
            Button(role: .destructive) {
                requestDeletion(of: row.task)
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
    }

    /// No task at all (« Nouvelle tâche »), or none matching the filters (« Réinitialiser les filtres »).
    @ViewBuilder
    private var emptyTasks: some View {
        let hasNoTask = model.tasks.isEmpty
        GroupsStateView(
            systemImage: hasNoTask ? "checklist" : "line.3.horizontal.decrease.circle",
            title: hasNoTask ? Self.noTaskTitle : Self.noMatchTitle,
            message: model.emptyRowsMessage
        ) {
            if hasNoTask {
                if model.canCreateTask {
                    PrimaryButton("Nouvelle tâche", systemImage: "plus") {
                        editorRequest = GroupsEditorRequest(mode: .create(groupId: model.groupId))
                    }
                    .accessibilityIdentifier(AccessibilityID.Groups.createFirstTaskButton)
                }
            } else if model.hasActiveFilter {
                Button("Réinitialiser les filtres") {
                    withAnimation(reduceMotion ? nil : .snappy) {
                        model.resetFilter()
                    }
                }
                .buttonStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Groups.resetFilterButton)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Groups.emptyTasks)
    }

    /// The floating « + » of « Tâches » (not on « Activité »).
    @ViewBuilder
    private var addButton: some View {
        if model.tab == .tasks && model.canCreateTask {
            FloatingAddButton(accessibilityLabel: "Nouvelle tâche") {
                editorRequest = GroupsEditorRequest(mode: .create(groupId: model.groupId))
            }
            .accessibilityIdentifier(AccessibilityID.Tasks.addButton)
            .padding(.trailing, Theme.Spacing.page)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Helpers

    private static let noTaskTitle = "Aucune tâche"
    private static let noMatchTitle = "Aucun résultat"

    /// Stable identifier suffix of a filter chip.
    static func filterKey(_ kind: TaskFilterChip.Kind) -> String {
        switch kind {
        case let .status(status): status.rawValue
        case .assignedToMe: "assignedToMe"
        case .overdue: "overdue"
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

    private func requestDeletion(of task: TaskItem) {
        taskPendingDeletion = task
        isConfirmingTaskDeletion = true
    }

    /// Pushes the members screen on the stack showing this group.
    private func showMembers() {
        let route = AppRoute.members(groupId: model.groupId)
        let router = appModel.router
        if router.selectedTab == .myTasks {
            router.myTasksPath.append(route)
        } else {
            router.groupsPath.append(route)
        }
    }
}

/// The look of a `CircleIconButton` `.translucent` for a menu's label (the « … » of the group hero): a white 22 %
/// circle of 44 pt, growing with the text up to 60 pt, with a white symbol.
private struct GroupHeroCircleLabel: View {
    let systemImage: String

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    init(systemImage: String) {
        self.systemImage = systemImage
    }

    var body: some View {
        let diameter = min(max(44, side), 60)
        Image(systemName: systemImage)
            .font(Font.body.weight(.bold))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .foregroundStyle(Theme.onFill)
            .frame(width: diameter, height: diameter)
            .background(Color.white.opacity(0.22), in: Circle())
            .contentShape(Circle())
    }
}

/// Tells when the hero's identity (tile, name, members) has scrolled away under the pinned bar, on iOS 18 and later
/// (on iOS 17 the bar keeps its buttons only).
private struct GroupHeroVisibilityTracker: ViewModifier {
    @Binding var isCollapsed: Bool

    init(isCollapsed: Binding<Bool>) {
        _isCollapsed = isCollapsed
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.3) { isVisible in
                isCollapsed = !isVisible
            }
        } else {
            content
        }
    }
}

/// A « Nouvelle tâche » / « Modifier la tâche » sheet to present.
private struct GroupsEditorRequest: Identifiable {
    let id = UUID()
    let mode: TaskEditorViewModel.Mode
}
