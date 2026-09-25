import SwiftUI
import TeamTasksCore

/// The weekly podium (docs/DESIGN-V2.md §5): up to 3 columns in the order given — pass
/// `GroupActivityViewModel.podiumStageOrder` (2nd, 1st, 3rd).
///
/// Each column shows the avatar (the first place has a trophy above it and an amber ring), the short name, then a bar
/// with the count and « 1re / 2e / 3e ». The bar's height tells the place: 104, 72 and 52 pt at the default text size,
/// growing with Dynamic Type (a bar is never shorter than its text). The first place's bar is amber; the others take the
/// person's soft color. VoiceOver reads one element per column: « Inès, 1re, 6 tâches ».
struct PodiumView: View {
    let entries: [PodiumEntry]

    @ScaledMetric(relativeTo: .title2) private var scale: CGFloat = 1

    init(entries: [PodiumEntry]) {
        self.entries = entries
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(entries) { entry in
                column(entry)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func column(_ entry: PodiumEntry) -> some View {
        let isFirst = entry.place == 1
        let tone = isFirst ? ColorKey.amber.tone : entry.person.appearance.color.tone
        return VStack(spacing: 6) {
            if isFirst {
                Image(systemName: "trophy.fill")
                    .font(.title3)
                    .foregroundStyle(ColorKey.amber.accent)
            }
            AvatarView(
                entry.person.appearance,
                size: isFirst ? 48 : 40,
                ring: isFirst ? Theme.card : nil,
                highlight: isFirst ? ColorKey.amber.accent : nil
            )
            .padding(isFirst ? 2 * AvatarView.ringWidth : 0)
            Text(entry.person.shortName)
                .font(Font.subheadline.weight(isFirst ? .heavy : .bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            VStack(spacing: 2) {
                Text("\(entry.count)")
                    .font(.roundedNumber(isFirst ? .title : .title2))
                Text(entry.placeText)
                    .font(Font.caption.weight(.heavy))
            }
            .foregroundStyle(tone.foreground)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: barHeight(for: entry.place))
            .background(
                tone.background,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 14,
                    bottomLeadingRadius: 6,
                    bottomTrailingRadius: 6,
                    topTrailingRadius: 14,
                    style: .continuous
                )
            )
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(entry.person.shortName), \(entry.placeText), \(FrenchText.count(entry.count, "tâche", "tâches"))"
        )
    }

    private func barHeight(for place: Int) -> CGFloat {
        let base: CGFloat
        switch place {
        case 1: base = 104
        case 2: base = 72
        default: base = 52
        }
        return base * min(max(scale, 1), 1.8)
    }
}
