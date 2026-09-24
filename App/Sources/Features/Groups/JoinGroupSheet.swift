import SwiftUI
import TeamTasksCore

/// « Rejoindre un groupe » sheet: the invite code is formatted live as `ABCD-EFGH`. After a successful join the
/// sheet says whether the group was joined or already joined, and « Ouvrir le groupe » calls `onOpenGroup`
/// (the presenter closes the sheet and shows the group).
struct JoinGroupSheet: View {
    let onOpenGroup: (UUID) -> Void

    @State private var model: JoinGroupViewModel
    /// Text of the field, re-synchronized with the formatted `model.code` after every edit (a TextField does not
    /// always redisplay a bound value that its setter normalized back to the previous value).
    @State private var codeText: String
    @FocusState private var isCodeFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(session: SessionModel, code: String = "", onOpenGroup: @escaping (UUID) -> Void) {
        self.onOpenGroup = onOpenGroup
        let model = JoinGroupViewModel(session: session, code: code)
        _model = State(initialValue: model)
        _codeText = State(initialValue: model.code)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Rejoindre un groupe")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cancelTitle) {
                            dismiss()
                        }
                        .disabled(model.isSubmitting)
                        .accessibilityIdentifier(AccessibilityID.Groups.cancelButton)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.isSubmitting {
                            ProgressView()
                                .accessibilityLabel("Vérification du code")
                        } else if model.result == nil {
                            Button("Rejoindre") { submit() }
                                .disabled(!model.canSubmit)
                                .accessibilityIdentifier(AccessibilityID.Groups.saveButton)
                        }
                    }
                }
        }
        .interactiveDismissDisabled(model.isSubmitting)
        .alert("Erreur", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let result = model.result {
            ContentUnavailableView {
                Label {
                    Text(result.alreadyMember ? Self.alreadyMemberTitle : Self.joinedTitle)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                }
            } description: {
                Text(model.resultMessage ?? "")
                    .accessibilityIdentifier(AccessibilityID.Groups.joinResult)
            } actions: {
                Button {
                    onOpenGroup(result.groupId)
                } label: {
                    Label("Ouvrir le groupe", systemImage: "arrow.right.circle")
                }
                .shellProminentButtonStyle()
                .accessibilityIdentifier(AccessibilityID.Groups.openGroupButton)
            }
        } else {
            Form {
                Section {
                    TextField(JoinGroupViewModel.placeholder, text: $codeText)
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.join)
                        .focused($isCodeFocused)
                        .onSubmit { submit() }
                        .onChange(of: codeText) { _, newValue in
                            model.code = newValue
                            if codeText != model.code {
                                codeText = model.code
                            }
                        }
                        .accessibilityLabel("Code d’invitation")
                        .accessibilityIdentifier(AccessibilityID.Groups.codeField)
                } header: {
                    Text("Code d’invitation")
                } footer: {
                    Text("Demandez le code à un admin du groupe\u{00A0}: 8 lettres ou chiffres, par exemple \(JoinGroupViewModel.placeholder).")
                }
            }
            .disabled(model.isSubmitting)
            .onAppear {
                isCodeFocused = true
            }
        }
    }

    private static let joinedTitle = "Bienvenue\u{00A0}!"
    private static let alreadyMemberTitle = "Déjà membre"

    private var cancelTitle: String { model.result == nil ? "Annuler" : "Fermer" }

    private func submit() {
        guard model.canSubmit else { return }
        isCodeFocused = false
        Task {
            await model.join()
        }
    }
}
