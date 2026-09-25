import SwiftUI
import TeamTasksCore

/// The glyph of a task status (docs/DESIGN-V2.md §5): « à faire » is a ring in `tint` (the group's color, see
/// `ColorKey.accent`), « en cours » an amber ring half filled, « terminée » a green disc with a check. 24 pt by
/// default. Decorative (see `StatusControl` for the button).
struct StatusGlyph: View {
    let status: TaskStatus
    var tint: Color
    var size: CGFloat

    init(_ status: TaskStatus, tint: Color = Theme.accent, size: CGFloat = 24) {
        self.status = status
        self.tint = tint
        self.size = size
    }

    var body: some View {
        ZStack {
            switch status {
            case .todo:
                Circle()
                    .strokeBorder(tint, lineWidth: lineWidth)
            case .inProgress:
                Circle()
                    .strokeBorder(ColorKey.amber.accent, lineWidth: lineWidth)
                // The left half: a circle trimmed from 6 to 12 o'clock (clockwise from 3 o'clock), closed by its fill.
                Circle()
                    .trim(from: 0.25, to: 0.75)
                    .fill(ColorKey.amber.accent)
                    .padding(lineWidth + size * 0.08)
            case .done:
                Circle()
                    .fill(ColorKey.green.fill)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(Theme.onFill)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var lineWidth: CGFloat { max(2, size * 0.105) }
}

/// The status button of a task row (docs/DESIGN-V2.md §5): a `StatusGlyph` in a 44 pt target (at least), growing with
/// Dynamic Type. A tap asks for the next status of the cycle (the caller runs it: `row.status.next`); a spinner
/// replaces the glyph while `isBusy`. Borderless: it keeps its own tap inside a `NavigationLink` row or card.
///
/// Accessibility: « Statut : À faire », hint « Passer à « En cours » », identifier `AccessibilityID.Tasks.statusButton`.
struct StatusControl: View {
    let status: TaskStatus
    var tint: Color
    var isBusy: Bool
    var isEnabled: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .headline) private var glyphSize: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        status: TaskStatus,
        tint: Color = Theme.accent,
        isBusy: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.status = status
        self.tint = tint
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        let side = max(44, glyphSize + 20)
        Button(action: action) {
            ZStack {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    StatusGlyph(status, tint: tint, size: glyphSize)
                        .opacity(isEnabled ? 1 : 0.45)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled || isBusy)
        .animation(reduceMotion ? nil : .snappy, value: status)
        .sensoryFeedback(.success, trigger: status) { _, newStatus in
            newStatus == .done
        }
        .accessibilityLabel("Statut\u{00A0}: \(status.label)")
        .accessibilityHint(isEnabled ? "Passer à «\u{00A0}\(status.next.label)\u{00A0}»" : "")
        .accessibilityIdentifier(AccessibilityID.Tasks.statusButton)
    }
}
