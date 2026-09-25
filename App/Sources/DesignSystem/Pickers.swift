import SwiftUI
import TeamTasksCore

/// The color picker of docs/DESIGN-V2.md §5: the 9 palette colors in a 3 × 3 grid of 44 pt swatches, a check on the
/// selected one. Each swatch is a button named after its color (« Corail »), with the selected trait and the identifier
/// `AccessibilityID.Picker.color(rawValue)`.
///
/// ```swift
/// SwatchGrid(options: model.colorOptions, isSelected: { model.isSelected($0) }, onSelect: { model.selectColor($0) })
/// ```
struct SwatchGrid: View {
    let options: [ColorKey]
    let isSelected: (ColorKey) -> Bool
    let onSelect: (ColorKey) -> Void
    var columns: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        options: [ColorKey] = ColorKey.allCases,
        columns: Int = 3,
        isSelected: @escaping (ColorKey) -> Bool,
        onSelect: @escaping (ColorKey) -> Void
    ) {
        self.options = options
        self.columns = columns
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: max(columns, 1)),
            spacing: 10
        ) {
            ForEach(options) { option in
                swatch(option)
            }
        }
    }

    private func swatch(_ option: ColorKey) -> some View {
        let selected = isSelected(option)
        return Button {
            withAnimation(reduceMotion ? nil : .snappy) {
                onSelect(option)
            }
        } label: {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(option.fill)
                .frame(height: 44)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(Theme.onFill)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(3)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .strokeBorder(option.accent, lineWidth: 2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.Picker.color(option.rawValue))
    }
}

/// The emoji picker of docs/DESIGN-V2.md §5: a grid of the curated emojis (`EmojiChoices`), the selected one on
/// `accentSoft` with an accent ring. With `initials`, a first cell shows them and stands for « no emoji » (nil): the
/// avatar picker. Each cell is a button (VoiceOver reads the emoji's name, « Initiales » for the first cell) with the
/// selected trait and the identifier `AccessibilityID.Picker.emoji(_:)` (`Picker.initials`).
///
/// ```swift
/// EmojiGrid(options: avatar.emojiOptions, selection: avatar.emoji, initials: avatar.initials) { avatar.selectEmoji($0) }
/// EmojiGrid(options: create.emojiOptions, selection: create.emoji) { create.selectEmoji($0) }   // tap again: none
/// ```
struct EmojiGrid: View {
    let options: [String]
    let selection: String?
    var initials: String?
    var columns: Int
    let onSelect: (String?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        options: [String],
        selection: String?,
        initials: String? = nil,
        columns: Int = 6,
        onSelect: @escaping (String?) -> Void
    ) {
        self.options = options
        self.selection = selection
        self.initials = initials
        self.columns = columns
        self.onSelect = onSelect
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: max(columns, 1)),
            spacing: 8
        ) {
            if let initials {
                cell(isSelected: selection == nil, identifier: AccessibilityID.Picker.initials) {
                    onSelect(nil)
                } label: {
                    Text(initials)
                        .font(.rounded(.headline, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityLabel("Initiales")
                }
            }
            ForEach(options, id: \.self) { emoji in
                cell(isSelected: selection == emoji, identifier: AccessibilityID.Picker.emoji(emoji)) {
                    onSelect(emoji)
                } label: {
                    Text(emoji)
                        .font(.title2)
                        .lineLimit(1)
                }
            }
        }
    }

    private func cell<CellLabel: View>(
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> CellLabel
    ) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) {
                action()
            }
        } label: {
            label()
                .padding(4)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? Theme.accentSoft : Theme.card)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 2.5 : 1.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// A titled block of a picker (« Couleur », « Symbole », « Emoji »): a subheadline bold `textSecondary` header above
/// the content.
struct PickerSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Font.subheadline.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
