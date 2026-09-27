import Foundation

/// « Heures calmes » (docs/CONTRACTS-V3.md §9): a daily window, 22:00 → 08:00 and off by default, stored per device
/// in the `KeyValueStore`. While it is on:
/// - a due-date reminder that would fire inside the window fires at its end (`ReminderPlanner`);
/// - the notifications shown at once (a new assignment) play no sound (the iOS scheduler checks `contains(_:calendar:)`).
///
/// ntfy pushes are not affected: they are sent by the server to the ntfy app.
///
/// Times are minutes after midnight, read in the injected calendar's time zone. The window runs from `startMinute`
/// (included) to `endMinute` (excluded) and spans midnight when the start is later than the end; a window whose start
/// equals its end is empty. Pure.
public struct QuietHours: Sendable, Hashable, Codable {
    /// `KeyValueStore` key.
    public static let storageKey = "settings.quietHours"
    public static let minutesPerDay = 24 * 60
    /// 22:00.
    public static let defaultStart = 22 * 60
    /// 08:00.
    public static let defaultEnd = 8 * 60

    public var isEnabled: Bool
    /// 0 ..< 1440 (normalized by the initializer).
    public var startMinute: Int
    /// 0 ..< 1440 (normalized by the initializer).
    public var endMinute: Int

    /// Off, 22:00 → 08:00 by default.
    public init(isEnabled: Bool = false, startMinute: Int = QuietHours.defaultStart, endMinute: Int = QuietHours.defaultEnd) {
        self.isEnabled = isEnabled
        self.startMinute = Self.normalized(startMinute)
        self.endMinute = Self.normalized(endMinute)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case startMinute
        case endMinute
    }

    /// Missing values take their default; out-of-range minutes are brought back into one day.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            startMinute: try container.decodeIfPresent(Int.self, forKey: .startMinute) ?? Self.defaultStart,
            endMinute: try container.decodeIfPresent(Int.self, forKey: .endMinute) ?? Self.defaultEnd
        )
    }

    // MARK: - Storage

    /// The stored value, or the default (off, 22:00 → 08:00) when missing or unreadable.
    public static func load(from store: any KeyValueStore) -> QuietHours {
        store.value(QuietHours.self, forKey: storageKey) ?? QuietHours()
    }

    public func save(to store: any KeyValueStore) {
        store.setValue(self, forKey: Self.storageKey)
    }

    // MARK: - The window

    /// On, with a window that is not empty.
    public var isActive: Bool { isEnabled && startMinute != endMinute }

    /// True when `date` falls inside the window (always false while off).
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        windowEnd(containing: date, calendar: calendar) != nil
    }

    /// The end of the window `date` falls in (the next `endMinute` time), nil when `date` is outside it or the quiet
    /// hours are off.
    public func windowEnd(containing date: Date, calendar: Calendar) -> Date? {
        guard isActive else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let daysToEnd: Int
        if startMinute < endMinute {
            // Within one day (13:00 → 15:00).
            guard minute >= startMinute, minute < endMinute else { return nil }
            daysToEnd = 0
        } else if minute >= startMinute {
            // Spanning midnight (22:00 → 08:00), before midnight: the window ends tomorrow.
            daysToEnd = 1
        } else if minute < endMinute {
            // After midnight: it ends today.
            daysToEnd = 0
        } else {
            return nil
        }
        let startOfDay = calendar.startOfDay(for: date)
        guard let endDay = calendar.date(byAdding: .day, value: daysToEnd, to: startOfDay),
              let end = calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60, second: 0, of: endDay),
              end > date
        else { return nil }
        return end
    }

    /// `date` moved to the end of the window when it falls inside it; `date` unchanged otherwise.
    public func deferred(_ date: Date, calendar: Calendar) -> Date {
        windowEnd(containing: date, calendar: calendar) ?? date
    }

    // MARK: - Wording

    /// « 22:00 → 8:00 ».
    public var rangeText: String {
        "\(Self.timeText(startMinute))\u{00A0}→ \(Self.timeText(endMinute))"
    }

    /// « 8:00 », « 22:30 » (minutes after midnight).
    public static func timeText(_ minute: Int) -> String {
        let value = normalized(minute)
        let minutes = value % 60
        return "\(value / 60):\(minutes < 10 ? "0" : "")\(minutes)"
    }

    /// `minute` brought back into 0 ..< 1440.
    public static func normalized(_ minute: Int) -> Int {
        ((minute % minutesPerDay) + minutesPerDay) % minutesPerDay
    }
}
