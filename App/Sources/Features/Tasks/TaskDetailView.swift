import SwiftUI
import TeamTasksCore

/// Task screen (docs/DESIGN-V2.md §7.6), pushed on a tab's `NavigationStack` for `AppRoute.task(groupId:taskId:)`:
/// - the group's chip (when « Mes tâches » handed the task over, see `MyTasksHandoff`), the title, « En retard » or
///   « Terminée … », and the status pill (admins, the creator and the assignees may change it);
/// - the info card: Échéance, Se répète (the rule and the next dates), À tour de rôle (the turn order, the current
///   turn ringed), Priorité, Assignée à; then who created the task and when;
/// - the Checklist card (`TaskDetailChecklistRows`), the notes, and « Supprimer la tâche ».
///
/// « Modifier » (sheet) and « Supprimer la tâche » for admins and the creator. Leaves the stack by itself when the task
/// disappears (deleted here or elsewhere, or no longer visible).
struct TaskDetailView: View {
    @Environment(AppModel.self) private var appModel: AppModel?
    @Environment(\.dismiss) private var dismiss
    @State private var model: TaskDetailViewModel
    @State private var editorItem: TaskDetailEditorItem?
    @State private var presentedEditor: TaskEditorViewModel?
    @State private var isConfirmingDelete = false
    @State private var pendingStatus: TaskStatus?
    @State private var hasLeft = false
    @State private var renamedItem: ChecklistItem?
    @State private var renamedTitle = ""

    /// - Parameter task: the task from the list, when known (shown before the first load completes). Without it, the
    ///   task « Mes tâches » showed, if any (it carries the group's name, color and emoji).
    init(groupId: UUID, taskId: UUID, session: SessionModel, task: TaskItem? = nil) {
        let handedOver = task ?? MyTasksHandoff.task(taskId, in: groupId, of: session)
        _model = State(
            initialValue: TaskDetailViewModel(session: session, groupId: groupId, taskId: taskId, task: handedOver)
        )
    }

