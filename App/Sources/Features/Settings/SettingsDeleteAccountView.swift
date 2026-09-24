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
                    Label {
                        Text(SettingsViewModel.deleteAccountWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField(SettingsViewModel.deleteConfirmationWord, text: $model.deleteConfirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isFieldFocused)
                        .onSubmit(deleteAccount)
                        .accessibilityLabel("Tapez \(SettingsViewModel.deleteConfirmationWord) pour confirmer")
                        .accessibilityIdentifier(AccessibilityID.Settings.deleteConfirmationField)
                } header: {
                    Text("Confirmation")
                } footer: {
                    Text("Tapez « \(SettingsViewModel.deleteConfirmationWord) » en majuscules pour confirmer.")
                }

                Section {
                    Button(role: .destructive, action: deleteAccount) {
                        HStack {
                            Spacer()
                            if model.isDeletingAccount {
                                ProgressView()
                            } else {
                                Text("Supprimer définitivement mon compte")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!model.canDeleteAccount)
                    .accessibilityIdentifier(AccessibilityID.Settings.confirmDeleteAccount)
                }
            }
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
