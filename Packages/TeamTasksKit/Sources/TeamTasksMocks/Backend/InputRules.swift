import Foundation
import TeamTasksCore

/// Server-side validation of docs/CONTRACTS.md §1: the shared rules of `InputValidation` (the Supabase adapters
/// apply the same ones before calling the server), plus the membership rule of assignees.
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
}
