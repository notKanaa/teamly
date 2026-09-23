import Foundation

/// Maps backend (PostgREST / Postgres) errors to `AppError`.
/// Server convention (see docs/CONTRACTS.md): business errors use SQLSTATE `P0001` with the error code
/// as the message (e.g. `last_admin`); permission errors use SQLSTATE `42501`.
public enum BackendErrorMapper {
    /// Business error codes raised by the SQL functions/triggers (exception message).
    public static let messageCodes: [String: AppError] = [
        "not_authenticated": .notAuthenticated,
        "invalid_display_name": .invalidDisplayName,
        "invalid_name": .invalidName,
        "invalid_title": .invalidTitle,
        "invalid_details": .invalidDetails,
        "invalid_due_at": .invalidInput,
        "invalid_input": .invalidInput,
        "invalid_code": .invalidCode,
        "rate_limited": .rateLimited,
        "forbidden": .forbidden,
        "forbidden_fields": .forbiddenFields,
        "immutable_field": .forbidden,
        "last_admin": .lastAdmin,
        "not_member": .notMember,
        "cannot_remove_self": .cannotRemoveSelf,
        "assignee_not_member": .assigneeNotMember,
        "too_many_assignees": .tooManyAssignees,
        "task_not_found": .notFound,
        "group_not_found": .notFound,
    ]

    /// - Parameters:
    ///   - code: SQLSTATE or PostgREST code (e.g. `P0001`, `42501`, `PGRST116`).
    ///   - message: error message (business code for `P0001`).
    ///   - httpStatus: HTTP status if known.
    public static func map(code: String?, message: String?, httpStatus: Int? = nil) -> AppError {
        if let message, let mapped = messageCodes[message.trimmingCharacters(in: .whitespacesAndNewlines)] {
            return mapped
        }
        // PostgREST answers a request without a valid session (anon role) with HTTP 401 + 42501.
        // Our own 42501 errors ('forbidden', 'forbidden_fields') are HTTP 403 and matched above.
        if code == "42501", httpStatus == 401 { return .notAuthenticated }
        switch code {
        case "42501": return .forbidden
        case "23505": return .conflict
        case "23514", "22001", "22P02", "22P05", "23502": return .invalidInput
        case "23503": return .notFound
        case "PGRST116": return .notFound
        case "PGRST301", "PGRST302": return .notAuthenticated
        default: break
        }
        switch httpStatus {
        case 401: return .notAuthenticated
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        default: break
        }
        return .unknown([code, message].compactMap { $0 }.joined(separator: " "))
    }
}
