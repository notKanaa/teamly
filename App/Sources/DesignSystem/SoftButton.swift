import SwiftUI

/// A full-width soft button (docs/DESIGN-V2.md, v3 mockups): bold text and symbol in the tone's foreground on its
/// background, 44 pt tall at least, radius 14; dimmed while disabled. « Relancer Inès » is `.soft(.danger)`,
/// « Proposer mon tour à… » `.soft(ColorKey.teal.tone)`.
///
/// ```swift
/// Button { … } label: { Label("Relancer Inès", systemImage: "bell.badge.fill") }
///     .buttonStyle(.soft(.danger))
/// ```
struct SoftButtonStyle: ButtonStyle {
    var tone: SoftTone
    var isFullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled

    init(tone: SoftTone, isFullWidth: Bool = true) {
        self.tone = tone
        self.isFullWidth = isFullWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.subheadline.weight(.heavy))
            .foregroundStyle(tone.foreground)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: isFullWidth ? .infinity : nil, minHeight: 44)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.55)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    /// A full-width soft button in `tone`.
    static func soft(_ tone: SoftTone) -> SoftButtonStyle { SoftButtonStyle(tone: tone) }
}
