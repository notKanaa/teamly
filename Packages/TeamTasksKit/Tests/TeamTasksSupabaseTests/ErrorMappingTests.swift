import Foundation
import Supabase
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// §4.2 error mapping: PostgREST bodies + HTTP status, Supabase Auth codes, transport errors.
@Suite struct ErrorMappingTests {
    struct PostgrestCase: Decodable, Sendable, CustomTestStringConvertible {
        struct Body: Codable, Sendable {
            let code: String?
            let message: String?
        }

        let name: String
        let status: Int
        let body: Body
        let expected: String
        var testDescription: String { name }
    }

    struct AuthCase: Decodable, Sendable, CustomTestStringConvertible {
        struct Body: Decodable, Sendable {
            let code: Int
            let errorCode: String
            let msg: String

            enum CodingKeys: String, CodingKey {
                case code
                case errorCode = "error_code"
                case msg
            }
        }

        let name: String
        let body: Body
        let expected: String
        var testDescription: String { name }
    }

    static let postgrestCases: [PostgrestCase] = (try? Fixture.plain([PostgrestCase].self, "postgrest_errors")) ?? []
    /// Every v2 error code (docs/CONTRACTS-V2.md §3), captured from the local stack.
    static let v2PostgrestCases: [PostgrestCase] = (try? Fixture.plain([PostgrestCase].self, "postgrest_errors_v2")) ?? []
    static let authCases: [AuthCase] = (try? Fixture.plain([AuthCase].self, "auth_errors")) ?? []

    @Test func fixturesAreLoaded() {
        #expect(Self.postgrestCases.count == 7)
        #expect(Self.v2PostgrestCases.count == 9)
        #expect(Self.authCases.count == 6)
    }

    /// Captured error bodies, mapped with their real HTTP status.
    @Test(arguments: postgrestCases + v2PostgrestCases)
    func capturedPostgrestErrors(_ example: PostgrestCase) throws {
        let body = try JSONEncoder().encode(example.body)
        let expected = try #require(AppErrorName.all[example.expected])
        #expect(SupabaseErrorMapping.postgrest(status: example.status, body: body) == expected)
    }

