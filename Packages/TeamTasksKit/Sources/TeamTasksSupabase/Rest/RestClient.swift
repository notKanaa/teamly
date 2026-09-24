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
    func send(_ build: (Credentials) -> RestRequest) async throws -> Data {
        let credentials = try await credentials()
        return try await send(build(credentials), credentials: credentials)
    }

    func send(_ request: RestRequest, credentials: Credentials) async throws -> Data {
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

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SupabaseErrorMapping.transport(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw SupabaseErrorMapping.postgrest(status: response.statusCode, body: data)
        }
        return data
    }

    /// Sends and decodes the JSON answer.
    func fetch<Value: Decodable>(_ type: Value.Type, _ build: (Credentials) -> RestRequest) async throws -> Value {
        try RestDecoding.decode(type, from: try await send(build))
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
            throw AppError.unknown("réponse inattendue du serveur")
        }
    }
}
