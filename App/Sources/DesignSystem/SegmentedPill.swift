import SwiftUI

/// How the selected segment of a `SegmentedPill` is drawn.
enum SegmentTone {
    /// A `card` segment with `textPrimary` text and a small shadow (Tâches / Activité, Créer / Rejoindre).
    case standard
    /// A soft pair (the status of a task: « En cours » amber; the priority: « Moyenne » orange).
    case soft(SoftTone)
    /// A solid fill with white text (the repetition frequency, in `Theme.accentFill`).
    case filled(Color)
}

/// A segmented control of docs/DESIGN-V2.md §5: a `track` with 44 pt segments; the selected one slides with a spring
/// (a crossfade with Reduce Motion). Used for Tâches / Activité, the status and the priority of a task, the repetition
/// frequency, Créer / Rejoindre. At accessibility text sizes the segments stack vertically instead of being cut.
///
/// Each segment is a button with the selected trait and an optional accessibility identifier. `onSelect` is called with
/// an option other than the selected one; the pill shows `selection`, so an asynchronous change (a status) moves it
/// when the model changes.
///
/// ```swift
/// SegmentedPill(OnboardingViewModel.FirstGroupMode.allCases, selection: $model.firstGroupMode) { $0.label }
///
/// SegmentedPill(TaskStatus.allCases, selection: model.task.status, title: \.label,
///               tone: { .soft($0.tone) }, identifier: { AccessibilityID.Tasks.statusOption($0.rawValue) }) { status in
///     Task { await model.setStatus(status) }
/// }
/// ```
struct SegmentedPill<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    let tone: (Option) -> SegmentTone
    let identifier: (Option) -> String?
    let track: Color
    let onSelect: (Option) -> Void

    @Namespace private var namespace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - title: the text of a segment.
    ///   - tone: how the segment looks when selected (`.standard` by default).
    ///   - identifier: the accessibility identifier of a segment (UI tests), nil for none.
    ///   - track: the color of the track (`Theme.track`; `Theme.card` on the ground, `Theme.hairline` in a card).
    ///   - onSelect: called when another option is tapped.
    init(
        _ options: [Option],
        selection: Option,
        title: @escaping (Option) -> String,
        tone: @escaping (Option) -> SegmentTone = { _ in .standard },
        identifier: @escaping (Option) -> String? = { _ in nil },
        track: Color = Theme.track,
        onSelect: @escaping (Option) -> Void
    ) {
        self.options = options
        self.selection = selection
        self.title = title
        self.tone = tone
        self.identifier = identifier
        self.track = track
        self.onSelect = onSelect
    }

    /// A pill bound to a value (the selection changes at once).
    init(
        _ options: [Option],
        selection: Binding<Option>,
        tone: @escaping (Option) -> SegmentTone = { _ in .standard },
        identifier: @escaping (Option) -> String? = { _ in nil },
        track: Color = Theme.track,
        title: @escaping (Option) -> String
    ) {
        self.init(
            options,
            selection: selection.wrappedValue,
            title: title,
            tone: tone,
            identifier: identifier,
            track: track,
            onSelect: { selection.wrappedValue = $0 }
        )
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(4)
        .background(track, in: RoundedRectangle(cornerRadius: Theme.Radius.track, style: .continuous))
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy, value: selection)
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        return Button {
            if !isSelected {
                onSelect(option)
            }
        } label: {
            Text(title(option))
                .font(Font.subheadline.weight(isSelected ? .heavy : .bold))
                .foregroundStyle(isSelected ? selectedForeground(option) : Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if isSelected {
                        selectedBackground(option)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifierIfPresent(identifier(option))
    }

    private func selectedForeground(_ option: Option) -> Color {
        switch tone(option) {
        case .standard: Theme.textPrimary
        case let .soft(soft): soft.foreground
        case .filled: Theme.onFill
        }
    }

    @ViewBuilder
    private func selectedBackground(_ option: Option) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous)
        switch tone(option) {
        case .standard:
            shape
                .fill(Theme.card)
                .shadow(color: Theme.shadow.opacity(colorScheme == .dark ? 0 : 0.12), radius: 1.5, x: 0, y: 1)
        case let .soft(soft):
            shape.fill(soft.background)
        case let .filled(color):
            shape.fill(color)
        }
    }
}
