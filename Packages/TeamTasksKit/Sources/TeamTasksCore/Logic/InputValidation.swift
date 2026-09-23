import Foundation

/// Input rules of docs/CONTRACTS.md §1, shared by the mock backend and the Supabase adapters.
///
/// Adapters apply them before calling the server, so both backends answer the same even where the server alone
/// would not: Supabase Auth accepts a blank display name (the profile trigger falls back to the e-mail), does not
/// trim e-mails, and Postgres rejects U+0000 with a generic `22P05`.
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
}
