import SwiftUI
import TeamTasksCore

/// « Checklist » of a new task in the editor (docs/DESIGN-V2.md §7.7), as rows of its section: the items, each an
/// editable title (a swipe deletes it, a drag reorders), then « Ajouter un élément » and the checklist's message. The
/// items are checked on the task screen, once the task exists.
struct TaskEditorChecklistRows: View {
    @Bindable var model: TaskEditorViewModel
    let focusedField: FocusState<TaskEditorField?>.Binding

    init(model: TaskEditorViewModel, focusedField: FocusState<TaskEditorField?>.Binding) {
        self.model = model
        self.focusedField = focusedField
    }

    var body: some View {
        ForEach(model.checklistItems) { item in
            HStack(alignment: .center, spacing: 12) {
                ChecklistCheckbox(isDone: false)
                TextField("Élément", text: title(of: item))
                    .submitLabel(.done)
                    .accessibilityLabel("Élément de la checklist")
            }
            .frame(minHeight: 44)
        }
        .onDelete { offsets in
            let ids = offsets.compactMap { model.checklistItems.indices.contains($0) ? model.checklistItems[$0].id : nil }
            for id in ids {
                model.removeChecklistItem(id)
            }
        }
        .onMove { source, destination in
            model.moveChecklistItems(fromOffsets: source, toOffset: destination)
        }

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "plus")
                .font(Font.body.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            TextField(
                TaskEditorViewModel.addChecklistItemTitle,
                text: $model.newChecklistItemTitle,
                prompt: Text(TaskEditorViewModel.addChecklistItemTitle)
                    .foregroundStyle(Theme.accent)
                    .fontWeight(.semibold)
            )
            .submitLabel(.done)
            .focused(focusedField, equals: .newChecklistItem)
            .onSubmit(add)
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

        if let message = model.checklistError {
            TaskEditorErrorText(message: message)
                .font(.footnote)
        }
    }

    /// The title of a draft item, renamed as it is typed (checked on save).
    private func title(of item: ChecklistDraftItem) -> Binding<String> {
        Binding(
            get: { model.checklistItems.first { $0.id == item.id }?.title ?? item.title },
            set: { model.renameChecklistItem(item.id, to: $0) }
        )
    }

    private func add() {
        guard model.canAddChecklistItem else { return }
        if model.addChecklistItem() {
            // Ready for the next item.
            focusedField.wrappedValue = .newChecklistItem
        }
    }
}
