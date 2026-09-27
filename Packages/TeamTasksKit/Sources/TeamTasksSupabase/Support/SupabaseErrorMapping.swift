import Foundation
import Supabase
import TeamTasksCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Maps every failure of the Supabase stack to `AppError` (docs/CONTRACTS.md §4.2, §9).
///
/// `CancellationError` is passed through unchanged: view models ignore it (a cancelled SwiftUI `.task` must not
/// surface « annulé »). Nothing the server says in English reaches the user: the conditions without an `AppError`
/// case of their own become `.unknown` with one of the French details below, which address the user with « tu »
/// (docs/CONTRACTS-V2.md §13).
enum SupabaseErrorMapping {
    // MARK: - French details of `.unknown`

    /// A malformed answer (not JSON, an HTML page of a captive portal, a missing field).
    static let unexpectedAnswer = "réponse inattendue du serveur"
    /// Temporary server-side failure: 5xx, PostgREST `PGRST000`–`PGRST003` (database unreachable, e.g. while a free
    /// project resumes from pause), statement timeout, gateway rate limit, Auth `unexpected_failure`/`request_timeout`.
    static let serverUnavailable = "le serveur est momentanément indisponible, réessaie dans un instant"
    /// Supabase Auth request rate limit (a window of minutes, unlike the one-hour limit of `join_group_by_code`).
    static let authRateLimited = "trop de tentatives, réessaie dans quelques minutes"
    /// `email_address_not_authorized`: the project's built-in SMTP only delivers to its team members until a custom
    /// SMTP server is configured.
    static let emailDeliveryUnavailable = "l’envoi d’e-mails vers cette adresse n’est pas encore possible"
    static let signupDisabled = "les inscriptions sont fermées pour le moment"
    static let emailProviderDisabled = "la connexion par e-mail est désactivée pour le moment"
    static let userBanned = "ce compte est suspendu"
    static let reauthenticationNeeded = "reconnecte-toi, puis réessaie"
    static let captchaFailed = "la vérification de sécurité a échoué"

    // MARK: - PostgREST

    /// The JSON error body of PostgREST: `{"code": "P0001", "message": "last_admin", "details": …, "hint": …}`.
    struct PostgrestErrorBody: Decodable, Sendable {
        let code: String?
        let message: String?
    }

    /// PostgREST codes of a database it cannot reach (connection, schema cache, pool timeout).
    static let temporaryPostgrestCodes: Set<String> = ["PGRST000", "PGRST001", "PGRST002", "PGRST003", "57014"]

    /// A non-2xx PostgREST answer → `BackendErrorMapper` (message first, then SQLSTATE, then HTTP status).
    static func postgrest(status: Int, body: Data) -> AppError {
        let error = try? JSONDecoder().decode(PostgrestErrorBody.self, from: body)
        let mapped = BackendErrorMapper.map(code: error?.code, message: error?.message, httpStatus: status)
        guard case let .unknown(detail) = mapped else { return mapped }
        let isTemporaryCode = error?.code.map { temporaryPostgrestCodes.contains($0) } ?? false
        if status >= 500 || status == 429 || isTemporaryCode {
            return .unknown(serverUnavailable)
        }
        // No usable body: at least name the HTTP status.
        return detail.isEmpty ? .unknown("HTTP \(status)") : mapped
    }

    // MARK: - Transport

    /// Network-level failures: `URLError` → `.network` (cancellation → `CancellationError`); anything else (e.g. a
    /// `DecodingError` of an unexpected answer) → `.unknown(unexpectedAnswer)`.
    static func transport(_ error: any Error) -> any Error {
        if error is CancellationError || error is AppError { return error }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : AppError.network
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorCancelled ? CancellationError() : AppError.network
        }
        return AppError.unknown(unexpectedAnswer)
    }

    // MARK: - Storage (docs/CONTRACTS-V3.md §6)

    /// Maps an error of the storage client (the bucket `task-photos`): a `StorageError` (the body of a refusal) or an
    /// `HTTPError` (a refusal without such a body) by its status and code; transport failures as usual.
    static func storage(_ error: any Error) -> any Error {
        if error is CancellationError || error is AppError { return error }
        if let storageError = error as? StorageError {
            return storage(status: storageError.statusCode.flatMap { Int($0) }, code: storageError.error, message: storageError.message)
        }
        if let httpError = error as? HTTPError {
            let body = try? JSONDecoder().decode(StorageErrorBody.self, from: httpError.data)
            return storage(status: httpError.response.statusCode, code: body?.error, message: body?.message ?? "")
        }
        return transport(error)
    }

    /// The JSON error body of the Storage API: `{"statusCode": "413", "error": "Payload too large", "message": …}`.
    struct StorageErrorBody: Decodable, Sendable {
        let error: String?
        let message: String?
    }

    /// A refusal of the Storage API → `AppError`:
    /// - the bucket's limits (5 MB, JPEG / PNG / HEIC): `.invalidPhoto`;
    /// - a policy refusal (not a member of the path's group, not the owner): `.forbidden`; an expired session:
    ///   `.notAuthenticated`;
    /// - no such object (or bucket): `.notFound`; an object already at that path: `.conflict`;
    /// - 5xx and 429: the temporary failure of the server.
    static func storage(status: Int?, code: String?, message: String) -> AppError {
        let text = "\(code ?? "") \(message)".lowercased()
        if status == 413 || text.contains("too large") || text.contains("maximum allowed size") || text.contains("mime") {
            return .invalidPhoto
        }
        if text.contains("row-level security") || text.contains("row level security") {
            return .forbidden
        }
        if text.contains("not found") || text.contains("nosuchkey") || text.contains("nosuchbucket") {
            return .notFound
        }
        if text.contains("duplicate") || text.contains("already exists") {
            return .conflict
        }
        switch status ?? 0 {
        case 401: return .notAuthenticated
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        case 429, 500...: return .unknown(serverUnavailable)
        default: return .unknown(unexpectedAnswer)
        }
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
            return AppError.unknown(unexpectedAnswer)
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
        case "over_request_rate_limit": return .unknown(authRateLimited)
        case "session_not_found", "session_expired", "refresh_token_not_found", "refresh_token_already_used",
             "bad_jwt", "no_authorization", "user_not_found":
            return .notAuthenticated
        case "validation_failed": return .invalidInput
        case "email_address_not_authorized": return .unknown(emailDeliveryUnavailable)
        case "signup_disabled": return .unknown(signupDisabled)
        case "email_provider_disabled": return .unknown(emailProviderDisabled)
        case "user_banned": return .unknown(userBanned)
        case "reauthentication_needed", "reauthentication_not_valid": return .unknown(reauthenticationNeeded)
        case "captcha_failed": return .unknown(captchaFailed)
        case "unexpected_failure", "request_timeout": return .unknown(serverUnavailable)
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
        case 429: return .unknown(authRateLimited)
        case 500...: return .unknown(serverUnavailable)
        // The server's message is English: only the code is shown (for support).
        default: return .unknown(code == "unknown" ? unexpectedAnswer : code)
        }
    }
}
