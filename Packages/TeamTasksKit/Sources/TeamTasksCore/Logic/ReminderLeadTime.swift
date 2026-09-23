import Foundation

/// How long before a task's due date its reminder fires (Réglages › Rappels). Persisted in `KeyValueStore`.
public enum ReminderLeadTime: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case atDueTime
    case fifteenMinutes
    case oneHour
    case oneDay
    /// No due-date reminders.
    case off

    /// Default when nothing is stored: 1 hour before.
    public static let `default`: ReminderLeadTime = .oneHour
    /// `KeyValueStore` key.
    public static let storageKey = "settings.reminderLeadTime"

    public var id: String { rawValue }

    /// French label for the settings picker.
    public var label: String {
        switch self {
        case .atDueTime: "À l'heure de l'échéance"
        case .fifteenMinutes: "15 minutes avant"
        case .oneHour: "1 heure avant"
        case .oneDay: "1 jour avant"
        case .off: "Aucun rappel"
        }
    }

    public var isEnabled: Bool { self != .off }

    /// When the reminder of a task due at `dueAt` fires, or nil when reminders are off.
    /// "1 jour avant" is one calendar day earlier at the same wall-clock time (23 or 25 hours across a
    /// daylight-saving transition), per `calendar`'s time zone.
    public func fireDate(forDueAt dueAt: Date, calendar: Calendar) -> Date? {
        switch self {
        case .atDueTime: dueAt
        case .fifteenMinutes: dueAt.addingTimeInterval(-15 * 60)
        case .oneHour: dueAt.addingTimeInterval(-60 * 60)
        case .oneDay: calendar.date(byAdding: .day, value: -1, to: dueAt) ?? dueAt.addingTimeInterval(-86_400)
        case .off: nil
        }
    }

    /// Stored value, or `.default` when missing or unreadable.
    public static func load(from store: any KeyValueStore) -> ReminderLeadTime {
        store.value(ReminderLeadTime.self, forKey: storageKey) ?? .default
    }

    public func save(to store: any KeyValueStore) {
        store.setValue(self, forKey: Self.storageKey)
    }
}
