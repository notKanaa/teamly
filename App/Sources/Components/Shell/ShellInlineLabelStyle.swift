import SwiftUI

/// Icon then title with a small gap, for the labels inside list rows (« Demain à 18:00 », a group name…).
///
/// Inside a `List`, `.automatic` and even `.titleAndIcon` keep the list's wide, centred icon column, which costs
/// 15–20 pt per label on a row that is already short of width.
struct ShellInlineLabelStyle: LabelStyle {
    var spacing: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == ShellInlineLabelStyle {
    /// Icon and title side by side, without the list's icon column (see `ShellInlineLabelStyle`).
    static var inlineIcon: ShellInlineLabelStyle { ShellInlineLabelStyle() }
}
