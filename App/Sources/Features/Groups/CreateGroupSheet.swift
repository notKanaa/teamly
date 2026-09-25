import SwiftUI
import TeamTasksCore

/// « Nouveau groupe » sheet (docs/DESIGN-V2.md §7.2): the live tile of the group next to its name (with the « n/60 »
/// counter), then its emoji (tap the chosen one again for none: the initials) and its color. The creator becomes the
/// group's admin; on success `onCreated` is called (the presenter closes the sheet and shows the group). The return
/// key only closes the keyboard: « Créer » is in the navigation bar.
struct CreateGroupSheet: View {
    let onCreated: (GroupSummary) -> Void

    @State private var model: CreateGroupViewModel
    @FocusState private var isNameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: SessionModel, onCreated: @escaping (GroupSummary) -> Void) {
        self.onCreated = onCreated
        _model = State(initialValue: CreateGroupViewModel(session: session))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(padding: 18, spacing: 18, radius: 24) {
                        nameRow
                        nameFooter
                        PickerSection(OnboardingViewModel.emojiSectionTitle) {
                            EmojiGrid(options: model.emojiOptions, selection: model.emoji) { emoji in
                                model.selectEmoji(emoji)
                            }
                        }
                        PickerSection(OnboardingViewModel.colorSectionTitle) {
                            SwatchGrid(
                                options: model.colorOptions,
                                isSelected: { $0 == model.color },
                                onSelect: { model.selectColor($0) }
                            )
                        }
                    }
                    Text("Tu seras admin du groupe et pourras inviter d’autres personnes.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .disabled(model.isSubmitting)
            .navigationTitle("Nouveau groupe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                    .disabled(model.isSubmitting)
                    .accessibilityIdentifier(AccessibilityID.Groups.cancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSubmitting {
                        ProgressView()
                            .accessibilityLabel("Création du groupe")
                    } else {
                        Button("Créer") {
                            submit()
                        }
                        .fontWeight(.bold)
                        .disabled(!model.canSubmit)
                        .accessibilityIdentifier(AccessibilityID.Groups.saveButton)
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.isSubmitting)
        .onAppear {
            isNameFocused = true
        }
        .shellErrorAlert(model)
    }

    /// The tile as the group will look, next to « Nom du groupe ».
    private var nameRow: some View {
        HStack(alignment: .center, spacing: 14) {
            GroupTile(model.preview, size: 60)
                .animation(reduceMotion ? nil : .snappy, value: model.preview)
            VStack(alignment: .leading, spacing: 4) {
                Text(OnboardingViewModel.groupNameLabel)
                    .font(Font.footnote.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                TextField(CreateGroupViewModel.namePlaceholder, text: $model.name)
                    .font(.rounded(.title3, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .focused($isNameFocused)
                    .onSubmit {
                        isNameFocused = false
                    }
                    .accessibilityLabel(OnboardingViewModel.groupNameLabel)
                    .accessibilityIdentifier(AccessibilityID.Groups.nameField)
                Rectangle()
                    .fill(model.nameError == nil ? Theme.track : Theme.danger)
                    .frame(height: 2)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The name error, if any, and the « n/60 » counter, measured like the validation (trimmed, code points): it
    /// turns red exactly when « Créer » would refuse the name.
    private var nameFooter: some View {
        let length = CreateGroupNameCounter.length(of: model.name)
        let isTooLong = CreateGroupNameCounter.isTooLong(model.name)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let nameError = model.nameError {
                Label(nameError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.Groups.nameError)
            }
            Spacer(minLength: 8)
            Text("\(length)/\(CreateGroupNameCounter.maxLength)")
                .font(Font.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isTooLong ? Theme.danger : Theme.textSecondary)
                .accessibilityLabel("\(length) caractères sur \(CreateGroupNameCounter.maxLength)")
        }
    }

    private func submit() {
        guard model.canSubmit else { return }
        isNameFocused = false
        Task {
            if let group = await model.create() {
                onCreated(group)
            }
        }
    }
}
