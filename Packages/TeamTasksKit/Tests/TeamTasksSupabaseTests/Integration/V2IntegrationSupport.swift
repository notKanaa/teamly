import Foundation
import TeamTasksContract
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Helpers of the v2 integration tests (docs/CONTRACTS-V2.md): fresh users on their own client sessions, groups joined
/// by invite code, fixed instants.
enum V2IT {
    /// 2031-01-06T18:00:00Z, a Monday (19:00 in Paris).
    static let monday = Date(timeIntervalSince1970: 1_925_488_800)
    /// 2031-01-31T09:00:00Z (10:00 in Paris).
    static let january31 = Date(timeIntervalSince1970: 1_927_616_400)
    static let weekly = RecurrenceRule(frequency: .weekly, weekdays: [5, 1, 3], timeZoneId: "Europe/Paris")
    static let daily = RecurrenceRule(frequency: .daily, timeZoneId: "Europe/Paris")

    /// A brand-new account, signed in on a client session of its own.
    static func user(_ name: String) async throws -> ContractUser {
        try await SupabaseHarness().makeUser(displayName: name)
    }

    /// A group of `admin` (with its appearance), joined by `members` in order.
    static func group(
        of admin: ContractUser,
        color: ColorKey? = nil,
        emoji: String? = nil,
        joinedBy members: [ContractUser] = []
    ) async throws -> GroupSummary {
        let summary = try await admin.groups.createGroup(name: "Groupe \(UUID().uuidString.prefix(6))", color: color, emoji: emoji)
        let code = try await admin.groups.inviteCode(groupId: summary.id)
        for member in members {
            _ = try await member.groups.join(code: code)
        }
        return summary
    }

    /// The group as listed by `user` (`myGroups`).
    static func listed(_ groupId: UUID, by user: ContractUser) async throws -> GroupSummary {
        try #require(try await user.groups.myGroups().first { $0.id == groupId })
    }

    /// `date` plus one microsecond (the precision of the server's timestamps).
    static func microsecond(after date: Date) -> Date {
        PostgresTimestamp.date(epochMicroseconds: PostgresTimestamp.epochMicroseconds(date) + 1)
    }
}

/// A PostgREST transport that rewrites the answers of the real server, to play a newer server (values this client
/// does not know yet).
struct RewritingTransport: HTTPTransport {
    let base = URLSessionTransport(session: .shared)
    /// Regular expression → replacement, applied to every answer.
    let replacements: [(pattern: String, replacement: String)]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await base.send(request)
        var text = String(decoding: data, as: UTF8.self)
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return (Data(text.utf8), response)
    }
}

extension IntegrationEnvironment {
    /// A client session whose PostgREST answers go through `transport` (Auth and Realtime are the real ones).
    static func makeServices(transport: any HTTPTransport) throws -> AppServices {
        SupabaseBackend.services(for: SupabaseContext(
            configuration: try unwrapConfiguration(), authStorage: InMemoryAuthStorage(), now: { Date() }, transport: transport
        ))
    }
}
