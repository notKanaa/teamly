import Foundation
import TeamTasksCore

/// Server-side validation of docs/CONTRACTS.md §1. Strings are trimmed first; lengths count Unicode scalars
/// like Postgres `char_length`.
enum InputRules {
    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func length(_ value: String) -> Int {
        value.unicodeScalars.count
    }

    static func displayName(_ raw: String) throws -> String {
        let value = trimmed(raw)
        guard Limits.displayName.contains(length(value)) else { throw AppError.invalidDisplayName }
        return value
    }

    static func groupName(_ raw: String) throws -> String {
        let value = trimmed(raw)
        guard Limits.groupName.contains(length(value)) else { throw AppError.invalidName }
        return value
    }

    static func title(_ raw: String) throws -> String {
        let value = trimmed(raw)
        guard Limits.taskTitle.contains(length(value)) else { throw AppError.invalidTitle }
        return value
    }

    /// Empty (after trimming) is stored as NULL.
    static func details(_ raw: String) throws -> String? {
        let value = trimmed(raw)
        guard length(value) <= Limits.taskDetailsMax else { throw AppError.invalidDetails }
        return value.isEmpty ? nil : value
    }

    /// ≤ 20 distinct users, all members of the group.
    static func assignees(_ ids: Set<UUID>, groupId: UUID, in data: BackendData) throws {
        guard ids.count <= Limits.maxAssignees else { throw AppError.tooManyAssignees }
        guard ids.allSatisfy({ data.isMember($0, of: groupId) }) else { throw AppError.assigneeNotMember }
    }

    /// Normalized e-mail (trimmed, lowercased) or `.invalidEmail`.
    static func email(_ raw: String) throws -> String {
        let value = normalizedEmail(raw)
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !value.contains(where: { $0.isWhitespace }),
              parts[1].contains("."),
              !parts[1].split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
        else { throw AppError.invalidEmail }
        return value
    }

    static func normalizedEmail(_ raw: String) -> String {
        trimmed(raw).lowercased()
    }

    static func password(_ value: String) throws {
        guard value.count >= Limits.passwordMinLength else { throw AppError.weakPassword }
    }
}
