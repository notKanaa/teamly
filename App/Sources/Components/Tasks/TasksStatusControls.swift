import SwiftUI
import TeamTasksCore

/// Round status icon of a task row. A tap asks for the next status of the cycle (à faire → en cours → terminée →
/// à faire); shows a spinner while `isBusy`. Borderless, so it stays tappable inside a `NavigationLink` row.
///
/// Its tap area is at least 44 × 44 pt, but it lays out as tall as the glyph's box only: the glyph stays level with
/// the first line of the row's title, and the tap area overflows into the row's vertical padding.
struct TasksStatusButton: View {
    let status: TaskStatus
    let isBusy: Bool
    let isEnabled: Bool
    let action: () -> Void

    /// Side of the glyph's box, growing with Dynamic Type like the `.title2` glyph it holds.
    @ScaledMetric(relativeTo: .title2) private var glyphSide: CGFloat = 32

    init(status: TaskStatus, isBusy: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.status = status
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.action = action
    }

    /// Side of the tap area: Apple's 44 pt minimum, or the glyph's box when larger.
    private var hitSide: CGFloat { max(44, glyphSide) }

    var body: some View {
        Button {
            action()
        } label: {
            ZStack {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: status.systemImage)
                        .font(.title2)
                        .foregroundStyle(status.tasksTint)
                        .opacity(isEnabled ? 1 : 0.55)
                }
            }
            .frame(width: hitSide, height: hitSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.vertical, (glyphSide - hitSide) / 2)
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(accessibilityHintText)
        .accessibilityIdentifier(AccessibilityID.Tasks.statusButton)
    }

    private var accessibilityText: String {
        "Statut\u{00A0}: \(status.label)"
    }

    private var accessibilityHintText: String {
        isEnabled ? "Passer à «\u{00A0}\(status.next.label)\u{00A0}»" : ""
    }
}

/// Status selector of the task screen: one button per status, the current one filled. Selecting another status
/// calls `onSelect` (the caller runs the change). Each button is borderless so that it works inside a `List` row.
struct TasksStatusPicker: View {
    let selection: TaskStatus
    let options: [TaskStatus]
    let isBusy: Bool
    let onSelect: (TaskStatus) -> Void

    init(
        selection: TaskStatus,
        options: [TaskStatus] = TaskStatus.allCases,
        isBusy: Bool = false,
        onSelect: @escaping (TaskStatus) -> Void
    ) {
        self.selection = selection
        self.options = options
        self.isBusy = isBusy
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                optionButton(option)
            }
        }
        .opacity(isBusy ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }

    private func optionButton(_ option: TaskStatus) -> some View {
        let isSelected = option == selection
        return Button {
            if !isSelected {
                onSelect(option)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: option.systemImage)
                    .font(.title3)
                Text(option.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            // `onTint` on the solid fill: white on the dark light-mode tints, black on the bright dark-mode ones.
            .foregroundStyle(isSelected ? ShellPalette.onTint : option.tasksTint)
            .background(
                isSelected ? option.tasksTint : option.tasksTint.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.borderless)
        .disabled(isBusy)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.Tasks.statusOption(option.rawValue))
    }
}
