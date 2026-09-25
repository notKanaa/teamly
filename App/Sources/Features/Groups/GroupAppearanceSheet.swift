import SwiftUI
import TeamTasksCore

/// « Apparence » of a group (admins, from the « … » of the group screen; docs/DESIGN-V2.md §7.4): a live preview of
/// the group's hero, the emoji (or the initials: the first cell) and the color. « Enregistrer » (enabled once
/// something changed; a spinner while it saves) hands the saved group to `onSaved` and closes the sheet; an error shows
/// in an alert and keeps the choice. The sheet also closes when the group turns out to be gone.
struct GroupAppearanceSheet: View {
    let model: GroupAppearanceViewModel
    let onSaved: (TeamGroup) -> Void

    @Environment(\.dismiss) private var dismiss

    init(model: GroupAppearanceViewModel, onSaved: @escaping (TeamGroup) -> Void) {
        self.model = model
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    GroupAppearancePreview(appearance: model.preview, name: model.group.name)
                    PickerSection(OnboardingViewModel.emojiSectionTitle) {
                        EmojiGrid(
                            options: model.emojiOptions,
                            selection: model.emoji,
                            initials: model.preview.initials
                        ) { emoji in
                            model.selectEmoji(emoji)
                        }
                    }
                    PickerSection(OnboardingViewModel.colorSectionTitle) {
                        SwatchGrid(
                            options: model.colorOptions,
                            isSelected: { model.isSelected($0) },
                            onSelect: { model.selectColor($0) }
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, 16)
            }
            .screenBackground()
            .navigationTitle(GroupAppearanceViewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier(AccessibilityID.Groups.appearanceCancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                            .accessibilityLabel("Enregistrement")
                    } else {
                        Button("Enregistrer", action: save)
                            .fontWeight(.bold)
                            .disabled(!model.canSave)
                            .accessibilityIdentifier(AccessibilityID.Groups.appearanceSaveButton)
                    }
                }
            }
            .interactiveDismissDisabled(model.isSaving)
            .shellErrorAlert(model)
        }
        .onChange(of: model.isShowingError) { _, isShowing in
            // « Ce groupe n’existe plus… » was read: nothing left to edit.
            if !isShowing && model.isGone {
                dismiss()
            }
        }
    }

    private func save() {
        Task {
            if let saved = await model.save() {
                onSaved(saved)
                dismiss()
            }
        }
    }
}

/// The group's hero as it will look (docs/DESIGN-V2.md §7.4): the white tile with the emoji or the initials and the
/// name, on the group's fill. VoiceOver: « Aperçu du groupe », valued « 🎉, violet ».
struct GroupAppearancePreview: View {
    let appearance: AvatarAppearance
    let name: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(appearance: AvatarAppearance, name: String) {
        self.appearance = appearance
        self.name = name
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            GroupTile(appearance, size: 64, style: .onColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.rounded(.title3))
                    .foregroundStyle(Theme.onFill)
                    .fixedSize(horizontal: false, vertical: true)
                Text(appearance.color.label)
                    .font(Font.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onFill)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            appearance.color.fill,
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
        .animation(reduceMotion ? nil : .snappy, value: appearance)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aperçu du groupe")
        .accessibilityValue(GroupAppearanceText.describe(appearance))
        .accessibilityIdentifier(AccessibilityID.Groups.appearancePreview)
    }
}

/// French words for a group's look.
enum GroupAppearanceText {
    /// « 🏠, corail », « initiales CR, corail »: for VoiceOver (the tiles are decorative) and the UI tests.
    static func describe(_ appearance: AvatarAppearance) -> String {
        let symbol = appearance.emoji ?? "initiales \(appearance.initials)"
        return "\(symbol), \(appearance.color.label.lowercased())"
    }
}
