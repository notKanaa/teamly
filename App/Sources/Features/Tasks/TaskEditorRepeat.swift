import SwiftUI
import TeamTasksCore

/// « Répéter » in the « Quand » card of the task editor (docs/DESIGN-V2.md §7.7), as rows of its section:
/// - the title and the pill Jamais / Jour / Semaine / Mois (choosing a frequency turns the due date on);
/// - while the task repeats: the interval (« Toutes les 2 semaines »), the weekday circles of a weekly rule, and a
///   hint: the rule, the next dates after the due date, what happens when the task is done, and the rule's error.
struct TaskEditorRepeatRows: View {
    @Bindable var model: TaskEditorViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: TaskEditorViewModel) {
        self.model = model
    }

    /// How many next dates the hint lists.
    private static let upcomingCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TaskEditorRowLabel("Répéter", systemImage: "arrow.triangle.2.circlepath", tone: ColorKey.coral.tone)
            SegmentedPill(
                model.repeatFrequencyOptions,
                selection: $model.repeatFrequency.animation(reduceMotion ? nil : .snappy),
                tone: { _ in .filled(Theme.accentFill) },
                identifier: { AccessibilityID.Tasks.repeatOption($0.rawValue) },
                track: Theme.hairline
            ) { $0.label }
        }
        .padding(.vertical, 4)

        if let frequency = model.repeatFrequency.frequency {
            Stepper(value: $model.repeatInterval, in: model.repeatIntervalRange) {
                Text(RecurrenceText.summary(frequency: frequency, interval: model.repeatInterval))
                    .font(Font.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .accessibilityIdentifier(AccessibilityID.Tasks.repeatIntervalStepper)
            .listRowSeparator(.hidden, edges: .top)

            if frequency == .weekly {
                TaskEditorWeekdayPicker(options: model.weekdayOptions) { weekday in
                    model.toggleWeekday(weekday)
                }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden, edges: .top)
            }

            hint
                .listRowSeparator(.hidden, edges: .top)
        }
    }

    /// « Chaque semaine, le samedi. », « Prochaines fois : samedi 3 octobre, … », « Dès que la tâche est faite, la
    /// suivante est créée. », then the rule's error.
    private var hint: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary = model.recurrenceSummary {
                Text(summary + ".")
                    .font(Font.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            if let upcoming = upcomingText {
                Text(upcoming)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(TaskEditorViewModel.recurrenceHint)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            if let message = model.recurrenceError {
                TaskEditorErrorText(message: message)
                    .font(.footnote)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Tasks.repeatHint)
    }

    /// « Prochaines fois : samedi 3 octobre, samedi 10 octobre et samedi 17 octobre. »: the occurrences after the due
    /// date, as the server would create them (`NextDueCalculator`); nil without a rule or a due date.
    private var upcomingText: String? {
        let draft = model.draft
        guard let rule = draft.recurrence, let dueAt = draft.dueAt else { return nil }
        let calendar = model.session.platform.calendar
        let dates = NextDueCalculator.upcomingDueDates(
            after: dueAt, rule: rule, now: model.session.platform.now(), count: Self.upcomingCount
        )
        guard let last = dates.last else { return nil }
        let formatter = FrenchDateFormatter(timeZone: calendar.timeZone)
        let days = dates.map { formatter.day($0, includeYear: false) }
        let list = days.count > 1
            ? "\(days.dropLast().joined(separator: ", ")) et \(formatter.day(last, includeYear: false))"
            : days[0]
        return "\(TaskDetailViewModel.upcomingTitle)\u{00A0}: \(list)."
    }
}

/// The 7 weekday circles of a weekly repetition (L M M J V S D), 44 pt: the chosen days filled in the accent. They
/// share the width; at accessibility text sizes they grow and wrap. Each is a button named after its day (« Lundi »),
/// with the selected trait.
struct TaskEditorWeekdayPicker: View {
    let options: [WeekdayOption]
    let onToggle: (Int) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledSide: CGFloat = 44

    init(options: [WeekdayOption], onToggle: @escaping (Int) -> Void) {
        self.options = options
        self.onToggle = onToggle
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(options) { option in
                        circle(option, side: min(scaledSide, 76))
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(options) { option in
                        circle(option, side: 44)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Jours")
    }

    private func circle(_ option: WeekdayOption, side: CGFloat) -> some View {
        Button {
            onToggle(option.id)
        } label: {
            Text(option.letter)
                .font(.rounded(.body, weight: option.isSelected ? .heavy : .bold))
                .foregroundStyle(option.isSelected ? Theme.onFill : Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: side, height: side)
                .background {
                    Circle()
                        .fill(option.isSelected ? Theme.accentFill : Theme.background)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(option.isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.Tasks.weekday(option.id))
    }
}
