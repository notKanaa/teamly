import SwiftUI
import TeamTasksCore

/// The avatar picker of `AvatarEditorViewModel` (docs/DESIGN-V2.md §7.1 step 2, and the « Ton avatar » sheet of
/// « Réglages »): the 116 pt preview, the « Couleur » swatches, then « Symbole »: the initials or an emoji.
struct AvatarEditorContent: View {
    let model: AvatarEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            AvatarPreview(appearance: model.preview)
            PickerSection(OnboardingViewModel.colorSectionTitle) {
                SwatchGrid(
                    options: model.colorOptions,
                    isSelected: { model.isSelected($0) },
                    onSelect: { model.selectColor($0) }
                )
            }
            PickerSection(OnboardingViewModel.symbolSectionTitle) {
                EmojiGrid(options: model.emojiOptions, selection: model.emoji, initials: model.initials) { emoji in
                    model.selectEmoji(emoji)
                }
            }
        }
    }
}

/// The big preview of an avatar being edited: 116 pt, a 6 pt `card` ring and a soft shadow. VoiceOver: « Aperçu de
/// ton avatar », with its symbol and color.
struct AvatarPreview: View {
    let appearance: AvatarAppearance

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AvatarView(appearance, size: 116)
            .background {
                Circle()
                    .fill(Theme.card)
                    .padding(-6)
                    .shadow(color: Theme.shadow.opacity(colorScheme == .dark ? 0 : 0.18), radius: 15, x: 0, y: 14)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .snappy, value: appearance)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Aperçu de ton avatar")
            .accessibilityValue(valueText)
            .accessibilityIdentifier(AccessibilityID.Picker.avatarPreview)
    }

    /// « 🦊, corail » / « initiales CM, indigo ».
    private var valueText: String {
        let symbol = appearance.emoji ?? "initiales \(appearance.initials)"
        return "\(symbol), \(appearance.color.label.lowercased())"
    }
}

/// « Ton avatar » (sheet of « Réglages »): the avatar picker, « Annuler » and « Enregistrer » (enabled once something
/// changed; a spinner while it saves). On success `onSaved` gets the saved profile and the sheet closes; an error shows
/// in an alert and keeps the choice.
struct AvatarEditorSheet: View {
    let model: AvatarEditorViewModel
    let onSaved: (UserProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                AvatarEditorContent(model: model)
                    .padding(.horizontal, Theme.Spacing.page)
                    .padding(.vertical, 16)
            }
            .screenBackground()
            .navigationTitle("Ton avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier(AccessibilityID.Settings.avatarCancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button("Enregistrer", action: save)
                            .fontWeight(.bold)
                            .disabled(!model.canSave)
                            .accessibilityIdentifier(AccessibilityID.Settings.avatarSaveButton)
                    }
                }
            }
            .interactiveDismissDisabled(model.isSaving)
            .shellErrorAlert(model)
        }
    }

    private func save() {
        Task {
            if await model.save() {
                onSaved(model.profile)
                dismiss()
            }
        }
    }
}
