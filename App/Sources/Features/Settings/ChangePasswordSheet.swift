import SwiftUI
import TeamTasksCore

/// « Mot de passe » (sheet of « Réglages »): the new password twice, with the fields of the « Nouveau mot de passe »
/// step of the reset flow, then « Enregistrer le mot de passe ». Once saved, the sheet says so and « OK » closes it;
/// the session stays open.
struct ChangePasswordSheet: View {
    @Bindable var model: ChangePasswordViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isUITesting) private var isUITesting
    @FocusState private var focus: AuthFocusField?

    init(model: ChangePasswordViewModel) {
        _model = Bindable(model)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 14) {
                        IconTile(
                            systemImage: model.isDone ? "checkmark.seal.fill" : "lock.rotation",
                            tone: model.isDone ? SoftTone.done : ColorKey.blue.tone,
                            size: 64
                        )
                        Text(model.isDone ? ChangePasswordViewModel.doneMessage : ChangePasswordViewModel.hint)
                            .font(.callout)
                            .foregroundStyle(model.isDone ? Theme.textPrimary : Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifierIfPresent(model.isDone ? AccessibilityID.Settings.passwordDone : nil)
                    }
                    .frame(maxWidth: .infinity)

                    if model.isDone {
                        PrimaryButton("OK") {
                            dismiss()
                        }
                    } else {
                        fields
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle(ChangePasswordViewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !model.isDone {
                        Button("Annuler") {
                            dismiss()
                        }
                        .disabled(model.isSaving)
                        .accessibilityIdentifier(AccessibilityID.Settings.cancelPassword)
                    }
                }
            }
            .interactiveDismissDisabled(model.isSaving)
            .shellErrorAlert(model)
            .onAppear {
                focus = .newPassword
            }
        }
    }

    private var fields: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                AuthPasswordField(
                    title: "Nouveau mot de passe",
                    text: $model.newPassword,
                    focus: $focus,
                    field: .newPassword,
                    accessibilityID: AccessibilityID.Settings.newPasswordField
                )
                .newPasswordContentType(isUITesting: isUITesting)
                .submitLabel(.next)
                .onSubmit { focus = .passwordConfirmation }

                AuthPasswordField(
                    title: "Confirme le mot de passe",
                    text: $model.passwordConfirmation,
                    focus: $focus,
                    field: .passwordConfirmation,
                    accessibilityID: AccessibilityID.Settings.passwordConfirmationField
                )
                .newPasswordContentType(isUITesting: isUITesting)
                .submitLabel(.done)
                .onSubmit(save)
            }

            PrimaryButton("Enregistrer le mot de passe", isLoading: model.isSaving, action: save)
                .disabled(!model.canSave)
                .accessibilityIdentifier(AccessibilityID.Settings.savePassword)
        }
    }

    private func save() {
        guard model.canSave else { return }
        focus = nil
        Task {
            await model.save()
        }
    }
}
