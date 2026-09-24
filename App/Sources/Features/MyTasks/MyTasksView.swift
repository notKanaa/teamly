import SwiftUI
import TeamTasksCore

/// « Mes tâches » tab root: the tasks assigned to the user in every group, in due-date sections (En retard,
/// Aujourd’hui, Cette semaine, Plus tard, Sans échéance, and Terminées when shown), with the group name, a « Nouveau »
/// badge and a quick status change. A tap pushes `AppRoute.task(groupId:taskId:)`.
///
/// No `NavigationStack` inside: the tab container provides it, bound to `Router.myTasksPath`, with
/// `.navigationDestination(for: AppRoute.self)` showing `TaskDetailView` for `.task` routes.
///
/// Model: the one given to `init(model:)`; otherwise the `MyTasksViewModel` of the environment when it belongs to the
/// same session (the tab container owns it for the live tab badge); otherwise its own.
struct MyTasksView: View {
    @Environment(MyTasksViewModel.self) private var environmentModel: MyTasksViewModel?
    @State private var ownModel: MyTasksViewModel
    private let usesGivenModel: Bool

    init(session: SessionModel) {
        _ownModel = State(initialValue: MyTasksViewModel(session: session))
        usesGivenModel = false
    }

    init(model: MyTasksViewModel) {
        _ownModel = State(initialValue: model)
        usesGivenModel = true
    }

    var body: some View {
        MyTasksList(model: model)
    }

    private var model: MyTasksViewModel {
        if !usesGivenModel, let environmentModel, environmentModel.session.id == ownModel.session.id {
            return environmentModel
        }
        return ownModel
    }
}

/// Sections of tasks, with the loading, error and empty states.
private struct MyTasksList: View {
    @Bindable var model: MyTasksViewModel

    var body: some View {
        List {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        taskRow(row)
                    }
                } header: {
                    MyTasksSectionHeader(section: section)
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier(AccessibilityID.MyTasks.list)
        .overlay {
            overlayContent
        }
        .navigationTitle(AppTab.myTasks.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $model.includeDone) {
                        Label("Afficher les terminées", systemImage: "checkmark.circle")
                    }
                    .accessibilityIdentifier(AccessibilityID.MyTasks.showDoneToggle)
                } label: {
                    Label("Options d’affichage", systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier(AccessibilityID.MyTasks.optionsMenu)
            }
        }
        .task(id: model.refreshKey) {
            await model.load()
        }
        .refreshable {
            await model.reload()
        }
        .onDisappear {
            // Only what was actually shown counts as seen.
            if model.loadState.isLoaded {
                model.markAllSeen()
            }
        }
        .alert("Erreur", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func taskRow(_ row: TaskRow) -> some View {
        NavigationLink(value: AppRoute.task(groupId: row.task.groupId, taskId: row.id)) {
            TasksRowView(row: row, isBusy: model.busyTaskIds.contains(row.id)) {
                setStatus(row.status.next, for: row)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Tasks.row(row.title))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if row.canChangeStatus {
                Button {
                    setStatus(row.status.next, for: row)
                } label: {
                    Label(row.status.next.label, systemImage: row.status.next.systemImage)
                }
                .tint(row.status.next.tasksTint)
            }
        }
        .contextMenu {
            if row.canChangeStatus {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Button {
                        setStatus(status, for: row)
                    } label: {
                        Label(status.label, systemImage: status.systemImage)
                    }
                    .disabled(status == row.status)
                }
            }
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch model.loadState {
        case .idle, .loading:
            if model.sections.isEmpty {
                ProgressView("Chargement…")
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Impossible de charger vos tâches", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Réessayer") {
                    Task { await model.reload() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AccessibilityID.MyTasks.retryButton)
            }
        case .loaded:
            if model.isEmpty {
                ContentUnavailableView {
                    Label(MyTasksViewModel.emptyTitle, systemImage: "checkmark.circle")
                } description: {
                    Text(MyTasksViewModel.emptyMessage)
                } actions: {
                    if !model.includeDone {
                        Button("Afficher les terminées") {
                            model.includeDone = true
                        }
                    }
                }
                .accessibilityIdentifier(AccessibilityID.MyTasks.emptyState)
            }
        }
    }

    private func setStatus(_ status: TaskStatus, for row: TaskRow) {
        Task {
            await model.setStatus(status, for: row.task)
        }
    }
}

/// « En retard  2 » — icon, title and number of tasks of a section (in red for overdue tasks).
private struct MyTasksSectionHeader: View {
    let section: MyTasksSection

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: section.bucket.tasksSystemImage)
            Text(section.title)
            Spacer()
            Text(section.rows.count, format: .number)
        }
        .textCase(nil)
        .foregroundStyle(section.bucket == .overdue ? Color.red : Color.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isHeader)
    }

    private var accessibilityText: String {
        let count = section.rows.count
        return "\(section.title), \(count) \(count > 1 ? "tâches" : "tâche")"
    }
}
