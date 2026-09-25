import SwiftUI
import TeamTasksCore

/// « Nouvelle tâche » / « Modifier la tâche » sheet (docs/DESIGN-V2.md §7.7), as cards:
/// - Titre and Notes;
/// - Quand: the due date, then « Répéter » (Jamais / Jour / Semaine / Mois, the interval, the weekdays of a weekly rule,
///   the next dates);
/// - Qui s’en occupe ?: the assignee picker, or « À tour de rôle » and its order while the task repeats;
/// - Checklist (creation only);
/// - Priorité.
///
/// Each field shows the view model's message under it. Embeds its own `NavigationStack`: present it with `.sheet`.
/// Calls `onSaved` with the saved task, then dismisses.
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
                        Label("Tu ne peux pas modifier cette tâche.", systemImage: "lock.fill")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.card)
                }
                Group {
                    textSection
                    whenSection
                    whoSection
                    if model.showsChecklist {
                        Section {
                            TaskEditorChecklistRows(model: model, focusedField: $focusedField)
                        } header: {
                            Text(TaskEditorViewModel.checklistTitle)
                        }
                        .listRowBackground(Theme.card)
                    }
                    prioritySection
                }
                .disabled(areFieldsDisabled)
            }
            .listSectionSpacing(16)
            .screenBackground()
            // Scrolling to the cards below (repetition, people, priority) puts the keyboard away.
            .scrollDismissesKeyboard(.immediately)
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
                // Return adds a line to the notes: « OK » closes the keyboard, which otherwise hides the cards below.
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

    // MARK: - Titre and Notes

    private var textSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TaskEditorFieldCaption("Titre")
                TextField("Titre de la tâche", text: $model.title)
                    .font(.rounded(.title3, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focusedField, equals: .title)
                    .submitLabel(.next)
                    .onSubmit {
                        focusedField = .details
                    }
                    .accessibilityIdentifier(AccessibilityID.Tasks.titleField)
                if let message = model.titleError {
                    TaskEditorErrorText(message: message)
                        .font(.footnote)
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                TaskEditorFieldCaption("Notes")
                TextField("Ajoute des précisions (facultatif)", text: $model.details, axis: .vertical)
                    .lineLimit(2...10)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focusedField, equals: .details)
                    .accessibilityIdentifier(AccessibilityID.Tasks.detailsField)
                if let message = model.detailsError {
                    TaskEditorErrorText(message: message)
                        .font(.footnote)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - Quand

    private var whenSection: some View {
        Section {
            Toggle(isOn: $model.hasDueDate.animation()) {
                TaskEditorRowLabel("Échéance", systemImage: "calendar", tone: .accent)
            }
            // A repeating task always has a due date (the view model turns it on with the frequency).
            .disabled(model.isDueDateRequired)
            .accessibilityIdentifier(AccessibilityID.Tasks.dueDateToggle)

            if model.hasDueDate {
                VStack(alignment: .leading, spacing: 6) {
                    DatePicker(
                        "Date et heure",
                        selection: $model.dueDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .foregroundStyle(Theme.textPrimary)
                    .environment(\.locale, Locale(identifier: "fr_FR"))
                    .environment(\.calendar, calendar)
                    .environment(\.timeZone, calendar.timeZone)
                    .accessibilityIdentifier(AccessibilityID.Tasks.dueDatePicker)
                    dueDateCaption
                }
                .listRowSeparator(.hidden, edges: .top)
            }

            TaskEditorRepeatRows(model: model)
        } header: {
            Text("Quand")
        }
        .listRowBackground(Theme.card)
    }

    /// « Demain à 18:00 », the date's error, or why the due date stays while the task repeats.
    @ViewBuilder
    private var dueDateCaption: some View {
        if let message = model.dueDateError {
            TaskEditorErrorText(message: message)
                .font(.footnote)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(dueDateSummary)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                if model.isDueDateRequired {
                    Text(TaskEditorViewModel.dueDateRequiredText)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Qui s’en occupe ?

    private var whoSection: some View {
        Section {
            switch model.loadState {
            case .loaded:
                if model.canUseRotation {
                    Toggle(isOn: $model.isRotationEnabled.animation()) {
                        TaskEditorRowLabel(
                            TaskEditorViewModel.rotationTitle,
                            subtitle: TaskEditorViewModel.rotationSubtitle,
                            systemImage: "person.2.fill",
                            tone: ColorKey.teal.tone
                        )
                    }
                    .accessibilityIdentifier(AccessibilityID.Tasks.rotationToggle)
                }
                if model.showsRotation {
                    TaskEditorRotationRows(model: model)
                } else {
                    assigneesLink
                }
            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.textSecondary)
                    Button("Réessayer") {
                        Task { await model.reload() }
                    }
                    .fontWeight(.semibold)
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Chargement des membres…")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        } header: {
            Text("Qui s’en occupe\u{00A0}?")
        } footer: {
            if let message = model.assigneesError, model.showsAssigneePicker {
                TaskEditorErrorText(message: message)
            }
        }
        .listRowBackground(Theme.card)
    }

    /// « Assigner à », the chosen people's avatars and names; opens `TaskEditorAssigneePicker`.
    private var assigneesLink: some View {
        NavigationLink {
            TaskEditorAssigneePicker(model: model)
        } label: {
            HStack(spacing: 12) {
                TaskEditorRowLabel("Assigner à", systemImage: "person.fill", tone: ColorKey.blue.tone)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if !selectedAssignees.isEmpty {
                    AvatarStack(people: selectedAssignees, limit: 3, size: 26)
                }
                Text(model.assigneesSummary)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Tasks.assigneesButton)
    }

    // MARK: - Priorité

    private var prioritySection: some View {
        Section {
            SegmentedPill(
                [TeamTasksCore.TaskPriority.low, .medium, .high],
                selection: $model.priority,
                tone: { .soft($0.tone) },
                identifier: { AccessibilityID.Tasks.priorityOption($0.rawValue) },
                track: Theme.card
            ) { $0.label }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Priorité")
            .accessibilityIdentifier(AccessibilityID.Tasks.priorityPicker)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        } header: {
            Text("Priorité")
        }
        .listRowBackground(Theme.card)
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

    /// The chosen assignees as badges, the current user first.
    private var selectedAssignees: [PersonBadge] {
        MemberDirectory(members: model.members, currentUserId: model.session.userId)
            .badges(of: Array(model.assigneeIds))
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

/// The fields of the task editor that take the keyboard focus.
enum TaskEditorField: Hashable {
    case title
    case details
    /// « Ajouter un élément » of the checklist.
    case newChecklistItem
}

/// A row title of the editor's cards, led by its icon tile (like the rows of Réglages), with an optional subtitle.
struct TaskEditorRowLabel: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let tone: SoftTone

    init(_ title: String, subtitle: String? = nil, systemImage: String, tone: SoftTone) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tone = tone
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            IconTile(systemImage: systemImage, tone: tone, size: 30)
        }
    }
}

/// The small title above a text field of the editor (« Titre », « Notes »). Hidden from VoiceOver: the field's own
/// label says the same.
struct TaskEditorFieldCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Font.footnote.weight(.bold))
            .foregroundStyle(Theme.textSecondary)
            .accessibilityHidden(true)
    }
}

/// Inline validation message under a field, in the danger color.
struct TaskEditorErrorText: View {
    let message: String

    init(message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }
}
