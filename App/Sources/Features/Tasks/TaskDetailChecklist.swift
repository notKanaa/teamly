import SwiftUI
import TeamTasksCore

/// The « Checklist » card of the task screen (docs/DESIGN-V2.md §7.6), as rows of its `List` section: the title with
/// « 2 sur 5 » and a teal progress bar, the items with their 24 pt checkbox (a tap checks or unchecks, at once and rolled
/// back when the server refuses), « Ajouter un élément », and the checklist's message.
///
/// With `canManageChecklist` (admins, the creator, the assignees): a swipe or the context menu deletes an item, the
/// context menu renames it (`onRename`, an alert of the screen), and VoiceOver has both as actions. Otherwise the items
/// are shown, not editable.
struct TaskDetailChecklistRows: View {
    @Bindable var model: TaskDetailViewModel
    /// Opens the « Renommer » alert of the screen for this item.
    let onRename: (ChecklistItem) -> Void

    @FocusState private var isAddFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: TaskDetailViewModel, onRename: @escaping (ChecklistItem) -> Void) {
        self.model = model
        self.onRename = onRename
    }

    var body: some View {
        let checklist = model.checklist
        let hasError = model.checklistError != nil
        header
            .listRowSeparator(.hidden)
            .listRowInsets(TaskDetailInsets.checklistHeader)
        ForEach(checklist) { item in
            let isLast = item.id == checklist.last?.id && !model.canManageChecklist && !hasError
            itemRow(item)
                .listRowSeparator(.hidden)
                .listRowInsets(isLast ? TaskDetailInsets.checklistLast : TaskDetailInsets.checklistItem)
        }
        if model.canManageChecklist {
            addRow
                .listRowSeparator(.hidden)
                .listRowInsets(hasError ? TaskDetailInsets.checklistItem : TaskDetailInsets.checklistLast)
        }
        if let message = model.checklistError {
            TaskEditorErrorText(message: message)
                .font(.footnote)
                .listRowSeparator(.hidden)
                .listRowInsets(TaskDetailInsets.checklistLast)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                IconTile(systemImage: "checklist", tone: ColorKey.teal.tone)
                Text(TaskDetailViewModel.checklistTitle)
                    .font(.rounded(.title3, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let progress = model.checklistProgress {
                    Text(progress.text)
                        .font(Font.headline.weight(.heavy))
                        .foregroundStyle(ColorKey.teal.accent)
                        .monospacedDigit()
                        .accessibilityIdentifier(AccessibilityID.Tasks.checklistProgress)
                }
            }
            if let progress = model.checklistProgress {
                ProgressBar(value: progress.fraction, tint: ColorKey.teal.fill, track: ColorKey.teal.tone.background)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Items

    @ViewBuilder
    private func itemRow(_ item: ChecklistItem) -> some View {
        let isBusy = model.busyChecklistItemIds.contains(item.id)
        if model.canManageChecklist {
            Button {
                Task { await model.toggleChecklistItem(item.id) }
            } label: {
                itemLabel(item, isBusy: isBusy)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            // Checked items are « selected »: the checkbox itself is decorative.
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(item.isDone ? .isSelected : [])
            .accessibilityHint(item.isDone ? "Décocher l’élément" : "Cocher l’élément")
            .accessibilityActions {
                Button("Renommer") { onRename(item) }
                Button("Supprimer") { delete(item) }
            }
            .accessibilityIdentifier(AccessibilityID.Tasks.checklistItem(item.title))
            .contextMenu {
                Button {
                    onRename(item)
                } label: {
                    Label("Renommer", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    delete(item)
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    delete(item)
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            }
        } else {
            itemLabel(item, isBusy: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.isDone ? "Coché" : "Non coché")
                .accessibilityIdentifier(AccessibilityID.Tasks.checklistItem(item.title))
        }
    }

    private func itemLabel(_ item: ChecklistItem, isBusy: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ChecklistCheckbox(isDone: item.isDone)
            Text(item.title)
                .font(.body)
                .strikethrough(item.isDone)
                .foregroundStyle(item.isDone ? Theme.textSecondary : Theme.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .snappy, value: item.isDone)
    }

    // MARK: - Add

    private var addRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                if model.isAddingChecklistItem {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(Font.body.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)

            TextField(
                TaskDetailViewModel.addChecklistItemTitle,
                text: $model.newChecklistItemTitle,
                prompt: Text(TaskDetailViewModel.addChecklistItemTitle)
                    .foregroundStyle(Theme.accent)
                    .fontWeight(.semibold)
            )
            .submitLabel(.done)
            .focused($isAddFieldFocused)
            .onSubmit(add)
            .disabled(model.isAddingChecklistItem)
            .accessibilityIdentifier(AccessibilityID.Tasks.checklistAddField)

            if model.canAddChecklistItem {
                Button("Ajouter", action: add)
                    .font(Font.body.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.Tasks.checklistAddButton)
            }
        }
        .frame(minHeight: 44)
    }

    // MARK: - Actions

    private func add() {
        guard model.canAddChecklistItem else { return }
        Task {
            if await model.addChecklistItem() {
                // Ready for the next item.
                isAddFieldFocused = true
            }
        }
    }

    private func delete(_ item: ChecklistItem) {
        Task { await model.deleteChecklistItem(item.id) }
    }
}

/// The 24 pt rounded-square checkbox of a checklist item: a teal outline, or filled in teal with a white check when
/// done. Grows with Dynamic Type. Decorative (the row says whether the item is checked).
struct ChecklistCheckbox: View {
    let isDone: Bool

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 24

    init(isDone: Bool) {
        self.isDone = isDone
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side / 3, style: .continuous)
        ZStack {
            if isDone {
                shape.fill(ColorKey.teal.fill)
                Image(systemName: "checkmark")
                    .font(.system(size: side * 0.55, weight: .heavy))
                    .foregroundStyle(Theme.onFill)
            } else {
                shape.strokeBorder(ColorKey.teal.accent, lineWidth: 2)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
