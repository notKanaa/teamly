import SwiftUI
import TeamTasksCore
import UIKit

/// « Supprimer le compte » (sheet): explains what is deleted and requires typing « SUPPRIMER ».
/// On success the session ends and `AppModel` shows the login screen (which removes this sheet).
struct SettingsDeleteAccountView: View {
    @Bindable var model: SettingsViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(systemImage: "exclamationmark.triangle.fill", tone: SoftTone.danger, size: 36)
                        Text(SettingsViewModel.deleteAccountWarning)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.card)

                Section {
                    TextField(SettingsViewModel.deleteConfirmationWord, text: $model.deleteConfirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isFieldFocused)
                        .onSubmit(deleteAccount)
                        .accessibilityLabel("Tape \(SettingsViewModel.deleteConfirmationWord) pour confirmer")
                        .accessibilityIdentifier(AccessibilityID.Settings.deleteConfirmationField)
                } header: {
                    Text("Confirmation")
                } footer: {
                    Text("Tape «\u{00A0}\(SettingsViewModel.deleteConfirmationWord)\u{00A0}» en majuscules pour confirmer.")
                }
                .listRowBackground(Theme.card)

                Section {
                    Button(role: .destructive, action: deleteAccount) {
                        HStack {
                            Spacer()
                            if model.isDeletingAccount {
                                ProgressView()
                            } else {
                                Text("Supprimer définitivement mon compte")
                                    .fontWeight(.bold)
                                    .foregroundStyle(model.canDeleteAccount ? Theme.danger : Theme.textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!model.canDeleteAccount)
                    .accessibilityIdentifier(AccessibilityID.Settings.confirmDeleteAccount)
                }
                .listRowBackground(Theme.card)
            }
            .screenBackground()
            .navigationTitle("Supprimer le compte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", action: close)
                        .disabled(model.isDeletingAccount)
                        .accessibilityIdentifier(AccessibilityID.Settings.cancelDeleteAccount)
                }
            }
            .interactiveDismissDisabled(model.isDeletingAccount)
            .shellErrorAlert(model)
            .onAppear {
                isFieldFocused = true
            }
        }
    }

    private func deleteAccount() {
        guard model.canDeleteAccount else { return }
        isFieldFocused = false
        Task {
            await model.deleteAccount()
        }
    }

    private func close() {
        model.deleteConfirmation = ""
        dismiss()
    }
}
