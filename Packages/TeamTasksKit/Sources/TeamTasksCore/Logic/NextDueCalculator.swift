import Foundation

/// Due dates of the occurrences of a recurring task (docs/CONTRACTS-V2.md §6), computed exactly like the server's
/// `private.next_due_at`: the mocks spawn the next occurrence with it, and the UI previews the next dates. Pure.
///
/// Days are local calendar dates of the rule's time zone, in the proleptic Gregorian calendar (weeks start on
/// Monday), and every occurrence keeps the local time of day of the due date it comes from. A local time that does
/// not exist or is ambiguous (a daylight saving time change) is read like PostgreSQL does, whatever Foundation's own
/// policy: a skipped time takes the offset from before the change (02:30 on the spring-forward day in Paris is
/// 03:30 CEST), a repeated time is the later instant (02:30 on the fall-back day in Paris is 02:30 CET).
public enum NextDueCalculator {
    /// Most calls of `step` in one computation, the first one included (docs/CONTRACTS-V2.md §6, vector 26).
    public static let maxSteps = 10_000

    /// The due date of the occurrence created when an occurrence due at `dueAt` becomes done at `now`.
    ///
    /// With `d` and `t` the local date and time of day of `dueAt` in the rule's time zone: `c = step(d)`, then
    /// `c = step(c)` while `c + t` (local) is not after `now`, at most `maxSteps` steps in all. Missed occurrences are
    /// skipped, a slot due exactly at `now` included, and an early completion does not repeat the same slot. After
    /// `maxSteps` steps the result may still be in the past.
    ///
    /// `step` adds `interval` days (daily) or weeks (weekly, no weekdays); with weekdays it goes to the next listed
    /// weekday of the same week, else to the first listed weekday `interval` weeks later; monthly, it goes `interval`
    /// months later, on `rule.monthDay` (nil: the local day of `dueAt`) or the last day of a shorter month.
    ///
    /// - Returns: nil when this device does not know the rule's time zone.
    public static func nextDueDate(after dueAt: Date, rule: RecurrenceRule, now: Date) -> Date? {
        guard let zone = rule.timeZone else { return nil }
        let local = LocalDateTime(dueAt, in: zone)
        let monthDay = rule.monthDay ?? CivilDate(dayNumber: local.day).day
        var day = step(local.day, rule: rule, monthDay: monthDay)
        var steps = 1
        var due = instant(day: day, time: local.time, in: zone)
        while due <= now, steps < maxSteps {
            day = step(day, rule: rule, monthDay: monthDay)
            steps += 1
            due = instant(day: day, time: local.time, in: zone)
        }
        return due
    }

    /// The next `count` due dates of the series, for previews (« Prochaines fois : … »): first the date of the
    /// occurrence created if the one due at `dueAt` became done at `now` (`nextDueDate(after:rule:now:)`), then each
    /// following one a single step after the previous, as the server would create them if every occurrence were done
    /// before the next one is due (same month day for the whole series, local time of day of the previous date).
    ///
    /// - Returns: `count` increasing dates; empty when `count` ≤ 0 or the rule's time zone is unknown.
    public static func upcomingDueDates(after dueAt: Date, rule: RecurrenceRule, now: Date, count: Int) -> [Date] {
        guard count > 0, let zone = rule.timeZone,
              let first = nextDueDate(after: dueAt, rule: rule, now: now)
        else { return [] }
        let monthDay = rule.monthDay ?? CivilDate(dayNumber: LocalDateTime(dueAt, in: zone).day).day
        var dates = [first]
        var previous = first
        while dates.count < count {
            let local = LocalDateTime(previous, in: zone)
            previous = instant(day: step(local.day, rule: rule, monthDay: monthDay), time: local.time, in: zone)
            dates.append(previous)
        }
        return dates
    }

    // MARK: - Steps

    /// The local date that follows `day` (days since 1970-01-01) in the rule (`private.recurrence_step`).
    static func step(_ day: Int, rule: RecurrenceRule, monthDay: Int) -> Int {
        let interval = rule.interval
        switch rule.frequency {
        case .daily:
            return day + interval
        case .weekly:
            guard let weekdays = rule.weekdays, let firstWeekday = weekdays.min() else { return day + 7 * interval }
            let weekday = isoWeekday(day)
            if let next = weekdays.filter({ $0 > weekday }).min() {
                return day + (next - weekday)
            }
            // monday(d) + 7 × interval + (min(W) − 1): a Sunday belongs to the week of the Monday before it.
            return day - (weekday - 1) + 7 * interval + (firstWeekday - 1)
        case .monthly:
            let date = CivilDate(dayNumber: day)
            let months = date.year * 12 + (date.month - 1) + interval
            let year = months >= 0 ? months / 12 : (months - 11) / 12
            let month = months - year * 12 + 1
            let clamped = min(max(monthDay, 1), CivilDate.daysInMonth(year: year, month: month))
            return CivilDate(year: year, month: month, day: clamped).dayNumber
        }
    }

    /// ISO weekday of a day number: 1 = Monday … 7 = Sunday (1970-01-01 was a Thursday).
    static func isoWeekday(_ day: Int) -> Int {
        ((day + 3) % 7 + 7) % 7 + 1
    }

    // MARK: - Local times

    /// The instant of the local date `day` at `time` (seconds after local midnight) in `zone`, with PostgreSQL's
    /// rules for a DST change (`DetermineTimeZoneOffset`): the candidates are the local time read with the offset
    /// of the day before and with the offset of the day after; when exactly one of them reads back as that local
    /// time it is the answer, otherwise (a skipped or repeated local time) the later of the two.
    static func instant(day: Int, time: TimeInterval, in zone: TimeZone) -> Date {
        let local = Double(day) * 86_400 + time
        let offsetBefore = offset(of: zone, at: local - 86_400)
        let offsetAfter = offset(of: zone, at: local + 86_400)
        let before = local - offsetBefore
        let after = local - offsetAfter
        guard offsetBefore != offsetAfter else { return Date(timeIntervalSince1970: before) }
        let beforeHolds = offset(of: zone, at: before) == offsetBefore
        let afterHolds = offset(of: zone, at: after) == offsetAfter
        if beforeHolds != afterHolds {
            return Date(timeIntervalSince1970: beforeHolds ? before : after)
        }
        return Date(timeIntervalSince1970: max(before, after))
    }

    private static func offset(of zone: TimeZone, at secondsSince1970: TimeInterval) -> TimeInterval {
        TimeInterval(zone.secondsFromGMT(for: Date(timeIntervalSince1970: secondsSince1970)))
    }
}

/// A local date and time of day: `day` since 1970-01-01, `time` in seconds after local midnight.
struct LocalDateTime: Hashable {
    var day: Int
    var time: TimeInterval

    init(_ date: Date, in zone: TimeZone) {
        let local = date.timeIntervalSince1970 + TimeInterval(zone.secondsFromGMT(for: date))
        day = Int((local / 86_400).rounded(.down))
        time = local - TimeInterval(day) * 86_400
    }
}

/// A date of the proleptic Gregorian calendar, converted to and from a day number (days since 1970-01-01) with
/// Howard Hinnant's `days_from_civil` / `civil_from_days` algorithms.
struct CivilDate: Hashable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(dayNumber: Int) {
        let z = dayNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153 // March = 0
        day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    }

    var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }
}
