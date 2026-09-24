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
    static let authCases: [AuthCase] = (try? Fixture.plain([AuthCase].self, "auth_errors")) ?? []

    @Test func fixturesAreLoaded() {
        #expect(Self.postgrestCases.count == 7)
        #expect(Self.authCases.count == 3)
    }

    /// Captured error bodies, mapped with their real HTTP status.
    @Test(arguments: postgrestCases)
    func capturedPostgrestErrors(_ example: PostgrestCase) throws {
        let body = try JSONEncoder().encode(example.body)
        let expected = try #require(AppErrorName.all[example.expected])
        #expect(SupabaseErrorMapping.postgrest(status: example.status, body: body) == expected)
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
        #expect(map(502, "<html>Bad gateway</html>") == .unknown("HTTP 502"))
        #expect(map(503, "") == .unknown("HTTP 503"))
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
        #expect(map("something_new", 429) == .rateLimited)
        #expect(map("something_new", 500) == .unknown("something_new message"))
        // Servers without `error_code`.
        #expect(SupabaseErrorMapping.auth(code: "unknown", message: "Invalid login credentials", httpStatus: 400) == .invalidCredentials)
        #expect(SupabaseErrorMapping.auth(code: "unknown", message: "User already registered", httpStatus: 422) == .emailAlreadyUsed)
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
    }

    @Test func transportErrors() {
        #expect(SupabaseErrorMapping.transport(URLError(.notConnectedToInternet)) as? AppError == .network)
        #expect(SupabaseErrorMapping.transport(URLError(.cannotConnectToHost)) as? AppError == .network)
        #expect(SupabaseErrorMapping.transport(URLError(.cancelled)) is CancellationError)
        #expect(SupabaseErrorMapping.transport(CancellationError()) is CancellationError)
        #expect(SupabaseErrorMapping.transport(AppError.forbidden) as? AppError == .forbidden)
    }
}
