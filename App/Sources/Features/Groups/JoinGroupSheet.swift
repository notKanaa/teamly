import SwiftUI
import TeamTasksCore

/// « Rejoindre un groupe » sheet (docs/DESIGN-V2.md §7.2): a big monospaced field where the invite code is formatted
/// live as `ABCD-EFGH`, and the hint. After a successful join the sheet says whether the group was joined or already
/// joined, and « Ouvrir le groupe » calls `onOpenGroup` (the presenter closes the sheet and shows the group).
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
            ScrollView {
                Group {
                    if let result = model.result {
                        resultContent(result)
                    } else {
                        codeContent
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
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
                        Button("Rejoindre") {
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
        .shellErrorAlert(model)
    }

    /// The key tile, the title, the hint and the code field.
    private var codeContent: some View {
        VStack(spacing: 18) {
            IconTile(systemImage: "key.fill", tone: .accent, size: 64)
            VStack(spacing: 6) {
                Text("Ton code d’invitation")
                    .font(.rounded(.title2))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Demande le code à un admin du groupe\u{00A0}: 8 lettres ou chiffres, par exemple \(JoinGroupViewModel.placeholder).")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(JoinGroupViewModel.placeholder, text: $codeText)
                .font(.system(.title, design: .monospaced, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.join)
                .focused($isCodeFocused)
                .onSubmit {
                    submit()
                }
                .onChange(of: codeText) { _, newValue in
                    model.code = newValue
                    if codeText != model.code {
                        codeText = model.code
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 64)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .accessibilityLabel("Code d’invitation")
                .accessibilityIdentifier(AccessibilityID.Groups.codeField)
        }
        .frame(maxWidth: .infinity)
        .disabled(model.isSubmitting)
        .onAppear {
            isCodeFocused = true
        }
    }

    /// « Bienvenue ! » or « Déjà membre », the message, and « Ouvrir le groupe ».
    private func resultContent(_ result: JoinResult) -> some View {
        VStack(spacing: 18) {
            IconTile(systemImage: "checkmark", tone: .done, size: 64)
            Text(result.alreadyMember ? Self.alreadyMemberTitle : Self.joinedTitle)
                .font(.rounded(.title2))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(model.resultMessage ?? "")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.Groups.joinResult)
            PrimaryButton("Ouvrir le groupe", systemImage: "arrow.right", iconPlacement: .trailing) {
                onOpenGroup(result.groupId)
            }
            .accessibilityIdentifier(AccessibilityID.Groups.openGroupButton)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
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
