import SwiftUI

/// A progress ring (docs/DESIGN-V2.md §5, « Ta journée »): a `track` circle and a rounded `tint` arc from 12 o'clock,
/// with a label in the middle (`ProgressRing(progress:text:)` for a rounded heavy figure such as « 2/4 »). 68 pt by
/// default, growing a little with Dynamic Type (at most ×1.4). Animated with a spring (not with Reduce Motion).
/// With an `accessibilityLabel` it is one element whose value is the percentage; without, it is hidden (the text next
/// to it says the same).
struct ProgressRing<Center: View>: View {
    let progress: Double
    var size: CGFloat
    var lineWidth: CGFloat
    var tint: Color
    var track: Color
    var accessibilityLabel: String?
    let label: Center

    @ScaledMetric(relativeTo: .headline) private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        progress: Double,
        size: CGFloat = 68,
        lineWidth: CGFloat = 8,
        tint: Color = Theme.accent,
        track: Color = Theme.accentSoft,
        accessibilityLabel: String? = nil,
        @ViewBuilder label: () -> Center
    ) {
        self.progress = progress
        self.size = size
        self.lineWidth = lineWidth
        self.tint = tint
        self.track = track
        self.accessibilityLabel = accessibilityLabel
        self.label = label()
    }

    var body: some View {
        let side = size * min(max(scale, 1), 1.4)
        let fraction = min(max(progress, 0), 1)
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(track, lineWidth: lineWidth)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label
                .frame(width: max(side - 2 * lineWidth - 8, 1))
        }
        .frame(width: side, height: side)
        .animation(reduceMotion ? nil : .snappy, value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? "")
        .accessibilityValue("\(Int((fraction * 100).rounded())) %")
        .accessibilityHidden(accessibilityLabel == nil)
    }
}

extension ProgressRing where Center == ProgressRingText {
    /// A ring with a rounded heavy figure in the middle (« 2/4 »), shrunk to fit.
    init(
        progress: Double,
        text: String,
        size: CGFloat = 68,
        lineWidth: CGFloat = 8,
        tint: Color = Theme.accent,
        track: Color = Theme.accentSoft,
        accessibilityLabel: String? = nil
    ) {
        self.init(
            progress: progress,
            size: size,
            lineWidth: lineWidth,
            tint: tint,
            track: track,
            accessibilityLabel: accessibilityLabel
        ) {
            ProgressRingText(text: text)
        }
    }
}

/// The figure in the middle of a `ProgressRing`.
struct ProgressRingText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.roundedNumber(.headline))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

/// A progress bar (docs/DESIGN-V2.md §5): 8 pt high, a `track` capsule and a `tint` capsule (checklists in teal, the
/// week of a group in its fill). With an `accessibilityLabel` it is one element whose value is the percentage;
/// without, it is hidden (the text next to it says the same).
struct ProgressBar: View {
    let value: Double
    var tint: Color
    var track: Color
    var height: CGFloat
    var accessibilityLabel: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        value: Double,
        tint: Color = Theme.accentFill,
        track: Color = Theme.track,
        height: CGFloat = 8,
        accessibilityLabel: String? = nil
    ) {
        self.value = value
        self.tint = tint
        self.track = track
        self.height = height
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        let fraction = min(max(value, 0), 1)
        Capsule()
            .fill(track)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(width: fraction > 0 ? max(height, proxy.size.width * fraction) : 0)
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: fraction)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel ?? "")
            .accessibilityValue("\(Int((fraction * 100).rounded())) %")
            .accessibilityHidden(accessibilityLabel == nil)
    }
}

/// The progress of the onboarding (docs/DESIGN-V2.md §5): one capsule per step (the done and current ones in
/// `accentFill`) and « 2 sur 4 ». VoiceOver: « Étape 2 sur 4 ».
struct StepProgress: View {
    /// 1-based.
    let current: Int
    let total: Int
    /// « 2 sur 4 » (`OnboardingViewModel.progressText`); computed when nil.
    var text: String?

    init(current: Int, total: Int, text: String? = nil) {
        self.current = current
        self.total = total
        self.text = text
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<max(total, 1), id: \.self) { index in
                    Capsule()
                        .fill(index < current ? Theme.accentFill : Theme.trackStrong)
                        .frame(height: 6)
                }
            }
            .frame(minWidth: 72)
            Text(text ?? "\(current) sur \(total)")
                .font(Font.footnote.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .fixedSize()
        }
        .animation(.snappy, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Étape \(current) sur \(total)")
    }
}
