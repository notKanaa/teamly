import Foundation
import TeamTasksCore
@testable import TeamTasksSupabase

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers PostgREST requests with queued responses and records what was sent.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Sent: Sendable {
        let method: String
        /// Path and query, percent-decoded, relative to `/rest/v1/`.
        let target: String
        /// Header names lowercased.
        let headers: [String: String]
        let body: String?
    }

    enum Response: Sendable {
        case json(Int, String)
        case fixture(Int, String)
        case failure(URLError.Code)
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var sentRequests: [Sent] = []

    init(_ responses: [Response] = []) {
        self.responses = responses
    }

    var sent: [Sent] {
        lock.lock()
        defer { lock.unlock() }
        return sentRequests
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let absolute = url.absoluteString
        let target = absolute.components(separatedBy: "/rest/v1/").last?.removingPercentEncoding ?? absolute
        let record = Sent(
            method: request.httpMethod ?? "GET",
            target: target,
            headers: Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }) { _, last in last },
            body: request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        )
        let next: Response? = {
            lock.lock()
            defer { lock.unlock() }
            sentRequests.append(record)
            return responses.isEmpty ? nil : responses.removeFirst()
        }()
        switch next {
        case let .json(status, body)?:
            return (Data(body.utf8), try response(url, status))
        case let .fixture(status, name)?:
            return (try Fixture.data(name), try response(url, status))
        case let .failure(code)?:
            throw URLError(code)
        case nil:
            throw URLError(.resourceUnavailable)
        }
    }

    private func response(_ url: URL, _ status: Int) throws -> HTTPURLResponse {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return response
    }
}

/// Fixed credentials: no Auth involved.
struct FixedCredentials: CredentialsProvider {
    let userId: UUID

    func credentials() async throws -> Credentials {
        Credentials(userId: userId, accessToken: "jeton-de-test")
    }
}

enum UnitBackend {
    static let configuration = SupabaseConfiguration(
        // Nothing listens on port 9: any unexpected network use fails fast.
        url: URL(string: "http://127.0.0.1:9")!,
        publishableKey: "sb_publishable_test"
    )

    /// Services whose PostgREST calls go to `transport`, signed in as `me`.
    static func services(
        _ transport: FakeTransport,
        me: UUID = Seed.camille,
        now: Date = PostgresTimestamp.date(epochMicroseconds: 1_790_244_000_123_456)
    ) -> AppServices {
        SupabaseBackend.services(for: SupabaseContext(
            configuration: configuration,
            authStorage: InMemoryAuthStorage(),
            now: { now },
            transport: transport,
            credentials: FixedCredentials(userId: me)
        ))
    }

    /// Services with the real Auth session (none: signed out) and a recording transport.
    static func signedOutServices(_ transport: FakeTransport) -> AppServices {
        SupabaseBackend.services(for: SupabaseContext(
            configuration: configuration,
            authStorage: InMemoryAuthStorage(),
            now: { Date() },
            transport: transport
        ))
    }
}
