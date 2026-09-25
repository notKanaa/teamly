import SwiftUI
import TeamTasksCore

/// A small label of a soft pair (docs/DESIGN-V2.md §5): an optional leading SF Symbol and the text, footnote semibold.
/// - `.soft`: the tone's background and foreground (a group, « En cours », « Basse », « 1 en retard »);
/// - `.plain`: the foreground only, no background (a due date, « Ton tour », a checklist count);
/// - `.filled`: white on the tone's fill.
/// Long texts wrap instead of being cut. VoiceOver reads the text (the symbol is decorative).
///
/// ```swift
/// Chip("🏠 Coloc’", tone: group.color.tone)
/// Chip("20:00", systemImage: "clock", tone: .ink(Theme.textSecondary), style: .plain)
/// Chip(TaskStatus.inProgress.label, tone: TaskStatus.inProgress.tone)
/// ```
struct Chip: View {
    enum Style {
        case soft
        case plain
        case filled
    }

    let text: String
    var systemImage: String?
    var tone: SoftTone
    var style: Style
    /// The weight of the text: semibold (`Font.chip`); bold for an overdue date or « Ton tour ».
    var weight: Font.Weight

    init(
        _ text: String,
        systemImage: String? = nil,
        tone: SoftTone = .accent,
        style: Style = .soft,
        weight: Font.Weight = .semibold
    ) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
        self.style = style
        self.weight = weight
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(Font.footnote.weight(weight))
        .foregroundStyle(style == .filled ? Theme.onFill : tone.foreground)
        .padding(.horizontal, style == .plain ? 0 : 9)
        .padding(.vertical, style == .plain ? 0 : 4)
        .background {
            if style != .plain {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(style == .filled ? tone.fill : tone.background)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// The « Nouveau » badge of a task assigned by someone else since the user last looked: white on `accentFill`
/// (docs/DESIGN-V2.md §3). Never truncated.
struct NewBadge: View {
    /// nil: « Nouveau » (`MyTasksViewModel.newBadgeText`).
    var text: String?

    init(_ text: String? = nil) {
        self.text = text
    }

    var body: some View {
        Text(text ?? MyTasksViewModel.newBadgeText)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(Theme.onFill)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.accentFill, in: Capsule())
            .fixedSize()
    }
}

/// A filter chip of a task list (docs/DESIGN-V2.md §7.4): 44 pt tall; selected, `textPrimary` fill with the
/// background color as text; idle, a card with an outline. Its label is `TaskFilterChip.countedLabel`
/// (« À faire · 4 »). VoiceOver gets the selected trait.
struct FilterChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Font.subheadline.weight(isSelected ? .heavy : .bold))
                .foregroundStyle(isSelected ? Theme.background : Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background {
                    Capsule().fill(isSelected ? Theme.textPrimary : Theme.card)
                }
                .overlay {
                    if !isSelected {
                        Capsule().strokeBorder(Theme.trackStrong, lineWidth: 1.5)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
