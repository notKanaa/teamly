import Foundation
import Supabase
import TeamTasksCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Maps every failure of the Supabase stack to `AppError` (docs/CONTRACTS.md §4.2, §9).
///
/// `CancellationError` is passed through unchanged: view models ignore it (a cancelled SwiftUI `.task` must not
/// surface « annulé »).
enum SupabaseErrorMapping {
    // MARK: - PostgREST

    /// The JSON error body of PostgREST: `{"code": "P0001", "message": "last_admin", "details": …, "hint": …}`.
    struct PostgrestErrorBody: Decodable, Sendable {
        let code: String?
        let message: String?
    }

    /// A non-2xx PostgREST answer → `BackendErrorMapper` (message first, then SQLSTATE, then HTTP status).
    static func postgrest(status: Int, body: Data) -> AppError {
        let error = try? JSONDecoder().decode(PostgrestErrorBody.self, from: body)
        let mapped = BackendErrorMapper.map(code: error?.code, message: error?.message, httpStatus: status)
        // No usable body (e.g. a gateway error page): at least name the HTTP status.
        if case let .unknown(detail) = mapped, detail.isEmpty {
            return .unknown("HTTP \(status)")
        }
        return mapped
    }

    // MARK: - Transport

    /// Network-level failures: `URLError` → `.network` (cancellation → `CancellationError`).
    static func transport(_ error: any Error) -> any Error {
        if error is CancellationError || error is AppError { return error }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : AppError.network
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorCancelled ? CancellationError() : AppError.network
        }
        return AppError.unknown(String(describing: error))
    }

    // MARK: - Auth

    /// Where an Auth error happened: a few codes mean something specific to one call.
    enum AuthContext: Sendable {
        case general
        case signIn
        case verifyOTP
    }

    /// Maps an error thrown by `AuthClient` (Supabase Auth / GoTrue).
    static func auth(_ error: any Error, context: AuthContext = .general) -> any Error {
        if error is CancellationError || error is AppError { return error }
        guard let authError = error as? AuthError else { return transport(error) }
        switch authError {
        case .sessionMissing:
            return AppError.notAuthenticated
        case .weakPassword:
            return AppError.weakPassword
        case let .api(message, errorCode, _, response):
            return auth(code: errorCode.rawValue, message: message, httpStatus: response.statusCode, context: context)
        default:
            return AppError.unknown(authError.message)
        }
    }

    /// Supabase Auth error codes (`error_code`) → `AppError`.
    static func auth(code: String, message: String, httpStatus: Int, context: AuthContext = .general) -> AppError {
        switch (context, code) {
        case (.signIn, "validation_failed"):
            return .invalidCredentials
        case (.verifyOTP, "validation_failed"), (.verifyOTP, "otp_disabled"), (.verifyOTP, "invalid_credentials"):
            return .otpInvalid
        default:
            break
        }
        switch code {
        case "invalid_credentials": return .invalidCredentials
        case "user_already_exists", "email_exists": return .emailAlreadyUsed
        case "weak_password": return .weakPassword
        case "email_address_invalid": return .invalidEmail
        case "email_not_confirmed": return .emailNotConfirmed
        case "otp_expired": return .otpInvalid
        case "over_email_send_rate_limit": return .emailRateLimited
        case "over_request_rate_limit": return .rateLimited
        case "session_not_found", "session_expired", "refresh_token_not_found", "refresh_token_already_used",
             "bad_jwt", "no_authorization", "user_not_found":
            return .notAuthenticated
        case "validation_failed": return .invalidInput
        default: break
        }
        // Servers older than the `error_code` field: match the historical messages.
        switch message {
        case "Invalid login credentials": return .invalidCredentials
        case "User already registered": return .emailAlreadyUsed
        default: break
        }
        switch httpStatus {
        case 401: return .notAuthenticated
        case 429: return .rateLimited
        default: return .unknown(code == "unknown" ? message : "\(code) \(message)")
        }
    }
}
