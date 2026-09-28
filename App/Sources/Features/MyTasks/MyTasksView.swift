import SwiftUI
import TeamTasksCore

/// « Mes tâches » tab root (docs/DESIGN-V2.md §7.3): the date and the title, « Ta journée », then the tasks assigned to
/// the user in every group as `TaskRowCard`s (with their group's chip) in due-date sections (En retard in red,
/// Aujourd’hui, Cette semaine, Plus tard, Sans échéance, and Terminées — the last 30 days — when shown), and
/// « 2 tâches terminées aujourd’hui », which unfolds today's done tasks. A tap pushes `AppRoute.task(groupId:taskId:)`;
/// the round button of a card and its context menu change the status.
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

/// The header, « Ta journée », the sections and today's done tasks, with the loading, error and empty states.
private struct MyTasksList: View {
    @Bindable var model: MyTasksViewModel
    @State private var showsDoneToday = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Under the « Terminées » title: `MyTasksViewModel` reads the tasks done in the last 30 days.
    private static let doneSectionNote = "30 derniers jours"

    init(model: MyTasksViewModel) {
        self.model = model
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                header
                    .padding(.bottom, 6)
                content
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .accessibilityIdentifier(AccessibilityID.MyTasks.list)
        // The date and the big title are drawn by the screen (the date comes first, docs/DESIGN-V2.md §7.3): the bar
        // only holds the display options.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                optionsMenu
            }
        }
        .task(id: model.refreshKey) {
            await model.load()
        }
        // v3: the turns proposed to the user.
        .task(id: model.swapRequests.refreshKey) {
            await model.swapRequests.load()
        }
        .refreshable {
            await model.reload()
            await model.swapRequests.reload()
        }
        .onDisappear {
            // Only what was actually shown counts as seen.
            if model.loadState.isLoaded {
                model.markAllSeen()
            }
        }
        .onChange(of: model.tasks + model.doneTasks, initial: true) { _, shown in
            MyTasksHandoff.remember(shown, of: model.session)
        }
        .shellErrorAlert(model)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.todayText)
                .font(Font.subheadline.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
            Text(AppTab.myTasks.title)
                .font(.rounded(.largeTitle))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var optionsMenu: some View {
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .idle, .loading:
            ProgressView("Chargement…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        case let .failed(message):
            MyTasksFailureCard(message: message) {
                Task { await model.reload() }
            }
        case .loaded:
            MyTasksDayCard(summary: model.daySummary)
                .padding(.bottom, 6)
            if model.swapRequests.hasContent {
                TurnSwapRequestsList(model: model.swapRequests)
                    .padding(.bottom, 6)
            }
            if model.isEmpty {
                emptyCard
            }
            // One `ForEach` for the titles, the cards and « n tâches terminées aujourd’hui »: a card keeps its identity
            // when its task changes section (done: into « terminées aujourd’hui » or « Terminées »). A card moved from a
            // `ForEach` to another under the same id could stay drawn as it was, like on the group screen.
            ForEach(lines) { line in
                switch line {
                case let .title(section):
                    sectionTitle(section)
                case let .task(row):
                    taskRow(row)
                case let .doneToday(text):
                    doneTodayButton(text)
                }
            }
        }
    }

    /// The sections (title, then cards), then « n tâches terminées aujourd’hui » and, unfolded, today's done tasks (not
    /// while « Terminées » is shown: they are in that section).
    private var lines: [MyTasksLine] {
        var lines: [MyTasksLine] = []
        for section in model.sections {
            lines.append(.title(section))
            lines += section.rows.map(MyTasksLine.task)
        }
        if let text = model.doneTodayText, !model.includeDone {
            lines.append(.doneToday(text))
            if showsDoneToday {
                lines += model.doneTodayRows.map(MyTasksLine.task)
            }
        }
        return lines
    }

    private func sectionTitle(_ section: MyTasksSection) -> some View {
        SectionTitle(
            section.title,
            color: section.bucket == .overdue ? Theme.danger : nil,
            trailing: section.bucket == .done ? Self.doneSectionNote : nil
        )
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sectionAccessibilityLabel(section))
        .accessibilityAddTraits(.isHeader)
    }

    /// « En retard, 1 tâche », « Terminées, 30 derniers jours, 4 tâches ».
    private func sectionAccessibilityLabel(_ section: MyTasksSection) -> String {
        let count = FrenchText.count(section.rows.count, "tâche", "tâches")
        if section.bucket == .done {
            return "\(section.title), \(Self.doneSectionNote), \(count)"
        }
        return "\(section.title), \(count)"
    }

    /// A task card: the task on tap, the status cycle on its ring (the new status shows at once), the status on a long
    /// press.
    private func taskRow(_ row: TaskRow) -> some View {
        NavigationLink(value: AppRoute.task(groupId: row.task.groupId, taskId: row.id)) {
            TaskRowCard(row: row) {
                setStatus(row.status.next, for: row)
            }
        }
        .buttonStyle(.pressable)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
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
        .accessibilityIdentifier(AccessibilityID.Tasks.row(row.title))
    }

    // MARK: - Done today

    /// « 2 tâches terminées aujourd’hui »: unfolds today's done tasks under it (`lines`), or folds them.
    private func doneTodayButton(_ text: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) {
                showsDoneToday.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(Font.body.weight(.bold))
                    .accessibilityHidden(true)
                Text(text)
                    .font(Font.subheadline.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(Font.footnote.weight(.bold))
                    .rotationEffect(.degrees(showsDoneToday ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(SoftTone.done.foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(
                SoftTone.done.background,
                in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        }
        .buttonStyle(.pressable)
        .padding(.top, 8)
        .accessibilityValue(showsDoneToday ? "Affichées" : "Masquées")
        .accessibilityHint(showsDoneToday ? "Masque ces tâches." : "Affiche ces tâches.")
        .accessibilityIdentifier(AccessibilityID.MyTasks.doneTodayButton)
    }

    // MARK: - Empty

    private var emptyCard: some View {
        Card(padding: 24, spacing: 10, alignment: .center) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(MyTasksViewModel.emptyTitle)
                .font(.rounded(.title3))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(MyTasksViewModel.emptyMessage)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !model.includeDone {
                Button("Afficher les terminées") {
                    model.includeDone = true
                }
                .buttonStyle(SecondaryButtonStyle(isFullWidth: false))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.MyTasks.emptyState)
    }

    // MARK: - Actions

    private func setStatus(_ status: TaskStatus, for row: TaskRow) {
        Task {
            await model.setStatus(status, for: row.task)
        }
    }
}

/// A line of « Mes tâches »: a section's title, a task card, or « n tâches terminées aujourd’hui ».
private enum MyTasksLine: Identifiable {
    case title(MyTasksSection)
    case task(TaskRow)
    case doneToday(String)

    enum ID: Hashable {
        case title(DueBucket)
        case task(UUID)
        case doneToday
    }

    var id: ID {
        switch self {
        case let .title(section): .title(section.bucket)
        case let .task(row): .task(row.id)
        case .doneToday: .doneToday
        }
    }
}

/// « Impossible de charger tes tâches », the reason and « Réessayer ».
private struct MyTasksFailureCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        Card(padding: 20, spacing: 12, alignment: .center) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .accessibilityHidden(true)
            Text("Impossible de charger tes tâches")
                .font(.rounded(.title3))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Réessayer", action: retry)
                .buttonStyle(.primary)
                .accessibilityIdentifier(AccessibilityID.MyTasks.retryButton)
        }
    }
}
