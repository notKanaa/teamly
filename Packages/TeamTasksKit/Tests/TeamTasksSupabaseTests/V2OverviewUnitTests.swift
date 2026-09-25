import Foundation
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The v2 reads of « Mes tâches » bounded by a completion date and of the groups overview (docs/CONTRACTS-V2.md §10),
/// against a fake PostgREST: the requests sent, the aggregation, and the pages of the reads that fill PostgREST's
/// 1000 rows.
@Suite struct V2OverviewUnitTests {
    /// Group ids in Postgres `uuid` order: A < B < C…
    static func groupId(_ index: Int) -> UUID {
        uuid("\(index)0000000-0000-4000-8000-00000000000\(index)")
    }

    static let a = groupId(1)
    static let b = groupId(2)
    static let c = groupId(3)
    /// Monday 2026-09-21 00:00 UTC.
    static let since = PostgresTimestamp.date(epochMicroseconds: 1_789_948_800_000_000)
    static let sinceText = "2026-09-21T00:00:00.000000Z"

    static func services(_ transport: any HTTPTransport, me: UUID = Seed.camille) -> AppServices {
        SupabaseBackend.services(for: SupabaseContext(
            configuration: UnitBackend.configuration,
            authStorage: InMemoryAuthStorage(),
            now: { since },
            transport: transport,
            credentials: FixedCredentials(userId: me)
        ))
    }

    static func member(_ group: UUID, _ user: UUID = UUID(), role: String = "member", name: String) -> String {
        let id = RestQuery.uuid(user)
        return #"{"group_id":"\#(RestQuery.uuid(group))","user_id":"\#(id)","role":"\#(role)","#
            + #""joined_at":"2026-09-25T02:25:54.55822+00:00","profile":{"id":"\#(id)","display_name":"\#(name)","#
            + #""avatar_color":"teal","avatar_emoji":null}}"#
    }

    static func members(_ group: UUID, count: Int) -> [String] {
        (0..<count).map { member(group, name: "Membre \($0)") }
    }

