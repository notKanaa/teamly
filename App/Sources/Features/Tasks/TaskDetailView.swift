import SwiftUI
import TeamTasksCore

/// Task screen, pushed on a tab's `NavigationStack` for `AppRoute.task(groupId:taskId:)`: title, description, status
/// (changeable by admins, the creator and the assignees), priority, due date, assignees, creator; « Modifier » (sheet)
/// and « Supprimer la tâche » for admins and the creator. Leaves the stack by itself when the task disappears
/// (deleted here or elsewhere, or no longer visible).
struct TaskDetailView: View {
    @Environment(AppModel.self) private var appModel: AppModel?
    @Environment(\.dismiss) private var dismiss
    @State private var model: TaskDetailViewModel
    @State private var editorItem: TaskDetailEditorItem?
    @State private var presentedEditor: TaskEditorViewModel?
    @State private var isConfirmingDelete = false
    @State private var pendingStatus: TaskStatus?
    @State private var hasLeft = false

    /// - Parameter task: the task from the list, when known (shown before the first load completes).
    init(groupId: UUID, taskId: UUID, session: SessionModel, task: TaskItem? = nil) {
        _model = State(initialValue: TaskDetailViewModel(session: session, groupId: groupId, taskId: taskId, task: task))
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
            .alert("Erreur", isPresented: $model.isShowingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .confirmationDialog(
                "Supprimer la tâche ?",
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
                .buttonStyle(.borderedProminent)
            }
        } else {
            ProgressView("Chargement…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadedList(_ task: TaskItem) -> some View {
        List {
            if let message = model.loadState.failureMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.orange)
                    Button("Réessayer") {
                        Task { await model.reload() }
                    }
                }
            }

            headerSection(task)
            descriptionSection
            statusSection(task)
            informationSection(task)
            assigneesSection

            if model.canDelete {
                Section {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Supprimer la tâche", systemImage: "trash")
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier(AccessibilityID.Tasks.deleteButton)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await model.reload()
        }
    }

    private func headerSection(_ task: TaskItem) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(task.title)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AccessibilityID.Tasks.detailTitle)
                if model.isOverdue {
                    Label("En retard", systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.red)
                }
                if let completedText = model.completedText {
                    Label(completedText, systemImage: "checkmark.seal.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.green)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var descriptionSection: some View {
        Section {
            if let details = model.details, !details.isEmpty {
                Text(details)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Aucune description.")
                    .foregroundStyle(Color.secondary)
            }
        } header: {
            Text("Description")
        }
    }

    @ViewBuilder
    private func statusSection(_ task: TaskItem) -> some View {
        if model.canChangeStatus {
            Section {
                TasksStatusPicker(
                    selection: pendingStatus ?? task.status,
                    options: model.statusOptions,
                    isBusy: model.isWorking
                ) { status in
                    change(to: status)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Statut")
            }
        } else {
            Section {
                LabeledContent("Statut") {
                    TasksStatusBadge(status: task.status)
                }
            } header: {
                Text("Statut")
            } footer: {
                if model.loadState.isLoaded {
                    Text("Seuls les administrateurs, le créateur de la tâche et les personnes assignées peuvent changer le statut.")
                }
            }
        }
    }

    private func informationSection(_ task: TaskItem) -> some View {
        Section {
            LabeledContent("Priorité") {
                TasksPriorityBadge(priority: task.priority)
            }
            LabeledContent("Échéance") {
                TasksDueDateLabel(text: model.dueText, isOverdue: model.isOverdue, showsPlaceholder: true)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Informations")
        } footer: {
            if let createdText = model.createdText {
                Text(createdText)
            }
        }
    }

    private var assigneesSection: some View {
        Section {
            if model.assigneeNames.isEmpty {
                Label(MemberDirectory.unassignedText, systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Color.secondary)
            } else {
                ForEach(Array(model.assigneeNames.enumerated()), id: \.offset) { item in
                    HStack(spacing: 12) {
                        TasksInitialsAvatar(name: item.element, size: 32)
                        Text(item.element)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Personnes assignées")
        }
    }

    // MARK: - Actions

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
