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
/// The switch folds the hero with one spring: its colored part shrinks to the bar, the tile shrinks and slides into
/// the bar's row, the name moves up to it, the members fold away, and the content (starting with the switch) follows
/// the hero's bottom. With Reduce Motion it is a quick crossfade.
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
    /// The tile and the name fly between the hero's identity and the compact bar.
    @Namespace private var heroNamespace
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
            .task(id: model.swapRequests.refreshKey) {
                await model.swapRequests.load()
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
                    .autocorrectionDisabled()
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
            // v3: « Relance envoyée à Inès ».
            .toast($model.toast)
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
                heroIdentity(appearance)
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
    }

    // MARK: - Hero

    /// The pinned top bar in the group's fill: back, then « Inviter » (admins) and « … ». On « Activité » it also shows
    /// the tile and the name, with rounded bottom corners; on « Tâches » it shows them (on one line) once the hero's
    /// identity has scrolled away (iOS 18). At accessibility text sizes the name of « Activité » gets its own line
    /// under the buttons, and « Tâches » keeps its buttons only.
    private func heroBar(_ appearance: AvatarAppearance) -> some View {
        let isActivity = model.tab == .activity
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let showsInlineTitle = !isLarge && (isActivity || isHeroCollapsed)
        let showsTitleLine = isLarge && isActivity
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                CircleIconButton(systemImage: "chevron.left", accessibilityLabel: "Retour", style: .translucent) {
                    dismiss()
                }
                .accessibilityIdentifier(AccessibilityID.Groups.backButton)
                if showsInlineTitle || showsTitleLine {
                    GroupTile(appearance, size: Self.compactTileSize, style: .onColor)
                        .matchedGeometryEffect(id: barMatch(.tile), in: heroNamespace, properties: .position)
                        .transition(barTransition(.tile))
                }
                if showsInlineTitle {
                    // On « Tâches » the name is already read in the hero's identity.
                    barTitle(appearance, isAccessible: isActivity)
                        .lineLimit(isActivity ? 2 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(barTransition(.title))
                } else {
                    Spacer(minLength: 0)
                    if model.canSeeInviteCode && !isActivity {
                        inviteButton(appearance)
                            .transition(.opacity)
                    }
                }
                optionsMenu
            }
            if showsTitleLine {
                barTitle(appearance, isAccessible: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(barTransition(.title))
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, 6)
        .padding(.bottom, isActivity ? 18 : 6)
        // A bar: large enough at the accessibility sizes, without taking the room of the content.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .background {
            UnevenRoundedRectangle(
                bottomLeadingRadius: isActivity ? 28 : 0,
                bottomTrailingRadius: isActivity ? 28 : 0,
                style: .continuous
            )
            .fill(appearance.color.fill)
            .ignoresSafeArea(edges: .top)
        }
        .animation(heroAnimation, value: showsInlineTitle)
    }

    /// The name in the bar (title3), which the identity's name (title2) flies to on « Activité ».
    private func barTitle(_ appearance: AvatarAppearance, isAccessible: Bool) -> some View {
        heroTitle(appearance, font: .rounded(.title3))
            .accessibilityHidden(!isAccessible)
            .matchedGeometryEffect(
                id: barMatch(.title), in: heroNamespace, properties: .position, anchor: .leading
            )
    }

    /// The white tile, the name and the members (a link to « Membres »), on the group's fill with rounded bottom
    /// corners. Its color reaches far above, so that pulling the content down never shows the ground.
    ///
    /// On « Activité » it folds to nothing, with the switch's spring: its colored bottom rises to the bar, which is then
    /// the compact hero; the tile and the name fly into the bar's row (`HeroMatch`), and the members fade, cut at the
    /// rising edge. « Tâches » unfolds it the same way back.
    private func heroIdentity(_ appearance: AvatarAppearance) -> some View {
        let isCompact = model.tab == .activity
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        return layout {
            if !isCompact {
                GroupTile(appearance, size: Self.identityTileSize, style: .onColor)
                    .matchedGeometryEffect(id: identityMatch(.tile), in: heroNamespace, properties: .position)
                    .transition(identityTransition(.tile))
            }
            VStack(alignment: .leading, spacing: 6) {
                if !isCompact {
                    heroTitle(appearance, font: .rounded(.title2))
                        .matchedGeometryEffect(
                            id: identityMatch(.title), in: heroNamespace, properties: .position, anchor: .leading
                        )
                        .transition(identityTransition(.title))
                    membersLink(appearance)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, isCompact ? 0 : 4)
        .padding(.bottom, isCompact ? 0 : 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        // What folds away is cut at the rising bottom edge; above it nothing is cut (the tile and the name fly up).
        .mask(alignment: .top) {
            Rectangle()
                .padding(.top, -Self.heroColorReach)
        }
        .background(alignment: .bottom) {
            UnevenRoundedRectangle(bottomLeadingRadius: 32, bottomTrailingRadius: 32, style: .continuous)
                .fill(appearance.color.fill)
                .padding(.top, -Self.heroColorReach)
        }
        .modifier(GroupHeroVisibilityTracker(isCollapsed: heroCollapsedBinding))
    }

    // MARK: - Hero motion

    /// The switch between the large hero (« Tâches ») and the compact one (« Activité »): one spring for the whole
    /// hero and the content under it; a quick crossfade with Reduce Motion (nothing flies then).
    private var heroAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.45, bounce: 0.12)
    }

    /// The tile: 64 pt in the identity, 40 pt in the bar. While it flies, each copy scales to the other one's size, so
    /// that the two look like one tile shrinking (or growing) on its way.
    private static let identityTileSize: CGFloat = 64
    private static let compactTileSize: CGFloat = 40
    /// The name: title2 in the identity, title3 in the bar (22 and 20 pt at the default size).
    private static let compactTitleScale: CGFloat = 20.0 / 22.0
    /// How far above the hero its color reaches (pulling the content down never shows the ground).
    private static let heroColorReach: CGFloat = 600

    /// A part of the hero that moves between the identity (« Tâches ») and the compact bar (« Activité »).
    private enum HeroPart: Hashable {
        case tile
        case title
    }

    /// The matched-geometry id of a copy of a part. `flight` is shared by the identity's copy and the bar's copy, so
    /// that the part flies from one to the other when the hero folds or unfolds; otherwise each copy has its own.
    private enum HeroMatch: Hashable {
        case flight(HeroPart)
        case identity(HeroPart)
        case bar(HeroPart)
    }

    /// The identity's copies fly only while the identity is on screen (not scrolled away) and motion is allowed.
    private func identityMatch(_ part: HeroPart) -> HeroMatch {
        !reduceMotion && !isHeroCollapsed ? .flight(part) : .identity(part)
    }

    /// The bar's copies fly only on « Activité »: on « Tâches » the bar shows them once the identity scrolled away,
    /// while the identity's copies are still there (off screen).
    private func barMatch(_ part: HeroPart) -> HeroMatch {
        !reduceMotion && model.tab == .activity ? .flight(part) : .bar(part)
    }

    /// The identity's copies scale to the bar's size as they leave (and from it as they come back).
    private func identityTransition(_ part: HeroPart) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        switch part {
        case .tile:
            return .scale(scale: Self.compactTileSize / Self.identityTileSize)
        case .title:
            return .scale(scale: Self.compactTitleScale, anchor: .leading).combined(with: .opacity)
        }
    }

    /// The bar's copies scale from the identity's size as they come (and to it as they leave); on « Tâches » (the
    /// identity scrolled away) they only fade.
    private func barTransition(_ part: HeroPart) -> AnyTransition {
        guard !reduceMotion, model.tab == .activity else { return .opacity }
        switch part {
        case .tile:
            return .scale(scale: Self.identityTileSize / Self.compactTileSize)
        case .title:
            return .scale(scale: 1 / Self.compactTitleScale, anchor: .leading).combined(with: .opacity)
        }
    }

    /// Whether the identity scrolled away (iOS 18). Folded on « Activité », the identity says nothing about the scroll
    /// of « Tâches »: its reports are ignored there.
    private var heroCollapsedBinding: Binding<Bool> {
        Binding(
            get: { isHeroCollapsed },
            set: { isCollapsed in
                if model.tab == .tasks {
                    isHeroCollapsed = isCollapsed
                }
            }
        )
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

    /// The members' avatars and « 3 membres · Tu es admin »: opens « Membres ». The avatars are ringed in white: one
    /// may have the group's own color.
    private func membersLink(_ appearance: AvatarAppearance) -> some View {
        // At accessibility text sizes the avatars go above the text, which then gets the whole width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        return NavigationLink(value: AppRoute.members(groupId: model.groupId)) {
            layout {
                AvatarStack(people: model.memberBadges, limit: 3, size: 26, surface: Color.white)
                HStack(alignment: .center, spacing: 8) {
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

    /// « Tâches » / « Activité »: the change folds or unfolds the hero, in one animation with the content.
    private var tabPill: some View {
        SegmentedPill(
            GroupDetailViewModel.Tab.allCases,
            selection: animatedTab,
            identifier: { AccessibilityID.Groups.tab($0.rawValue) }
        ) { tab in
            tab.label
        }
    }

    private var animatedTab: Binding<GroupDetailViewModel.Tab> {
        Binding(
            get: { model.tab },
            set: { tab in
                withAnimation(heroAnimation) {
                    model.tab = tab
                }
            }
        )
    }

    // MARK: - Tâches

    @ViewBuilder
    private func tasksContent(_ appearance: AvatarAppearance) -> some View {
        // v3: the turns proposed to the user in this group, « Accepter » / « Refuser ».
        if model.swapRequests.hasContent {
            TurnSwapRequestsList(model: model.swapRequests)
        }
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
            // One `ForEach` for the cards and the « Terminées » title: a card keeps its identity when its task becomes
            // done and moves under the title. (With a `ForEach` for each part, the card moved from one to the other
            // under the same id, and the lazy stack kept showing the old card, spinner included, until the screen was
            // left.)
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(GroupTaskLine.lines(rows)) { line in
                    switch line {
                    case let .task(row):
                        taskCard(row, tint: appearance.color.accent)
                    case .doneTitle:
                        SectionTitle(TaskStatusFilter.done.label)
                            .padding(.top, 10)
                    }
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

    /// A task card: the task on tap, the status cycle on its ring (the new status shows at once), the actions on a
    /// long press. Only a deletion in progress makes it busy.
    private func taskCard(_ row: TaskRow, tint: Color) -> some View {
        NavigationLink(value: AppRoute.task(groupId: model.groupId, taskId: row.id)) {
            TaskRowCard(row: row, tint: tint, isBusy: model.deletingTaskIds.contains(row.id)) {
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
        // v3: « Relancer Inès » on an overdue task assigned to someone else.
        if model.canNudge(row.task) {
            Button {
                Task { await model.nudge(row.task) }
            } label: {
                Label(model.nudgeTitle(for: row.task), systemImage: "bell.badge")
            }
            .disabled(model.nudgingTaskIds.contains(row.id))
            .accessibilityIdentifier(AccessibilityID.Social.nudgeMenuItem(row.title))
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

    /// The floating « + » of « Tâches » (not on « Activité »). It is not marked `Shell.pinnedBottomBar`: it stays in the
    /// accessibility tree behind the sheets, where the keyboard avoidance lifts it, and the UI-test helpers would then
    /// take the sheet's rows at its height for covered. Their taps land in the middle of the cards, away from it.
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

/// A line of the group's task list: a card, or the « Terminées » title before the done cards. What is left to do
/// comes first, then the done tasks, each part in the chosen order.
private enum GroupTaskLine: Identifiable {
    case task(TaskRow)
    case doneTitle

    enum ID: Hashable {
        case task(UUID)
        case doneTitle
    }

    var id: ID {
        switch self {
        case let .task(row): .task(row.id)
        case .doneTitle: .doneTitle
        }
    }

    /// The open rows, then « Terminées » (when both parts have rows) and the done rows.
    static func lines(_ rows: [TaskRow]) -> [GroupTaskLine] {
        let openRows = rows.filter { !$0.isDone }
        let doneRows = rows.filter(\.isDone)
        var lines = openRows.map(GroupTaskLine.task)
        if !openRows.isEmpty && !doneRows.isEmpty {
            lines.append(.doneTitle)
        }
        lines += doneRows.map(GroupTaskLine.task)
        return lines
    }
}

/// A « Nouvelle tâche » / « Modifier la tâche » sheet to present.
private struct GroupsEditorRequest: Identifiable {
    let id = UUID()
    let mode: TaskEditorViewModel.Mode
}
