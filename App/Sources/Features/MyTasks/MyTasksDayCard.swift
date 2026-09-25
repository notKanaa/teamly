import SwiftUI
import TeamTasksCore

/// « Ta journée » (docs/DESIGN-V2.md §7.3): a ring of what is done today out of what was planned (« 1/2 »), the
/// subtitle (« 1 tâche faite sur 2 prévues »), then the chips « 1 en retard » and « 2 nouvelles » when there are any.
/// The ring goes above the texts at accessibility text sizes. VoiceOver reads the card as one element.
struct MyTasksDayCard: View {
    let summary: DaySummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(summary: DaySummary) {
        self.summary = summary
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            ProgressRing(progress: summary.fraction, text: summary.ringText)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DaySummary.title)
                        .font(.rounded(.title3, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text(summary.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if summary.overdueText != nil || summary.newText != nil {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        if let overdue = summary.overdueText {
                            Chip(overdue, tone: .danger, weight: .bold)
                        }
                        if let new = summary.newText {
                            Chip(new, tone: .accent, weight: .bold)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DaySummary.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(AccessibilityID.MyTasks.daySummary)
    }

    /// « 1 tâche faite sur 2 prévues, 1 en retard, 2 nouvelles ».
    private var accessibilityValue: String {
        [summary.subtitle, summary.overdueText, summary.newText].compactMap { $0 }.joined(separator: ", ")
    }
}
