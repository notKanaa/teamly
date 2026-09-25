import Foundation

/// Input rules of docs/CONTRACTS.md §1 and docs/CONTRACTS-V2.md §1, §3, §5, shared by the mock backend and the
/// Supabase adapters.
///
/// Adapters apply them before calling the server, so both backends answer the same even where the server alone
/// would not: Supabase Auth accepts a blank display name (the profile trigger falls back to the e-mail), does not
/// trim e-mails, and Postgres rejects U+0000 with a generic `22P05`.
///
/// v2 order of `create_task` (docs/CONTRACTS-V2.md §3): title → details → due date → `recurrence(_:dueAt:)` →
/// `rotation(_:recurrence:)` then its membership → assignees (without rotation: count, then membership) →
/// `checklist(_:)`. The membership rules need the group's members: an adapter that leaves them to the server must not
/// check anything that comes after them (the checklist) on the client, or its first error could differ.
public enum InputValidation {
    /// Code points trimmed at both ends of every text field: U+0009–U+000D, U+0020, U+0085, U+00A0, U+1680,
    /// U+2000–U+200B, U+2028, U+2029, U+202F, U+205F, U+3000.
    ///
    /// An explicit list because `CharacterSet.whitespacesAndNewlines` differs between Linux and Apple platforms
    /// (U+200B). Must match the class of the SQL `private.clean_text`.
    public static let trimmedCharacters: CharacterSet = {
        let ranges: [ClosedRange<Unicode.Scalar>] = [
            "\u{09}"..."\u{0D}", "\u{20}"..."\u{20}", "\u{85}"..."\u{85}", "\u{A0}"..."\u{A0}",
            "\u{1680}"..."\u{1680}", "\u{2000}"..."\u{200B}", "\u{2028}"..."\u{2029}", "\u{202F}"..."\u{202F}",
            "\u{205F}"..."\u{205F}", "\u{3000}"..."\u{3000}",
        ]
        var set = CharacterSet()
        for range in ranges {
            set.insert(charactersIn: range)
        }
        return set
    }()

    /// Supabase Auth hashes passwords with bcrypt, which reads at most 72 bytes.
    public static let passwordMaxBytes = 72
    /// Supabase Auth refuses longer e-mail addresses.
    public static let emailMaxBytes = 255

    // MARK: - Text fields

    /// `value` without the `trimmedCharacters` at both ends (code point by code point, like the SQL regexp).
    public static func trimmed(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard let first = scalars.firstIndex(where: { !trimmedCharacters.contains($0) }),
              let last = scalars.lastIndex(where: { !trimmedCharacters.contains($0) })
        else { return "" }
        return String(scalars[first...last])
    }

    /// Length as Postgres `char_length` counts it: Unicode scalars.
    public static func length(_ value: String) -> Int {
        value.unicodeScalars.count
    }

    /// Trimmed display name (1–50) or `.invalidDisplayName`.
    public static func displayName(_ raw: String) throws -> String {
        try text(raw, lengths: Limits.displayName, error: .invalidDisplayName)
    }

    /// Trimmed group name (1–60) or `.invalidName`.
    public static func groupName(_ raw: String) throws -> String {
        try text(raw, lengths: Limits.groupName, error: .invalidName)
    }

    /// Trimmed task title (1–200) or `.invalidTitle`.
    public static func taskTitle(_ raw: String) throws -> String {
        try text(raw, lengths: Limits.taskTitle, error: .invalidTitle)
    }

    /// Trimmed task details (≤ 5000, nil when empty) or `.invalidDetails`.
    public static func taskDetails(_ raw: String) throws -> String? {
        let value = try text(raw, lengths: 0...Limits.taskDetailsMax, error: .invalidDetails)
        return value.isEmpty ? nil : value
    }