    var body: some View {
        content
            .navigationTitle("Tâche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.loadState.isLoading && model.task != nil {
                        ProgressView()
                    } else if model.canEdit {
                        Button("Modifier") {
                            openEditor()
                        }
                        .fontWeight(.semibold)
                        .disabled(model.isWorking)
                        .accessibilityIdentifier(AccessibilityID.Tasks.editButton)
                    }
                }
            }
            .task(id: model.refreshKey) {
                await model.load()
            }
            .onChange(of: model.isGone, initial: true) { _, isGone in
                if isGone {
                    leave()
                }
            }
            .shellErrorAlert(model)
            .confirmationDialog(
                "Supprimer la tâche\u{00A0}?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Supprimer", role: .destructive) {
                    Task { await model.delete() }
                }
                .accessibilityIdentifier(AccessibilityID.Tasks.deleteConfirmButton)
                Button("Annuler", role: .cancel) {}
            } message: {
                Text(model.deleteConfirmationMessage)
            }
            .sheet(item: $editorItem, onDismiss: {
                editorDidDismiss()
            }) { item in
                TaskEditorView(model: item.model) { saved in
                    model.apply(saved)
                }
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let task = model.task {
            loadedList(task)
        } else if let message = model.loadState.failureMessage {
            ContentUnavailableView {
                Label("Impossible d’afficher la tâche", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Réessayer") {
                    Task { await model.reload() }
                }
                .buttonStyle(SecondaryButtonStyle(isFullWidth: false))
            }
        } else {
            ProgressView("Chargement…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadedList(_ task: TaskItem) -> some View {
        List {
            if let message = model.loadState.failureMessage {
                reloadSection(message)
            }
            headerSection(task)
            infoSection(task)
            if model.canManageChecklist || !model.checklist.isEmpty {
                Section {
                    TaskDetailChecklistRows(model: model) { item in
                        renamedTitle = item.title
                        renamedItem = item
                    }
                }
                .listRowBackground(Theme.card)
            }
            notesSection
            if model.canDelete {
                Section {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Supprimer la tâche", systemImage: "trash")
                            .foregroundStyle(Theme.danger)
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier(AccessibilityID.Tasks.deleteButton)
                }
                .listRowBackground(Theme.card)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await model.reload()
        }
        .alert("Renommer l’élément", isPresented: isRenaming, presenting: renamedItem) { item in
            TextField("Titre de l’élément", text: $renamedTitle)
            Button("Enregistrer") {
                let title = renamedTitle
                Task { await model.renameChecklistItem(item.id, to: title) }
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    // MARK: - Sections

    /// The task is shown (handed over by the list) but could not be loaded.
    private func reloadSection(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(Theme.textPrimary)
                Button("Réessayer") {
                    Task { await model.reload() }
                }
                .fontWeight(.semibold)
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Theme.card)
    }

    /// The group's chip, the title, « En retard » / « Terminée … », and the status, on the screen's ground.
    private func headerSection(_ task: TaskItem) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if let group = model.groupAppearance, let name = model.groupName {
                    Chip(group.emoji.map { "\($0) \(name)" } ?? name, tone: group.color.tone, weight: .bold)
                        .accessibilityLabel("Groupe \(name)")
                }
                Text(task.title)
                    .font(.rounded(.title))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AccessibilityID.Tasks.detailTitle)
                if model.isOverdue || model.completedText != nil {
                    FlowLayout(spacing: 8, lineSpacing: 6) {
                        if model.isOverdue {
                            Chip("En retard", systemImage: "exclamationmark.circle.fill", tone: .danger, weight: .bold)
                        }
                        if let completedText = model.completedText {
                            Chip(completedText, systemImage: "checkmark.seal.fill", tone: .done, weight: .bold)
                        }
                    }
                }
                statusPill(task)
                    .padding(.top, 4)
            }
            .padding(.bottom, 4)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
    }

    /// À faire / En cours / Terminée. It moves at once (`pendingStatus`) and back if the change fails; read-only for
    /// the others, with the reason.
    private func statusPill(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentedPill(
                model.statusOptions,
                selection: pendingStatus ?? task.status,
                title: { $0.label },
                tone: { .soft($0.tone) },
                identifier: { AccessibilityID.Tasks.statusOption($0.rawValue) }
            ) { status in
                change(to: status)
            }
            .disabled(!model.canChangeStatus || model.isWorking)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Statut")
            if !model.canChangeStatus && model.loadState.isLoaded {
                Text("Seuls les admins, le créateur de la tâche et les personnes assignées peuvent changer le statut.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func infoSection(_ task: TaskItem) -> some View {
        Section {
            TaskInfoRow("Échéance", systemImage: "calendar", tone: .accent) {
                TaskInfoValue(model.dueText ?? "Aucune", color: model.isOverdue ? Theme.danger : Theme.textPrimary)
            }
            if let recurrence = model.recurrenceText {
                TaskInfoRow("Se répète", systemImage: "arrow.triangle.2.circlepath", tone: ColorKey.coral.tone) {
                    TaskInfoValue(recurrence)
                } detail: {
                    upcomingDates
                }
                .accessibilityIdentifier(AccessibilityID.Tasks.recurrenceInfo)
            }
            if !model.rotationEntries.isEmpty {
                TaskInfoRow(TaskRow.rotationLabel, systemImage: "person.2.fill", tone: ColorKey.teal.tone) {
                    TaskRotationChain(entries: model.rotationEntries)
                } detail: {
                    if let rotationText = model.rotationText {
                        Text(rotationText)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Tasks.rotationInfo)
            }
            TaskInfoRow("Priorité", systemImage: "flag.fill", tone: task.priority.tone) {
                Chip(task.priority.label, tone: task.priority.tone, weight: .bold)
            }
            TaskInfoRow("Assignée à", systemImage: "person.fill", tone: ColorKey.blue.tone) {
                TaskAssigneesList(people: model.assignees)
            }
            .accessibilityIdentifier(AccessibilityID.Tasks.assigneesInfo)
        }
        .listRowBackground(Theme.card)
        .listRowInsets(TaskDetailInsets.infoRow)
    }

    /// « Prochaines fois », then the next due dates of a recurring task.
    @ViewBuilder
    private var upcomingDates: some View {
        let texts = model.upcomingDueTexts
        if !texts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(TaskDetailViewModel.upcomingTitle)
                    .font(Font.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                ForEach(texts, id: \.self) { text in
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var notesSection: some View {
        Section {
            if let details = model.details, !details.isEmpty {
                Text(details)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Aucune note.")
                    .foregroundStyle(Theme.textSecondary)
            }
        } header: {
            Text("Notes")
        } footer: {
            // « Créée par Lucas Bernard hier à 10:00 »: the v1 details, after the content.
            if let createdText = model.createdText {
                Text(createdText)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - Actions

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renamedItem != nil },
            set: { isShown in
                if !isShown {
                    renamedItem = nil
                }
            }
        )
    }

    private func change(to status: TaskStatus) {
        pendingStatus = status
        Task {
            await model.setStatus(status)
            pendingStatus = nil
        }
    }

    private func openEditor() {
        guard let editor = model.makeEditor() else { return }
        presentedEditor = editor
        editorItem = TaskDetailEditorItem(model: editor)
    }

    /// The editor found the task deleted: reload, which dismisses this screen too.
    private func editorDidDismiss() {
        if presentedEditor?.isGone == true {
            Task { await model.reload() }
        }
        presentedEditor = nil
    }

    /// Leaves the screen once: through the router when the task is on a tab's path, `dismiss()` otherwise.
    private func leave() {
        guard !hasLeft else { return }
        hasLeft = true
        editorItem = nil
        if let router = appModel?.router, isOnPath(of: router) {
            router.removeRoutes(forTask: model.taskId)
        } else {
            dismiss()
        }
    }

    private func isOnPath(of router: Router) -> Bool {
        let taskId = model.taskId
        let routes = router.groupsPath + router.myTasksPath
        return routes.contains { route in
            if case let .task(_, id) = route {
                return id == taskId
            }
            return false
        }
    }
}

/// Item of the « Modifier la tâche » sheet.
private struct TaskDetailEditorItem: Identifiable {
    let id = UUID()
    let model: TaskEditorViewModel
}