    /// The v2 codes: every one of them has a case of its own (never `.unknown`).
    @Test func v2CodesAreMappedByMessage() {
        func map(_ message: String, _ code: String = "P0001", _ status: Int = 400) -> AppError {
            SupabaseErrorMapping.postgrest(status: status, body: Data(#"{"code":"\#(code)","message":"\#(message)"}"#.utf8))
        }
        #expect(map("invalid_color") == .invalidAppearance)
        #expect(map("invalid_emoji") == .invalidAppearance)
        #expect(map("invalid_recurrence") == .invalidRecurrence)
        #expect(map("recurrence_requires_due_date") == .recurrenceNeedsDueDate)
        #expect(map("invalid_rotation") == .invalidRotation)
        #expect(map("invalid_item_title") == .invalidChecklistItem)
        #expect(map("too_many_items") == .tooManyChecklistItems)
        #expect(map("item_not_found") == .notFound)
        #expect(map("invalid_input", "23502") == .invalidInput)
        // Whatever the status: the message decides.
        #expect(map("invalid_rotation", "P0001", 500) == .invalidRotation)
    }

    @Test func messageFirstThenSQLStateThenStatus() {
        func map(_ status: Int, _ json: String) -> AppError {
            SupabaseErrorMapping.postgrest(status: status, body: Data(json.utf8))
        }
        #expect(map(403, #"{"code":"42501","message":"forbidden_fields"}"#) == .forbiddenFields)
        #expect(map(400, #"{"code":"P0001","message":"rate_limited"}"#) == .rateLimited)
        #expect(map(400, #"{"code":"P0001","message":"group_not_found"}"#) == .notFound)
        #expect(map(400, #"{"code":"P0001","message":"too_many_assignees"}"#) == .tooManyAssignees)
        #expect(map(400, #"{"code":"P0001","message":"assignee_not_member"}"#) == .assigneeNotMember)
        #expect(map(400, #"{"code":"P0001","message":"not_authenticated"}"#) == .notAuthenticated)
        #expect(map(403, #"{"code":"42501","message":"immutable_field"}"#) == .forbidden)
        // PostgREST's own 42501: 401 without a session, 403 for a missing privilege.
        #expect(map(401, #"{"code":"42501","message":"permission denied for table tasks"}"#) == .notAuthenticated)
        #expect(map(403, #"{"code":"42501","message":"permission denied for table tasks"}"#) == .forbidden)
        #expect(map(401, #"{"code":"PGRST303","message":"JWT expired"}"#) == .notAuthenticated)
        #expect(map(409, #"{"code":"23505","message":"duplicate key value"}"#) == .conflict)
        #expect(map(400, "") == .unknown("HTTP 400"))
        #expect(map(400, #"{"code":"PGRST100","message":"failed to parse filter"}"#) == .unknown("PGRST100 failed to parse filter"))
    }

    /// Temporary failures of the hosted project (e.g. while a paused free project resumes) are a retryable French
    /// message, never the English internals (review ADP-5).
    @Test func temporaryServerFailuresAreRetryableAndFrench() {
        func map(_ status: Int, _ json: String) -> AppError {
            SupabaseErrorMapping.postgrest(status: status, body: Data(json.utf8))
        }
        let unavailable = AppError.unknown(SupabaseErrorMapping.serverUnavailable)
        #expect(map(503, #"{"code":"PGRST002","message":"Could not query the database for the schema cache. Retrying.","details":null,"hint":null}"#) == unavailable)
        #expect(map(503, #"{"code":"PGRST001","message":"Database client error. Retrying the connection.","details":null,"hint":null}"#) == unavailable)
        #expect(map(504, #"{"code":"PGRST003","message":"Timed out acquiring connection from connection pool.","details":null,"hint":null}"#) == unavailable)
        #expect(map(500, #"{"code":"57014","message":"canceling statement due to statement timeout","details":null,"hint":null}"#) == unavailable)
        #expect(map(429, #"{"message":"Too many requests"}"#) == unavailable)
        #expect(map(502, "<html>Bad gateway</html>") == unavailable)
        #expect(map(503, "") == unavailable)
        // A business error keeps its meaning whatever the status.
        #expect(map(500, #"{"code":"P0001","message":"last_admin"}"#) == .lastAdmin)
        #expect(unavailable.messageFR == "Une erreur est survenue. (le serveur est momentanément indisponible, réessaie dans un instant)")
    }

    @Test(arguments: authCases)
    func capturedAuthErrors(_ example: AuthCase) throws {
        let expected = try #require(AppErrorName.all[example.expected])
        let mapped = SupabaseErrorMapping.auth(code: example.body.errorCode, message: example.body.msg, httpStatus: example.body.code)
        #expect(mapped == expected)
    }

    @Test func authErrorCodes() {
        func map(_ code: String, _ status: Int = 400, _ context: SupabaseErrorMapping.AuthContext = .general) -> AppError {
            SupabaseErrorMapping.auth(code: code, message: "message", httpStatus: status, context: context)
        }
        #expect(map("invalid_credentials") == .invalidCredentials)
        #expect(map("user_already_exists", 422) == .emailAlreadyUsed)
        #expect(map("email_exists", 422) == .emailAlreadyUsed)
        #expect(map("weak_password", 422) == .weakPassword)
        #expect(map("email_address_invalid") == .invalidEmail)
        #expect(map("otp_expired", 403) == .otpInvalid)
        #expect(map("over_email_send_rate_limit", 429) == .emailRateLimited)
        #expect(map("email_not_confirmed") == .emailNotConfirmed)
        #expect(map("session_not_found", 403) == .notAuthenticated)
        #expect(map("refresh_token_not_found") == .notAuthenticated)
        #expect(map("validation_failed") == .invalidInput)
        #expect(map("validation_failed", 400, .signIn) == .invalidCredentials)
        #expect(map("validation_failed", 400, .verifyOTP) == .otpInvalid)
        #expect(map("something_new", 401) == .notAuthenticated)
        #expect(map("something_new", 429) == .unknown(SupabaseErrorMapping.authRateLimited))
        #expect(map("something_new", 500) == .unknown(SupabaseErrorMapping.serverUnavailable))
        #expect(map("something_new", 400) == .unknown("something_new"), "the English message is not shown")
        #expect(SupabaseErrorMapping.auth(code: "unknown", message: "Something odd", httpStatus: 400) == .unknown(SupabaseErrorMapping.unexpectedAnswer))
        // Servers without `error_code`.
        #expect(SupabaseErrorMapping.auth(code: "unknown", message: "Invalid login credentials", httpStatus: 400) == .invalidCredentials)
        #expect(SupabaseErrorMapping.auth(code: "unknown", message: "User already registered", httpStatus: 422) == .emailAlreadyUsed)
    }

    /// Codes of a hosted project (review ADP-2 / ADP-5): French messages, never the English internals.
    @Test func hostedAuthCodes() {
        func map(_ code: String, _ status: Int) -> AppError {
            SupabaseErrorMapping.auth(code: code, message: "English message", httpStatus: status)
        }
        #expect(map("email_address_not_authorized", 400) == .unknown(SupabaseErrorMapping.emailDeliveryUnavailable))
        #expect(map("over_request_rate_limit", 429) == .unknown(SupabaseErrorMapping.authRateLimited))
        #expect(map("over_email_send_rate_limit", 429) == .emailRateLimited)
        #expect(map("signup_disabled", 422) == .unknown(SupabaseErrorMapping.signupDisabled))
        #expect(map("email_provider_disabled", 422) == .unknown(SupabaseErrorMapping.emailProviderDisabled))
        #expect(map("user_banned", 400) == .unknown(SupabaseErrorMapping.userBanned))
        #expect(map("reauthentication_needed", 400) == .unknown(SupabaseErrorMapping.reauthenticationNeeded))
        #expect(map("captcha_failed", 400) == .unknown(SupabaseErrorMapping.captchaFailed))
        #expect(map("unexpected_failure", 500) == .unknown(SupabaseErrorMapping.serverUnavailable))
        #expect(map("request_timeout", 504) == .unknown(SupabaseErrorMapping.serverUnavailable))
        let details = [
            SupabaseErrorMapping.unexpectedAnswer, SupabaseErrorMapping.serverUnavailable, SupabaseErrorMapping.authRateLimited,
            SupabaseErrorMapping.emailDeliveryUnavailable, SupabaseErrorMapping.signupDisabled,
            SupabaseErrorMapping.emailProviderDisabled, SupabaseErrorMapping.userBanned,
            SupabaseErrorMapping.reauthenticationNeeded, SupabaseErrorMapping.captchaFailed,
        ]
        #expect(details.allSatisfy { !$0.contains("'") })
        #expect(AppError.unknown(SupabaseErrorMapping.emailDeliveryUnavailable).messageFR
            == "Une erreur est survenue. (l’envoi d’e-mails vers cette adresse n’est pas encore possible)")
    }

    @Test func authClientErrors() throws {
        let url = try #require(URL(string: "http://127.0.0.1:54321/auth/v1/token"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil))
        let api = AuthError.api(
            message: "Invalid login credentials", errorCode: .invalidCredentials, underlyingData: Data(), underlyingResponse: response
        )
        #expect(SupabaseErrorMapping.auth(api) as? AppError == .invalidCredentials)
        #expect(SupabaseErrorMapping.auth(AuthError.sessionMissing) as? AppError == .notAuthenticated)
        #expect(SupabaseErrorMapping.auth(AuthError.weakPassword(message: "weak", reasons: ["length"])) as? AppError == .weakPassword)
        #expect(SupabaseErrorMapping.auth(URLError(.timedOut)) as? AppError == .network)
        // An HTML page instead of JSON (captive portal), another AuthError: no English internals.
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The given data was not valid JSON."))
        #expect(SupabaseErrorMapping.auth(decoding) as? AppError == .unknown(SupabaseErrorMapping.unexpectedAnswer))
        #expect(SupabaseErrorMapping.auth(AuthError.implicitGrantRedirect(message: "Not a valid redirect")) as? AppError == .unknown(SupabaseErrorMapping.unexpectedAnswer))
        let serverError = AuthError.api(
            message: "Unexpected error", errorCode: .unexpectedFailure, underlyingData: Data(),
            underlyingResponse: try #require(HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil))
        )
        #expect(SupabaseErrorMapping.auth(serverError) as? AppError == .unknown(SupabaseErrorMapping.serverUnavailable))
    }

    @Test func transportErrors() {
        #expect(SupabaseErrorMapping.transport(URLError(.notConnectedToInternet)) as? AppError == .network)
        #expect(SupabaseErrorMapping.transport(URLError(.cannotConnectToHost)) as? AppError == .network)
        #expect(SupabaseErrorMapping.transport(URLError(.cancelled)) is CancellationError)
        #expect(SupabaseErrorMapping.transport(CancellationError()) is CancellationError)
        #expect(SupabaseErrorMapping.transport(AppError.forbidden) as? AppError == .forbidden)
        struct Odd: Error {}
        #expect(SupabaseErrorMapping.transport(Odd()) as? AppError == .unknown(SupabaseErrorMapping.unexpectedAnswer))
    }
}
