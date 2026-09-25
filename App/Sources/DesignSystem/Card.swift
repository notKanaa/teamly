import SwiftUI

/// A card (docs/DESIGN-V2.md §5): a vertical stack of `content`, padded, on the `card` surface with radius 22 and the
/// card elevation (shadow in light mode, hairline in dark mode). Full width.
///
/// ```swift
/// Card {
///     SectionTitle("Checklist", size: .large)
///     ProgressBar(value: 0.4, tint: ColorKey.teal.fill, track: ColorKey.teal.tone.background)
/// }
/// ```
struct Card<Content: View>: View {
    var padding: CGFloat
    var spacing: CGFloat
    var radius: CGFloat
    var alignment: HorizontalAlignment
    let content: Content

    init(
        padding: CGFloat = Theme.Spacing.cardPadding,
        spacing: CGFloat = 12,
        radius: CGFloat = Theme.Radius.card,
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.spacing = spacing
        self.radius = radius
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        VStack(alignment: alignment, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .cardSurface(radius: radius)
    }
}

/// A rounded square with an SF Symbol in a soft tone (docs/DESIGN-V2.md §5): it leads the rows of the info cards
/// (32 pt), the turn cards (36), the onboarding highlights (48). Grows a little with Dynamic Type (at most ×1.5).
/// Decorative: hidden from VoiceOver.
struct IconTile: View {
    let systemImage: String
    var tone: SoftTone
    var size: CGFloat

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    init(systemImage: String, tone: SoftTone = .accent, size: CGFloat = 32) {
        self.systemImage = systemImage
        self.tone = tone
        self.size = size
    }

    var body: some View {
        let side = size * min(max(scale, 1), 1.5)
        RoundedRectangle(cornerRadius: side * 0.31, style: .continuous)
            .fill(tone.background)
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: side * 0.5, weight: .semibold))
                    .foregroundStyle(tone.foreground)
            }
            .accessibilityHidden(true)
    }
}
