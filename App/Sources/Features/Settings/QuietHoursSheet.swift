import SwiftUI
import TeamTasksCore

/// « Heures calmes » (sheet of « Réglages », docs/CONTRACTS-V3.md §9): the switch, then the start and end times of the
/// window (22:00 → 08:00 by default), and what it changes. « OK » hands the new value to `onSave` (the caller stores
/// it and resynchronizes the reminders); « Annuler » keeps the previous one.
struct QuietHoursSheet: View {
    let onSave: (QuietHours) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isEnabled: Bool
    @State private var start: Date
    @State private var end: Date

    static let explanation =
        "Pendant les heures calmes, les rappels d’échéance attendent la fin de la plage et les notifications arrivent sans son. Les notifications push (ntfy) ne sont pas concernées\u{00A0}: elles gardent les réglages de l’app ntfy."

    init(quietHours: QuietHours, onSave: @escaping (QuietHours) -> Void) {
        self.onSave = onSave
        _isEnabled = State(initialValue: quietHours.isEnabled)
        _start = State(initialValue: Self.date(minute: quietHours.startMinute))
        _end = State(initialValue: Self.date(minute: quietHours.endMinute))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $isEnabled.animation()) {
                        Label {
                            Text("Heures calmes")
                                .foregroundStyle(Theme.textPrimary)
                        } icon: {
                            IconTile(systemImage: "moon.fill", tone: SoftTone.accent, size: 30)
                        }
                    }
                    .tint(Theme.accentFill)
                    .accessibilityIdentifier(AccessibilityID.Settings.quietHoursToggle)

                    if isEnabled {
                        DatePicker("Début", selection: $start, displayedComponents: .hourAndMinute)
                            .accessibilityIdentifier(AccessibilityID.Settings.quietHoursStart)
                        DatePicker("Fin", selection: $end, displayedComponents: .hourAndMinute)
                            .accessibilityIdentifier(AccessibilityID.Settings.quietHoursEnd)
                    }
                } footer: {
                    Text(footer)
                }
                .listRowBackground(Theme.card)
            }
            .screenBackground()
            .navigationTitle("Heures calmes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.quietHoursCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK", action: save)
                        .fontWeight(.bold)
                        .accessibilityIdentifier(AccessibilityID.Settings.quietHoursDone)
                }
            }
        }
    }

    private var value: QuietHours {
        QuietHours(isEnabled: isEnabled, startMinute: Self.minute(of: start), endMinute: Self.minute(of: end))
    }

    private var footer: String {
        guard isEnabled else { return Self.explanation }
        let window = value
        if window.startMinute == window.endMinute {
            return "Choisis une fin différente du début. " + Self.explanation
        }
        return "De \(QuietHours.timeText(window.startMinute)) à \(QuietHours.timeText(window.endMinute)). " + Self.explanation
    }

    private func save() {
        onSave(value)
        dismiss()
    }

    // MARK: - Times of the pickers (today, in the device's calendar)

    static func date(minute: Int) -> Date {
        let calendar = Calendar.current
        let value = QuietHours.normalized(minute)
        return calendar.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: Date()) ?? Date()
    }

    static func minute(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
