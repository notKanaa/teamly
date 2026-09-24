import SwiftUI
import TeamTasksCore

/// Group screen: members and invite shortcuts, filter chips, the group's tasks (status, priority, due date,
/// assignees), « + » to create a task, and the options menu (sort, old done tasks, members, invite code, and for
/// admins rename / delete). Leaves the group's screens when the group is gone (deleted, left, removed).
struct GroupDetailView: View {
    let session: SessionModel

    @State private var model: GroupDetailViewModel
    @State private var editorRequest: GroupsEditorRequest?
    @State private var isShowingInviteCode = false
    @State private var isShowingRename = false
    @State private var renameText = ""
    @State private var isConfirmingGroupDeletion = false
    @State private var isConfirmingTaskDeletion = false
    @State private var taskPendingDeletion: TaskItem?
    @Environment(AppModel.self) private var appModel

    init(groupId: UUID, session: SessionModel) {
        self.session = session
        _model = State(initialValue: GroupDetailViewModel(session: session, groupId: groupId))
    }

    var body: some View {
        List {
            if model.loadState.isLoaded && !model.isGone {
                headerSection
                if !model.isEmpty {
                    filterSection
                }
                tasksSection
            }
        }
        .listSectionSpacing(.compact)
        .accessibilityIdentifier(AccessibilityID.Tasks.list)
        .overlay {
            overlay
        }
        .navigationTitle(model.title)
        .toolbar {
            toolbarContent
        }
        .task(id: model.refreshKey) {
            await model.load()
        }
        .refreshable {
            await model.reload()
        }
        .onChange(of: model.isGone, initial: true) { _, isGone in
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
        .alert("Erreur", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Sections

    /// Members (with their initials) and, for admins, the invite code.
    private var headerSection: some View {
        Section {
            NavigationLink(value: AppRoute.members(groupId: model.groupId)) {
                HStack(spacing: 12) {
                    GroupsAvatarStack(
                        people: model.members.map { GroupsAvatarStack.Person(id: $0.user.id, name: $0.user.displayName) },
                        maxVisible: 4,
                        size: 30
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Membres")
                            .font(.headline)
                        Text(membersSummary)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
            .accessibilityIdentifier(AccessibilityID.Groups.membersButton)
            if model.canSeeInviteCode {
                Button {
                    isShowingInviteCode = true
                } label: {
                    Label("Inviter avec un code", systemImage: "qrcode")
                }
                .accessibilityIdentifier(AccessibilityID.Groups.inviteButton)
            }
        }
    }

    private var filterSection: some View {
        Section {
            GroupsFilterChipBar(chips: model.filterChips) { kind in
                model.toggleFilterChip(kind)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var tasksSection: some View {
        let rows = model.rows
        Section {
            if rows.isEmpty {
                emptyTasks
                    .listRowBackground(Color.clear)
            } else {
                ForEach(rows) { row in
                    taskRow(row)
                }
            }
        } header: {
            if !model.tasks.isEmpty {
                Text(tasksHeader(shown: rows.count))
            }
        }
    }

    private var emptyTasks: some View {
        let hasNoTask = model.tasks.isEmpty
        return ContentUnavailableView {
            Label(hasNoTask ? Self.noTaskTitle : Self.noMatchTitle, systemImage: hasNoTask ? "checklist" : "line.3.horizontal.decrease.circle")
        } description: {
            Text(model.emptyRowsMessage)
        } actions: {
            if hasNoTask {
                if model.canCreateTask {
                    Button {
                        editorRequest = GroupsEditorRequest(mode: .create(groupId: model.groupId))
                    } label: {
                        Label("Nouvelle tâche", systemImage: "plus")
                    }
                    .shellProminentButtonStyle()
                    .accessibilityIdentifier(AccessibilityID.Groups.createFirstTaskButton)
                }
            } else if model.hasActiveFilter {
                Button("Réinitialiser les filtres") {
                    model.resetFilter()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.Groups.resetFilterButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Groups.emptyTasks)
    }

    private func taskRow(_ row: TaskRow) -> some View {
        NavigationLink(value: AppRoute.task(groupId: model.groupId, taskId: row.id)) {
            // The row of « Mes tâches », with the assignees' initials instead of the group name.
            TasksRowView(
                row: row,
                assignees: assignees(of: row.task),
                isBusy: model.busyTaskIds.contains(row.id),
                onToggleStatus: {
                    Task { await model.setStatus(row.status.next, for: row.task) }
                }
            )
        }
        // Same identifier as the rows of « Mes tâches ».
        .accessibilityIdentifier(AccessibilityID.Tasks.row(row.title))
        // Same leading swipe as « Mes tâches »: « Terminer » / « Rouvrir » (the status cycle is on the round button).
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if row.canChangeStatus {
                Button {
                    Task { await model.setStatus(row.isDone ? .todo : .done, for: row.task) }
                } label: {
                    if row.isDone {
                        Label("Rouvrir", systemImage: "arrow.uturn.backward")
                    } else {
                        Label("Terminer", systemImage: "checkmark")
                    }
                }
                .tint(row.isDone ? Color.orange : Color.green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if row.canDelete {
                Button {
                    requestDeletion(of: row.task)
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
                .tint(Color.red)
            }
            if row.canEdit {
                Button {
                    editorRequest = GroupsEditorRequest(mode: .edit(row.task))
                } label: {
                    Label("Modifier", systemImage: "pencil")
                }
                .tint(Color.blue)
            }
        }
        .contextMenu {
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
    }

    @ViewBuilder
    private var overlay: some View {
        if model.isGone {
            ContentUnavailableView(
                "Groupe indisponible",
                systemImage: "person.3",
                description: Text(GroupDetailViewModel.goneMessage)
            )
        } else if !model.loadState.isLoaded {
            GroupsLoadStateView(loadState: model.loadState) {
                Task { await model.reload() }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.loadState.isLoaded && !model.isGone {
                optionsMenu
                if model.canCreateTask {
                    Button {
                        editorRequest = GroupsEditorRequest(mode: .create(groupId: model.groupId))
                    } label: {
                        Label("Nouvelle tâche", systemImage: "plus")
                    }
                    .accessibilityIdentifier(AccessibilityID.Tasks.addButton)
                }
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
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
            Label("Options du groupe", systemImage: "ellipsis.circle")
        }
        .disabled(model.isUpdatingGroup)
        .accessibilityIdentifier(AccessibilityID.Groups.detailMenu)
    }

    // MARK: - Helpers

    private static let noTaskTitle = "Aucune tâche"
    private static let noMatchTitle = "Aucun résultat"

    /// « 3 membres · vous êtes admin ».
    private var membersSummary: String {
        let count = GroupsText.memberCount(model.members.count)
        switch model.myRole {
        case .some(.admin): return "\(count) · vous êtes admin"
        case .some(.member): return "\(count) · vous êtes membre"
        case .none: return count
        }
    }

    /// « 5 tâches », or « 2 tâches sur 5 » while a filter hides some.
    private func tasksHeader(shown: Int) -> String {
        let total = model.tasks.count
        if model.hasActiveFilter && shown != total {
            return "\(GroupsText.taskCount(shown)) sur \(total)"
        }
        return GroupsText.taskCount(shown)
    }

    /// Assignees of a task for the initials: the current user first, then by name (« ? » for a former member).
    private func assignees(of task: TaskItem) -> [GroupsAvatarStack.Person] {
        let me = session.userId
        let members = model.members
        let people = task.assigneeIds.map { userId in
            GroupsAvatarStack.Person(
                id: userId,
                name: members.first(where: { $0.user.id == userId })?.user.displayName ?? "?"
            )
        }
        return people.sorted { lhs, rhs in
            if lhs.id == me { return rhs.id != me }
            if rhs.id == me { return false }
            return NameOrder.precedes(lhs.name, rhs.name) ?? (lhs.id.uuidString < rhs.id.uuidString)
        }
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

/// A « Nouvelle tâche » / « Modifier la tâche » sheet to present.
private struct GroupsEditorRequest: Identifiable {
    let id = UUID()
    let mode: TaskEditorViewModel.Mode
}
