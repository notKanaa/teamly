import Foundation
import TeamTasksContract
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension IntegrationTests {
    /// The groups overview against the local stack (docs/CONTRACTS-V2.md §10), read in pages of 4 rows instead of
    /// 1000: the real server orders the rows by group, applies the limit, and the adapter follows with the next pages.
    /// (The reads themselves, with the default page size, are the contract scenarios `reads.groupOverviews` and
    /// `reads.myTasksDoneSince`.)
    @Suite struct V2OverviewIntegrationTests {
        @Test(.timeLimit(.minutes(1)))
        func overviewPagesOnTheRealServer() async throws {
            let recorder = RecordingTransport()
            let alice = try await SupabaseHarness.signUp(
                displayName: "Alice Pages", services: try IntegrationEnvironment.makeServices(transport: recorder)
            )
            let bob = try await V2IT.user("Bob Pages")
            let carol = try await V2IT.user("Carol Pages")
            let big = try await V2IT.group(of: alice, joinedBy: [bob, carol])
            let solo = try await V2IT.group(of: alice)
            let pair = try await V2IT.group(of: bob, joinedBy: [alice])
            let busy = try await V2IT.group(of: alice)
            func makeTasks(_ count: Int, in group: GroupSummary, by user: ContractUser) async throws -> [TaskItem] {
                var tasks: [TaskItem] = []
                for index in 1...count {
                    tasks.append(try await user.tasks.create(groupId: group.id, draft: TaskDraft(title: "Page \(index)")))
                }
                return tasks
            }
            let bigTasks = try await makeTasks(3, in: big, by: alice)
            _ = try await makeTasks(2, in: solo, by: alice)
            _ = try await makeTasks(1, in: pair, by: bob)
            _ = try await makeTasks(4, in: busy, by: alice)
            let done = try await alice.tasks.setStatus(taskId: bigTasks[2].id, status: .done)
            let since = try #require(done.completedAt)

            // One page per read: everything.
            let ids = [big.id, solo.id, pair.id, busy.id]
            let whole = try await alice.groups.overviews(groupIds: ids, doneSince: since)
            #expect(whole.map(\.groupId) == ids)
            #expect(whole.map(\.members.count) == [3, 1, 2, 1])
            #expect(whole.map(\.openTaskCount) == [2, 2, 1, 4])
            #expect(whole.map(\.doneTaskCount) == [1, 0, 0, 0])

            // Pages of 4 rows: 7 member rows and 10 task rows need several pages. « busy » and its 4 tasks fill a page
            // on their own: that group is left out; every other group is read completely.
            let service = try #require(alice.groups as? SupabaseGroupService)
            recorder.reset()
            let paged = try await service.overviews(groupIds: ids, doneSince: since, pageSize: 4)
            #expect(paged == whole.filter { $0.groupId != busy.id })
            #expect(recorder.sent(to: "group_members").count >= 2)
            #expect(recorder.sent(to: "tasks").count >= 2)
            #expect(recorder.sent.allSatisfy { $0.contains("&order=group_id.asc&limit=4") })
        }
    }
}

/// The real PostgREST transport, recording the requests sent (percent-decoded, relative to `/rest/v1/`).
final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let base = URLSessionTransport(session: .shared)
    private let lock = NSLock()
    private var targets: [String] = []

    var sent: [String] {
        lock.withLock { targets }
    }

    /// The requests sent to `path`, in order.
    func sent(to path: String) -> [String] {
        sent.filter { $0.hasPrefix(path + "?") }
    }

    func reset() {
        lock.withLock { targets.removeAll() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let absolute = request.url?.absoluteString ?? ""
        let target = absolute.components(separatedBy: "/rest/v1/").last?.removingPercentEncoding ?? absolute
        lock.withLock { targets.append(target) }
        return try await base.send(request)
    }
}
