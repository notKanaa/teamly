import Foundation
import TeamTasksCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends HTTP requests (injectable, so unit tests can answer with JSON fixtures).
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// The signed-in user of a client session and a valid access token.
struct Credentials: Sendable, Hashable {
    let userId: UUID
    let accessToken: String
}

/// Provides the credentials of the current session; throws `AppError.notAuthenticated` when signed out.
protocol CredentialsProvider: Sendable {
    func credentials() async throws -> Credentials
    /// The server refused `rejected` although its local expiry had not passed (signing key rotated, device clock
    /// behind, account deleted): refreshes the session and returns the new credentials. When the session cannot be
    /// refreshed (revoked, account deleted), the session is removed (the Auth client emits `.signedOut`) and
    /// `.notAuthenticated` is thrown; offline, `.network`.
    func refreshedCredentials(after rejected: Credentials) async throws -> Credentials
}

/// One PostgREST answer, before error mapping.
struct RestResponse: Sendable {
    let status: Int
    let body: Data

    var isSuccess: Bool { (200..<300).contains(status) }

    /// The mapped error of a non-2xx answer, nil for a success.
    var error: AppError? {
        isSuccess ? nil : SupabaseErrorMapping.postgrest(status: status, body: body)
    }

    /// The server refused the session of the request: HTTP 401 (token refused by PostgREST) or
    /// `not_authenticated` (token accepted, but its account no longer exists). Nothing was written.
    var refusesTheSession: Bool { error == .notAuthenticated }

    /// `not_authenticated` raised by our SQL (`private.require_uid`) with an accepted token: the account of the
    /// token no longer exists.
    var accountIsGone: Bool { status != 401 && refusesTheSession }

    /// The body of a 2xx answer; the mapped error otherwise.
    func data() throws -> Data {
        if let error { throw error }
        return body
    }
}

/// Minimal PostgREST client: the adapters build every request themselves (`RestQuery`) so that the query
/// strings are exactly those of docs/CONTRACTS.md §4.3 and the HTTP status of an error reaches
/// `BackendErrorMapper` (supabase-swift's `PostgrestError` drops it, and 401 vs 403 matters for `42501`).
struct RestClient: Sendable {
    /// `<project>/rest/v1`.
    let restURL: URL
    let apiKey: String
    let transport: any HTTPTransport
    let session: any CredentialsProvider

    init(projectURL: URL, apiKey: String, transport: any HTTPTransport, session: any CredentialsProvider) {
        restURL = projectURL.appendingPathComponent("rest").appendingPathComponent("v1")
        self.apiKey = apiKey
        self.transport = transport
        self.session = session
    }

    /// The current session's credentials (`.notAuthenticated` when there is none).
    func credentials() async throws -> Credentials {
        try await session.credentials()
    }

    /// Sends `request` for the current session and returns the body of a 2xx answer.
    ///
    /// When the server refuses the session (`RestResponse.refusesTheSession`), the session is refreshed once and
    /// the request sent again with the new token: a token refused before its local expiry (signing key rotated,
    /// clock behind) is replaced, and a dead session (revoked, account deleted) fails to refresh, which signs the
    /// device out instead of leaving the app « signed in » with every call failing until the token expires.
    func send(_ build: (Credentials) -> RestRequest) async throws -> Data {
        let credentials = try await credentials()
        let first = try await response(to: build(credentials), credentials: credentials)
        guard first.refusesTheSession else { return try first.data() }
        let fresh = try await session.refreshedCredentials(after: credentials)
        return try await response(to: build(fresh), credentials: fresh).data()
    }

    /// Sends `request` once and returns the body of a 2xx answer (no refresh).
    func send(_ request: RestRequest, credentials: Credentials) async throws -> Data {
        try await response(to: request, credentials: credentials).data()
    }

    /// Sends `request` once and returns the raw answer; only transport failures throw.
    func response(to request: RestRequest, credentials: Credentials) async throws -> RestResponse {
        guard let url = request.url(restURL: restURL) else { throw AppError.misconfigured }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue(apiKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let prefer = request.prefer {
            urlRequest.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        if let body = request.body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try body.encoded()
        }

        do {
            let (data, response) = try await transport.send(urlRequest)
            return RestResponse(status: response.statusCode, body: data)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SupabaseErrorMapping.transport(error)
        }
    }

    /// Sends and decodes the JSON answer.
    func fetch<Value: Decodable>(_ type: Value.Type, _ build: (Credentials) -> RestRequest) async throws -> Value {
        try RestDecoding.decode(type, from: try await send(build))
    }

    /// Sends and decodes a JSON array, leaving out the rows with a value this client does not know
    /// (`LossyRows`): a newer server must not make a whole list unreadable.
    func fetchRows<Row: Decodable>(_ type: Row.Type, _ build: (Credentials) -> RestRequest) async throws -> [Row] {
        try RestDecoding.decode(LossyRows<Row>.self, from: try await send(build)).rows
    }
}

/// JSON decoding of PostgREST answers: timestamps with 0 to 6 fractional digits (`PostgresTimestamp`).
enum RestDecoding {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = PostgresTimestamp.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp \(text)")
            }
            return date
        }
        return decoder
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw AppError.unknown(SupabaseErrorMapping.unexpectedAnswer)
        }
    }
}

// MARK: - Forward compatibility

/// A value of a server enum this client does not know (added by a later migration).
struct UnknownEnumValue: Error, Sendable, Hashable {
    let type: String
    let value: String
}

/// An enum column (`task_status`, `task_priority`, `member_role`): known values decode as usual, an unknown one
/// throws `UnknownEnumValue` (not a `DecodingError`), so that `LossyRows` leaves only that row out. Anywhere else
/// (a single row, an RPC result) it fails the decoding like any malformed answer.
struct Known<Value: RawRepresentable & Sendable & Hashable>: Decodable, Sendable, Hashable where Value.RawValue == String {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Value(rawValue: raw) else {
            throw UnknownEnumValue(type: String(describing: Value.self), value: raw)
        }
        self.value = value
    }
}

/// A JSON array whose rows holding an unknown enum value are left out (they cannot be shown, nor safely edited:
/// an edit would overwrite the unknown value); any other malformed row fails the whole array.
struct LossyRows<Row: Decodable>: Decodable {
    let rows: [Row]
    /// Number of rows left out.
    let skipped: Int

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var rows: [Row] = []
        var skipped = 0
        if let count = container.count {
            rows.reserveCapacity(count)
        }
        while !container.isAtEnd {
            do {
                rows.append(try container.decode(Row.self))
            } catch is UnknownEnumValue {
                // A failed element does not advance the container: step over it.
                _ = try container.decode(SkippedRow.self)
                skipped += 1
            }
        }
        self.rows = rows
        self.skipped = skipped
    }

    private struct SkippedRow: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}
