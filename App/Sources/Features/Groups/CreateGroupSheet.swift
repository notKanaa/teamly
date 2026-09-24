import SwiftUI
import TeamTasksCore

/// « Nouveau groupe » sheet. The creator becomes the group's admin; on success `onCreated` is called (the
/// presenter closes the sheet and shows the group).
struct CreateGroupSheet: View {
    let onCreated: (GroupSummary) -> Void

    @State private var model: CreateGroupViewModel
    @FocusState private var isNameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(session: SessionModel, onCreated: @escaping (GroupSummary) -> Void) {
        self.onCreated = onCreated
        _model = State(initialValue: CreateGroupViewModel(session: session))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom du groupe", text: $model.name)
                        .focused($isNameFocused)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit { submit() }
                        .accessibilityIdentifier(AccessibilityID.Groups.nameField)
                } header: {
                    Text("Nom")
                } footer: {
                    footer
                }
            }
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
                        Button("Créer") { submit() }
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
        .alert("Erreur", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var footer: some View {
        // Measured like the validation (trimmed, code points), so the counter turns red exactly when « Créer » would
        // refuse the name.
        let length = CreateGroupNameCounter.length(of: model.name)
        let isTooLong = CreateGroupNameCounter.isTooLong(model.name)
        return VStack(alignment: .leading, spacing: 6) {
            if let nameError = model.nameError {
                Label(nameError, systemImage: "exclamationmark.circle")
                    .foregroundStyle(ShellPalette.red)
                    .accessibilityIdentifier(AccessibilityID.Groups.nameError)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Par exemple «\u{00A0}Coloc’\u{00A0}», «\u{00A0}Famille\u{00A0}» ou «\u{00A0}Projet asso\u{00A0}». Vous serez admin du groupe et pourrez inviter d’autres personnes.")
                Spacer(minLength: 8)
                Text("\(length)/\(CreateGroupNameCounter.maxLength)")
                    .monospacedDigit()
                    .foregroundStyle(isTooLong ? ShellPalette.red : Color.secondary)
                    .accessibilityLabel("\(length) caractères sur \(CreateGroupNameCounter.maxLength)")
            }
        }
    }

    private func submit() {
        guard model.canSubmit else { return }
        Task {
            if let group = await model.create() {
                onCreated(group)
            }
        }
    }
}
