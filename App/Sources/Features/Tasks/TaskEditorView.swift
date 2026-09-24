import SwiftUI
import TeamTasksCore

/// « Nouvelle tâche » / « Modifier la tâche » sheet: title, description, priority, optional due date and assignees.
/// Embeds its own `NavigationStack`: present it with `.sheet`. Calls `onSaved` with the saved task, then dismisses.
///
///     .sheet(isPresented: $isCreatingTask) {
///         TaskEditorView(mode: .create(groupId: model.groupId), session: model.session, members: model.members) { task in
///             model.apply(task)
///         }
///     }
struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: TaskEditorViewModel
    @State private var isConfirmingDiscard = false
    @FocusState private var focusedField: TaskEditorField?
    private let onSaved: (TaskItem) -> Void

    /// - Parameters:
    ///   - mode: `.create(groupId:)` or `.edit(task)`.
    ///   - members: the group's members when already loaded (the assignee picker then needs no request).
    ///   - onSaved: called with the created or updated task, right before the sheet dismisses.
    init(
        mode: TaskEditorViewModel.Mode,
        session: SessionModel,
        members: [Membership]? = nil,
        onSaved: @escaping (TaskItem) -> Void = { _ in }
    ) {
        _model = State(initialValue: TaskEditorViewModel(session: session, mode: mode, members: members))
        self.onSaved = onSaved
    }

    /// Uses an editor built elsewhere (e.g. `TaskDetailViewModel.makeEditor()`).
    init(model: TaskEditorViewModel, onSaved: @escaping (TaskItem) -> Void = { _ in }) {
        _model = State(initialValue: model)
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                if isReadOnly {
                    Section {
                        Label("Vous ne pouvez pas modifier cette tâche.", systemImage: "lock.fill")
                            .foregroundStyle(Color.secondary)
                    }
                }
                Group {
                    titleSection
                    detailsSection
                    prioritySection
                    dueDateSection
                    assigneesSection
                }
                .disabled(areFieldsDisabled)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(model.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        cancel()
                    }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier(AccessibilityID.Tasks.cancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                            .accessibilityLabel("Enregistrement en cours")
                    } else {
                        Button(model.saveButtonTitle) {
                            save()
                        }
                        .fontWeight(.semibold)
                        .disabled(!model.canSave)
                        .accessibilityIdentifier(AccessibilityID.Tasks.saveButton)
                    }
                }
                // Return adds a line to the description: « OK » closes the keyboard, which otherwise hides
                // « Échéance » and « Assignation ».
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("OK") {
                        focusedField = nil
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Abandonner les modifications\u{00A0}?",
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Abandonner", role: .destructive) {
                    dismiss()
                }
                Button("Continuer la saisie", role: .cancel) {}
            } message: {
                Text("Les changements apportés à cette tâche seront perdus.")
            }
            .alert("Erreur", isPresented: $model.isShowingError) {
                Button("OK", role: .cancel) {
                    if model.isGone {
                        dismiss()
                    }
                }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(model.hasChanges || model.isSaving)
        .task {
            await model.load()
        }
        .onAppear {
            if !model.isEditing {
                focusedField = .title
            }
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        Section {
            TextField("Titre de la tâche", text: $model.title)
                .focused($focusedField, equals: .title)
                .submitLabel(.next)
                .onSubmit {
                    focusedField = .details
                }
                .accessibilityIdentifier(AccessibilityID.Tasks.titleField)
        } header: {
            Text("Titre")
        } footer: {
            if let message = model.titleError {
                TaskEditorErrorText(message: message)
            }
        }
    }

    private var detailsSection: some View {
        Section {
            TextField("Ajoutez des précisions (facultatif)", text: $model.details, axis: .vertical)
                .lineLimit(4...10)
                .focused($focusedField, equals: .details)
                .accessibilityIdentifier(AccessibilityID.Tasks.detailsField)
        } header: {
            Text("Description")
        } footer: {
            if let message = model.detailsError {
                TaskEditorErrorText(message: message)
            }
        }
    }

    private var prioritySection: some View {
        Section {
            Picker("Priorité", selection: $model.priority) {
                ForEach(TeamTasksCore.TaskPriority.pickerOrder, id: \.self) { priority in
                    Text(priority.label)
                        .tag(priority)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(AccessibilityID.Tasks.priorityPicker)
        } header: {
            Text("Priorité")
        }
    }

    private var dueDateSection: some View {
        Section {
            Toggle(isOn: $model.hasDueDate.animation()) {
                Label("Date d’échéance", systemImage: "calendar")
            }
            .accessibilityIdentifier(AccessibilityID.Tasks.dueDateToggle)

            if model.hasDueDate {
                DatePicker(
                    "Échéance",
                    selection: $model.dueDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .environment(\.locale, Locale(identifier: "fr_FR"))
                .environment(\.calendar, calendar)
                .environment(\.timeZone, calendar.timeZone)
                .accessibilityIdentifier(AccessibilityID.Tasks.dueDatePicker)
            }
        } header: {
            Text("Échéance")
        } footer: {
            if let message = model.dueDateError {
                TaskEditorErrorText(message: message)
            } else if model.hasDueDate {
                Text(dueDateSummary)
            }
        }
    }

    private var assigneesSection: some View {
        Section {
            switch model.loadState {
            case .loaded:
                NavigationLink {
                    TaskEditorAssigneePicker(model: model)
                } label: {
                    HStack(spacing: 12) {
                        Label("Assigner à", systemImage: "person.2")
                        Spacer(minLength: 8)
                        Text(model.assigneesSummary)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Tasks.assigneesButton)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.secondary)
                    Button("Réessayer") {
                        Task { await model.reload() }
                    }
                }
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Chargement des membres…")
                        .foregroundStyle(Color.secondary)
                }
            }
        } header: {
            Text("Assignation")
        } footer: {
            if let message = model.assigneesError {
                TaskEditorErrorText(message: message)
            }
        }
    }

    // MARK: - Helpers

    /// Members are loaded and the user may not edit (not admin nor creator any more).
    private var isReadOnly: Bool { !model.canEdit }

    private var areFieldsDisabled: Bool { model.isSaving || isReadOnly }

    private var calendar: Calendar { model.session.platform.calendar }

    /// « Demain à 18:00 ».
    private var dueDateSummary: String {
        DateText.relative(model.dueDate, now: model.session.platform.now(), calendar: calendar)
    }

    private func cancel() {
        if model.hasChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func save() {
        focusedField = nil
        Task {
            if let saved = await model.save() {
                onSaved(saved)
                dismiss()
            } else if model.titleError != nil {
                focusedField = .title
            }
        }
    }
}

private enum TaskEditorField: Hashable {
    case title
    case details
}

/// Inline validation message under a field.
private struct TaskEditorErrorText: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(ShellPalette.red)
    }
}
