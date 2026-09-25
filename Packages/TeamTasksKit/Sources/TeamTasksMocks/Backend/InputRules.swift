import Foundation
import TeamTasksCore

/// Server-side validation of docs/CONTRACTS.md §1 and docs/CONTRACTS-V2.md §1, §3, §5: the shared rules of
/// `InputValidation` (the Supabase adapters apply most of them before calling the server), plus the rules that need
/// the data: the membership of assignees and of a rotation.
enum InputRules {
    static func trimmed(_ value: String) -> String {
        InputValidation.trimmed(value)
    }

    static func displayName(_ raw: String) throws -> String {
        try InputValidation.displayName(raw)
    }

    static func groupName(_ raw: String) throws -> String {
        try InputValidation.groupName(raw)
    }

    static func title(_ raw: String) throws -> String {
        try InputValidation.taskTitle(raw)
    }

    /// Empty (after trimming) is stored as NULL.
    static func details(_ raw: String) throws -> String? {
        try InputValidation.taskDetails(raw)
    }

    /// NULL or within [1970, 10000) UTC, else `.invalidInput` (SQL `invalid_due_at`).
    static func dueDate(_ date: Date?) throws -> Date? {
        try InputValidation.dueDate(date)
    }

    /// ≤ 20 distinct users, all members of the group.
    static func assignees(_ ids: Set<UUID>, groupId: UUID, in data: BackendData) throws {
        guard ids.count <= Limits.maxAssignees else { throw AppError.tooManyAssignees }
        guard ids.allSatisfy({ data.isMember($0, of: groupId) }) else { throw AppError.assigneeNotMember }
    }

    /// Normalized e-mail (trimmed, lowercased) or `.invalidEmail`.
    static func email(_ raw: String) throws -> String {
        try InputValidation.email(raw)
    }

    static func normalizedEmail(_ raw: String) -> String {
        InputValidation.normalizedEmail(raw)
    }

    /// 8–72 UTF-8 bytes, like Supabase Auth.
    static func password(_ value: String) throws {
        try InputValidation.password(value)
    }

    // MARK: - v2

    /// `private.normalize_emoji`: nil, blank → nil; else 1–16 code points without trimmed or control code points
    /// (`.invalidAppearance`, SQL `invalid_emoji`). A typed `ColorKey` is always a valid color: `invalid_color`
    /// cannot happen through the Swift API.
    static func emoji(_ raw: String?) throws -> String? {
        try InputValidation.emoji(raw)
    }

    /// The recurrence of a draft: nil, or the rule's shape (`.invalidRecurrence`), then a due date
    /// (`.recurrenceNeedsDueDate`).
    static func recurrence(_ rule: RecurrenceRule?, dueAt: Date?) throws -> RecurrenceRule? {
        try InputValidation.recurrence(rule, dueAt: dueAt)
    }

    /// `private.check_rotation` behind the shape rules: a new rotation needs a recurrence, 2–20 distinct ids, all
    /// members of the group, else `.invalidRotation`. Empty = no rotation.
    static func rotation(
        _ ids: [UUID], recurrence: RecurrenceRule?, groupId: UUID, in data: BackendData
    ) throws -> [UUID] {
        let rotation = try InputValidation.rotation(ids, recurrence: recurrence)
        guard rotation.allSatisfy({ data.isMember($0, of: groupId) }) else { throw AppError.invalidRotation }
        return rotation
    }

    /// `private.normalize_item_title`: trimmed, 1–200 code points, else `.invalidChecklistItem`.
    static func checklistItemTitle(_ raw: String) throws -> String {
        try InputValidation.checklistItemTitle(raw)
    }

    /// The initial checklist of `create_task`: every title, then at most 30 items (`.tooManyChecklistItems`).
    static func checklist(_ titles: [String]) throws -> [String] {
        try InputValidation.checklist(titles)
    }
}

/// How the server stores a recurrence rule (docs/CONTRACTS-V2.md §5): the columns `repeat_*`, with
/// `repeat_month_day` set by the server for monthly rules.
enum StoredRecurrence {
    /// The local calendar date (year, month, day) of `date` in the zone `timeZoneId` (`(due_at at time zone tz)::date`).
    /// Reading the components of an instant is unambiguous (a DST change only affects the other direction).
    static func localDate(of date: Date, timeZoneId: String) -> DateComponents? {
        guard let zone = TimeZone(identifier: timeZoneId) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    /// The rule written by `create_task` (and by `update_task` for a task that becomes monthly): the fields sent by
    /// the client, and for a monthly rule `repeat_month_day` = the day of the due date in the rule's time zone.
    /// `rule.monthDay` is never sent by the clients: it is ignored.
    static func created(_ rule: RecurrenceRule, dueAt: Date) -> RecurrenceRule {
        var stored = rule
        stored.monthDay = rule.frequency == .monthly ? localDate(of: dueAt, timeZoneId: rule.timeZoneId)?.day : nil
        return stored
    }

    /// The rule after `update_task` (`tasks_before_update_v2`): `repeat_month_day` is recomputed when the task becomes
    /// monthly, or when the time zone or the local date of the due date changes; otherwise it is kept, so a « 31st »
    /// series stays at 31 on its February 28 occurrence.
    static func updated(_ rule: RecurrenceRule, dueAt: Date, stored: TaskRecord) -> RecurrenceRule {
        guard rule.frequency == .monthly else {
            var result = rule
            result.monthDay = nil
            return result
        }
        let previous = stored.recurrence
        var recompute = previous?.monthDay == nil || previous?.frequency != .monthly
            || previous?.timeZoneId != rule.timeZoneId
        if !recompute {
            let newDate = localDate(of: dueAt, timeZoneId: rule.timeZoneId)
            let oldDate = stored.dueAt.flatMap { localDate(of: $0, timeZoneId: previous?.timeZoneId ?? rule.timeZoneId) }
            recompute = newDate == nil || newDate != oldDate
        }
        guard recompute else {
            var result = rule
            result.monthDay = previous?.monthDay
            return result
        }
        return created(rule, dueAt: dueAt)
    }
}
