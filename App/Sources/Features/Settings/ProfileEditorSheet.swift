import SwiftUI
import TeamTasksCore

/// « Mon profil » (sheet of « Réglages », opened by the avatar and « Modifier mon profil »): the display name, then the
/// avatar picker (`AvatarEditorContent`: the preview, « Couleur », « Symbole »). « Enregistrer » (enabled once something
/// changed; a spinner while it saves) saves the name, then the avatar, and closes the sheet; an error shows under the
/// name or in an alert and keeps the choices. « Annuler » drops them.
struct ProfileEditorSheet: View {
    @Bindable var settings: SettingsViewModel
    let avatar: AvatarEditorViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var isSaving = false

    init(settings: SettingsViewModel, avatar: AvatarEditorViewModel) {
        _settings = Bindable(settings)
        self.avatar = avatar
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    nameSection
                    AvatarEditorContent(model: avatar)
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle("Mon profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", action: cancel)
                        .disabled(isSaving)
                        .accessibilityIdentifier(AccessibilityID.Settings.avatarCancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Enregistrer", action: save)
                            .fontWeight(.bold)
                            .disabled(!canSave)
                            .accessibilityIdentifier(AccessibilityID.Settings.avatarSaveButton)
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
            .shellErrorAlert(avatar)
        }
        .shellErrorAlert(settings)
        .onDisappear {
            // Swiped away: the name being edited is dropped, like with « Annuler ».
            if nameChanged {
                settings.displayName = settings.profile?.displayName ?? ""
            }
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ton nom")
                .font(Font.subheadline.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            TextField("Ton nom", text: $settings.displayName)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($isNameFocused)
                .onSubmit {
                    isNameFocused = false
                }
                .accessibilityLabel("Ton nom")
                .accessibilityIdentifier(AccessibilityID.Settings.displayNameField)
                .authFieldStyle(systemImage: "person.fill", error: settings.displayNameError)
            Text("Ton nom est visible par les membres de tes groupes.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The typed name differs from the saved one.
    private var nameChanged: Bool {
        InputValidation.trimmed(settings.displayName) != (settings.profile?.displayName ?? "")
    }

    private var canSave: Bool {
        !isSaving && (nameChanged || avatar.hasChanges)
    }

    private func save() {
        guard canSave else { return }
        isNameFocused = false
        isSaving = true
        Task {
            let saved = await saveChanges()
            isSaving = false
            if saved {
                dismiss()
            }
        }
    }

    /// The name first (its error shows under the field), then the avatar.
    private func saveChanges() async -> Bool {
        if nameChanged {
            guard await settings.saveDisplayName() else { return false }
        }
        if avatar.hasChanges {
            guard await avatar.save() else { return false }
            settings.apply(avatar.profile)
        }
        return true
    }

    private func cancel() {
        settings.displayName = settings.profile?.displayName ?? ""
        avatar.reset()
        dismiss()
    }
}