    /// Accepted due dates (`tasks_due_at_range`): [1970-01-01, 10000-01-01) UTC. Excludes ±infinity and BC
    /// dates, which PostgREST renders in forms no JSON decoder accepts.
    public static let dueDateRange: Range<Date> =
        Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 253_402_300_800)

    /// nil (no due date) or a date inside `dueDateRange`, else `.invalidInput` (SQL `invalid_due_at`).
    /// Checked after the title and the details, before the assignees (same order as the SQL).
    public static func dueDate(_ date: Date?) throws -> Date? {
        guard let date else { return nil }
        guard dueDateRange.contains(date) else { throw AppError.invalidInput }
        return date
    }

    /// Postgres `text` cannot hold U+0000: such input gets the field's validation error.
    private static func text(_ raw: String, lengths: ClosedRange<Int>, error: AppError) throws -> String {
        let value = trimmed(raw)
        guard lengths.contains(length(value)), !value.unicodeScalars.contains("\u{0}") else { throw error }
        return value
    }

    // MARK: - Auth

    /// Trimmed and lowercased e-mail (Supabase Auth stores e-mails lowercased but does not trim them, so the
    /// app normalizes every e-mail it sends to Auth).
    public static func normalizedEmail(_ raw: String) -> String {
        trimmed(raw).lowercased()
    }

    /// The normalized e-mail, or `.invalidEmail` unless it has the HTML5 syntax Supabase Auth checks: before the
    /// `@`, one or more ASCII letters, digits or characters among .!#$%&'*+/=?^_{|}~- and the backtick; after
    /// it, dot-separated labels of 1–63 ASCII letters, digits or hyphens, starting and ending with a letter or
    /// digit (`user@localhost` is valid). At most 255 bytes.
    public static func email(_ raw: String) throws -> String {
        let value = trimmed(raw)
        guard value.utf8.count <= emailMaxBytes, hasEmailSyntax(value) else { throw AppError.invalidEmail }
        return value.lowercased()
    }

    /// Password length in UTF-8 bytes, like Supabase Auth: at least `Limits.passwordMinLength` (`.weakPassword`),
    /// at most `passwordMaxBytes` (`.invalidInput`).
    public static func password(_ value: String) throws {
        let bytes = value.utf8.count
        guard bytes >= Limits.passwordMinLength else { throw AppError.weakPassword }
        guard bytes <= passwordMaxBytes else { throw AppError.invalidInput }
    }

    /// Sign-up input, checked in this order: e-mail, password, display name. Returns the normalized e-mail and
    /// the trimmed display name.
    public static func signUp(email: String, password: String, displayName: String) throws -> (email: String, displayName: String) {
        let email = try self.email(email)
        try self.password(password)
        let name = try self.displayName(displayName)
        return (email, name)
    }

    private static let emailLocalCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-".unicodeScalars)

    private static func hasEmailSyntax(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard let at = scalars.firstIndex(of: "@"), at > 0 else { return false }
        guard scalars[..<at].allSatisfy({ emailLocalCharacters.contains($0) }) else { return false }
        let labels = scalars[(at + 1)...].split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard (1...63).contains(label.count),
                  let first = label.first, let last = label.last,
                  isASCIIAlphanumeric(first), isASCIIAlphanumeric(last)
            else { return false }
            return label.allSatisfy { isASCIIAlphanumeric($0) || $0 == "-" }
        }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    // MARK: - v2: appearance (docs/CONTRACTS-V2.md §1)

    /// A color key from its stored text, exact case (`coral`); nil = automatic. `Coral`, `""` or an unknown key throw
    /// `.invalidAppearance` (SQL `invalid_color`). Typed `ColorKey` values are always valid.
    public static func colorKey(_ raw: String?) throws -> ColorKey? {
        guard let raw else { return nil }
        guard let key = ColorKey(rawValue: raw) else { throw AppError.invalidAppearance }
        return key
    }

    /// The normalized emoji of a group or an avatar (SQL `private.normalize_emoji`): nil stays nil; otherwise
    /// `trimmed(_:)`, and an empty result is nil. What remains must have 1–`Limits.emojiCodePointsMax` code points,
    /// none of them a trimmed code point or a C0/C1 control (`isForbiddenInEmoji`), else `.invalidAppearance`
    /// (SQL `invalid_emoji`). ZWJ sequences, variation selectors, keycaps and flags are accepted.
    public static func emoji(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = trimmed(raw)
        guard !value.isEmpty else { return nil }
        guard value.unicodeScalars.count <= Limits.emojiCodePointsMax,
              !value.unicodeScalars.contains(where: isForbiddenInEmoji)
        else { throw AppError.invalidAppearance }
        return value
    }

    /// Code points refused inside an emoji: U+0000–U+0020, U+007F–U+00A0, U+1680, U+2000–U+200B, U+2028, U+2029,
    /// U+202F, U+205F, U+3000 (the trimmed code points and the C0/C1 controls; U+200D, the ZWJ, is allowed).
    public static func isForbiddenInEmoji(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x20 || (0x7F...0xA0).contains(scalar.value) || trimmedCharacters.contains(scalar)
    }

    // MARK: - v2: recurrence (docs/CONTRACTS-V2.md §5)

    /// Zone names the server accepts that Foundation may list or name differently (`UTC` can read as `GMT`).
    private static let fixedTimeZoneIds: Set<String> = ["UTC", "GMT", "Etc/UTC", "Etc/GMT"]
    private static let knownTimeZoneIds = Set(TimeZone.knownTimeZoneIdentifiers)

    /// True for a time zone name accepted in a recurrence rule: an IANA name that this device knows, exact case
    /// (`Europe/Paris`, `UTC`, `America/Argentina/Buenos_Aires`), except the `posix/…` and `right/…` copies and
    /// `Factory`. POSIX offsets (`UTC+3`), abbreviations (`CEST`) and other cases (`europe/paris`) are refused.
    /// The server checks the same names against PostgreSQL's `pg_timezone_names`.
    public static func isValidTimeZoneId(_ id: String) -> Bool {
        guard !id.hasPrefix("posix/"), !id.hasPrefix("right/"), id != "Factory" else { return false }
        guard knownTimeZoneIds.contains(id) || fixedTimeZoneIds.contains(id) else { return false }
        return TimeZone(identifier: id) != nil
    }

    /// The shape of a rule, else `.invalidRecurrence` (SQL `invalid_recurrence`): `interval` in
    /// 1…`Limits.repeatIntervalMax`; `weekdays` only on a weekly rule, not empty, values in 1…7; `timeZoneId`
    /// accepted by `isValidTimeZoneId(_:)`. `monthDay` is not checked: the server sets it.
    public static func recurrence(_ rule: RecurrenceRule) throws -> RecurrenceRule {
        guard (1...Limits.repeatIntervalMax).contains(rule.interval) else { throw AppError.invalidRecurrence }
        if let weekdays = rule.weekdays {
            guard rule.frequency == .weekly, !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else {
                throw AppError.invalidRecurrence
            }
        }
        guard isValidTimeZoneId(rule.timeZoneId) else { throw AppError.invalidRecurrence }
        return rule
    }

    /// The recurrence of a draft: nil (no repetition), or the rule's shape (`recurrence(_:)`), then a due date is
    /// required (`.recurrenceNeedsDueDate`). Checked after the due date, before the rotation.
    public static func recurrence(_ rule: RecurrenceRule?, dueAt: Date?) throws -> RecurrenceRule? {
        guard let rule else { return nil }
        let checked = try recurrence(rule)
        guard dueAt != nil else { throw AppError.recurrenceNeedsDueDate }
        return checked
    }

    /// A new rotation, except the membership of its users (checked by the backend, with the same error): empty is no
    /// rotation; otherwise it needs a `recurrence`, and `Limits.rotationMin`…`Limits.rotationMax` distinct ids, else
    /// `.invalidRotation`. Checked after the recurrence, before the assignees (which a rotation replaces).
    /// On update, a rotation equal to the task's current one is kept without any check.
    public static func rotation(_ ids: [UUID], recurrence: RecurrenceRule?) throws -> [UUID] {
        guard !ids.isEmpty else { return [] }
        guard recurrence != nil,
              (Limits.rotationMin...Limits.rotationMax).contains(ids.count),
              Set(ids).count == ids.count
        else { throw AppError.invalidRotation }
        return ids
    }

    // MARK: - v2: checklist (docs/CONTRACTS-V2.md §3)

    /// Trimmed checklist item title (1–`Limits.checklistItemTitleMax`), else `.invalidChecklistItem`
    /// (SQL `invalid_item_title`).
    public static func checklistItemTitle(_ raw: String) throws -> String {
        try text(raw, lengths: 1...Limits.checklistItemTitleMax, error: .invalidChecklistItem)
    }

    /// The initial checklist of a new task: every title in order (`checklistItemTitle(_:)`), then at most
    /// `Limits.checklistItemsMax` items (`.tooManyChecklistItems`). Checked last, after the assignees.
    public static func checklist(_ titles: [String]) throws -> [String] {
        let checked = try titles.map { try checklistItemTitle($0) }
        guard checked.count <= Limits.checklistItemsMax else { throw AppError.tooManyChecklistItems }
        return checked
    }
}