    static func task(_ group: UUID, _ status: String = "todo", completedAt: String? = nil) -> String {
        let completion = completedAt.map { #""\#($0)""# } ?? "null"
        return #"{"group_id":"\#(RestQuery.uuid(group))","status":"\#(status)","completed_at":\#(completion)}"#
    }

    static func tasks(_ group: UUID, count: Int, _ status: String = "todo") -> [String] {
        Array(repeating: task(group, status), count: count)
    }

    static func page(_ rows: [String]) -> RoutingTransport.Answer {
        .json(200, "[" + rows.joined(separator: ",") + "]")
    }

    static func inList(_ ids: [UUID]) -> String {
        "group_id=in.(\(ids.map(RestQuery.uuid).joined(separator: ",")))"
    }

    // MARK: - My tasks, bounded

    @Test func myTasksDoneSinceReadsTheTasksNotDoneAndTheRecentOnes() async throws {
        let transport = FakeTransport([.fixture(200, "v2_my_tasks")])
        let tasks = try await UnitBackend.services(transport, me: V2Seed.camille).tasks.myTasks(doneSince: Self.since)
        #expect(!tasks.isEmpty)
        #expect(tasks.allSatisfy { $0.groupName == "Coloc fixture" && $0.groupColor == .coral && $0.myAssignedAt != nil })
        let expected = try Fixture.decode([TaskDTO].self, "v2_my_tasks").map(\.myTaskItem).sorted(by: TaskDTO.creationOrder)
        #expect(tasks == expected, "the items of myTasks(includeDone:)")
        #expect(transport.sent.map(\.target) == [
            "tasks?select=\(RestQueryTests.taskSelect),mine:task_assignees!inner(assigned_at,assigned_by,user_id),"
                + "group:groups(name,color,emoji)&mine.user_id=eq.8488c3bb-3233-4bf9-a1e6-24b66878ba02"
                + "&or=(status.neq.done,completed_at.gte.\(Self.sinceText))",
        ])
    }

    // MARK: - Groups overview

    /// Two reads for all the groups (their ids sorted), aggregated: the members sorted like `members(groupId:)`, the
    /// counts, one overview per group asked in the order asked, the groups without members left out, and the rows with
    /// an enum value unknown to this client left out.
    @Test func overviewsAggregateTheTwoReads() async throws {
        let (camille, lucas) = (Seed.camille, Seed.lucas)
        let transport = RoutingTransport([
            "group_members": [Self.page([
                Self.member(Self.a, lucas, name: "Lucas Bernard"),
                Self.member(Self.b, lucas, role: "admin", name: "Lucas Bernard"),
                Self.member(Self.a, UUID(), role: "owner", name: "Rôle inconnu"),
                Self.member(Self.a, camille, role: "admin", name: "Camille Martin"),
            ])],
            "tasks": [Self.page([
                Self.task(Self.a, "todo"),
                Self.task(Self.a, "in_progress"),
                Self.task(Self.a, "done", completedAt: Self.sinceText),
                Self.task(Self.a, "done", completedAt: "2026-09-20T23:59:59.999999Z"),
                Self.task(Self.a, "archived"),
            ])],
        ])
        let overviews = try await Self.services(transport).groups.overviews(
            groupIds: [Self.b, Self.a, Self.c, Self.a], doneSince: Self.since
        )
        #expect(overviews.map(\.groupId) == [Self.b, Self.a], "the order asked, once each; C has no member visible")
        #expect(overviews[0].members.map(\.user.id) == [lucas])
        #expect(overviews[0].members.first?.role == .admin)
        #expect(overviews[0].openTaskCount == 0 && overviews[0].doneTaskCount == 0)
        #expect(overviews[1].members.map(\.user.id) == [camille, lucas], "admins first, then by name")
        #expect(overviews[1].members.map(\.groupId) == [Self.a, Self.a])
        #expect(overviews[1].members.first?.user.avatarColor == .teal)
        #expect(overviews[1].openTaskCount == 2, "to do and in progress; an unknown status is not counted")
        #expect(overviews[1].doneTaskCount == 1, "done at doneSince (inclusive); an older one is not counted")

        let sortedIds = Self.inList([Self.a, Self.b, Self.c])
        #expect(transport.sent(to: "group_members") == [
            "group_members?select=group_id,user_id,role,joined_at,profile:profiles(id,display_name,avatar_color,avatar_emoji)"
                + "&\(sortedIds)&order=group_id.asc&limit=1000",
        ])
        #expect(transport.sent(to: "tasks") == [
            "tasks?select=group_id,status,completed_at&\(sortedIds)"
                + "&or=(status.neq.done,completed_at.gte.\(Self.sinceText))&order=group_id.asc&limit=1000",
        ])
    }

    /// A full page (1000 rows) may miss rows of its last group: the groups before it are complete, and the next page
    /// reads that group again with the ones after it.
    @Test func aFullPageIsFollowedByTheNextOne() async throws {
        let transport = RoutingTransport([
            "group_members": [
                Self.page(Self.members(Self.a, count: 400) + Self.members(Self.b, count: 600)),
                Self.page(Self.members(Self.b, count: 700) + Self.members(Self.c, count: 1)),
            ],
            "tasks": [Self.page(Self.tasks(Self.a, count: 2) + Self.tasks(Self.c, count: 1, "in_progress"))],
        ])
        let overviews = try await Self.services(transport).groups.overviews(
            groupIds: [Self.c, Self.b, Self.a], doneSince: Self.since
        )
        #expect(overviews.map(\.groupId) == [Self.c, Self.b, Self.a])
        #expect(overviews.map(\.members.count) == [1, 700, 400], "B read again in full on the second page")
        #expect(overviews.map(\.openTaskCount) == [1, 0, 2])
        #expect(transport.sent(to: "group_members").map { $0.contains(Self.inList([Self.a, Self.b, Self.c])) } == [true, false])
        #expect(transport.sent(to: "group_members").last?.contains(Self.inList([Self.b, Self.c])) == true)
        #expect(transport.sent(to: "tasks").count == 1)
    }

    /// A group whose rows fill a page on its own has more rows than a page: it is left out (no figures), the others are
    /// read.
    @Test func aGroupFillingAPageAloneIsLeftOut() async throws {
        let transport = RoutingTransport([
            "group_members": [Self.page([Self.member(Self.a, name: "Anne"), Self.member(Self.b, name: "Bruno")])],
            "tasks": [
                Self.page(Self.tasks(Self.a, count: Limits.readRowsMax)),
                Self.page(Self.tasks(Self.b, count: 3)),
            ],
        ])
        let overviews = try await Self.services(transport).groups.overviews(groupIds: [Self.a, Self.b], doneSince: Self.since)
        #expect(overviews.map(\.groupId) == [Self.b])
        #expect(overviews.first?.openTaskCount == 3)
        #expect(transport.sent(to: "tasks").map { $0.contains(Self.inList([Self.a, Self.b])) } == [true, false])
        #expect(transport.sent(to: "tasks").last?.contains(Self.inList([Self.b])) == true)
    }

    /// The page size counts every row, those with an enum value unknown to this client included: such a full page is
    /// followed by the next one.
    @Test func rowsWithAnUnknownValueCountInThePageSize() async throws {
        let transport = RoutingTransport([
            "group_members": [Self.page([Self.member(Self.a, name: "Anne"), Self.member(Self.b, name: "Bruno")])],
            "tasks": [
                Self.page(Self.tasks(Self.a, count: 600) + Self.tasks(Self.b, count: 400, "archived")),
                Self.page(Self.tasks(Self.b, count: 400, "archived") + Self.tasks(Self.b, count: 2)),
            ],
        ])
        let overviews = try await Self.services(transport).groups.overviews(groupIds: [Self.a, Self.b], doneSince: Self.since)
        #expect(overviews.map(\.openTaskCount) == [600, 2])
        #expect(transport.sent(to: "tasks").count == 2)
    }

    /// At most `overviewMaxPages` pages per read: the groups left after them have no overview.
    @Test func thePagesAreCapped() async throws {
        let groups = (1...7).map(Self.groupId)
        let pages = (0..<SupabaseGroupService.overviewMaxPages).map { index in
            Self.page(Self.tasks(groups[index], count: Limits.readRowsMax - 1) + Self.tasks(groups[index + 1], count: 1))
        }
        let transport = RoutingTransport([
            "group_members": [Self.page(groups.map { Self.member($0, name: "Membre") })],
            "tasks": pages,
        ])
        let overviews = try await Self.services(transport).groups.overviews(groupIds: groups, doneSince: Self.since)
        #expect(SupabaseGroupService.overviewMaxPages == 5)
        #expect(overviews.map(\.groupId) == Array(groups.prefix(5)))
        #expect(overviews.allSatisfy { $0.openTaskCount == Limits.readRowsMax - 1 })
        #expect(transport.sent(to: "tasks").count == 5)
        #expect(transport.sent(to: "group_members").count == 1)
    }

    @Test func noGroupNoRequest() async throws {
        let transport = RoutingTransport([:])
        let overviews = try await Self.services(transport).groups.overviews(groupIds: [], doneSince: Self.since)
        #expect(overviews.isEmpty)
        #expect(transport.sent.isEmpty)
    }

    /// Either read failing fails the call (the groups list then shows its groups without figures).
    @Test func aFailedReadFailsTheOverviews() async throws {
        let transport = RoutingTransport([
            "group_members": [Self.page([Self.member(Self.a, name: "Anne")])],
            "tasks": [.json(503, #"{"message":"unavailable"}"#)],
        ])
        await #expect(throws: AppError.unknown(SupabaseErrorMapping.serverUnavailable)) {
            try await Self.services(transport).groups.overviews(groupIds: [Self.a], doneSince: Self.since)
        }
    }

    @Test func signedOutReadsNeverReachTheServer() async throws {
        let transport = FakeTransport()
        let services = UnitBackend.signedOutServices(transport)
        await #expect(throws: AppError.notAuthenticated) {
            try await services.groups.overviews(groupIds: [Self.a], doneSince: Self.since)
        }
        await #expect(throws: AppError.notAuthenticated) { try await services.tasks.myTasks(doneSince: Self.since) }
        #expect(transport.sent.isEmpty)
    }

    /// The order the pages rely on: Postgres compares `uuid` values byte by byte, like the uppercase `uuidString`s.
    @Test func postgresUUIDOrder() {
        let ids = ["ffffffff-0000-4000-8000-000000000000", "0a000000-0000-4000-8000-000000000000", "a0000000-0000-4000-8000-000000000000"]
            .map(uuid)
        #expect(ids.sorted(by: SupabaseGroupService.postgresOrder).map(RestQuery.uuid) == [
            "0a000000-0000-4000-8000-000000000000", "a0000000-0000-4000-8000-000000000000", "ffffffff-0000-4000-8000-000000000000",
        ])
    }
}

/// Answers each PostgREST path (`group_members`, `tasks`…) from a queue of its own, whatever the order in which
/// concurrent requests arrive, and records what was sent (percent-decoded, relative to `/rest/v1/`).
final class RoutingTransport: HTTPTransport, @unchecked Sendable {
    enum Answer: Sendable {
        case json(Int, String)
    }

    private let lock = NSLock()
    private var queues: [String: [Answer]]
    private var targets: [String] = []

    init(_ queues: [String: [Answer]]) {
        self.queues = queues
    }

    var sent: [String] {
        lock.withLock { targets }
    }

    /// The requests sent to `path`, in order.
    func sent(to path: String) -> [String] {
        sent.filter { $0.hasPrefix(path + "?") }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let target = url.absoluteString.components(separatedBy: "/rest/v1/").last?.removingPercentEncoding ?? url.absoluteString
        let path = String(target.prefix { $0 != "?" })
        let answer: Answer? = lock.withLock {
            targets.append(target)
            guard var queue = queues[path], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            queues[path] = queue
            return next
        }
        guard case let .json(status, body)? = answer,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { throw URLError(.resourceUnavailable) }
        return (Data(body.utf8), response)
    }
}
