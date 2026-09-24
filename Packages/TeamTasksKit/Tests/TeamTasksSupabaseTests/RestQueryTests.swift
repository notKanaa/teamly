import Foundation
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

/// The PostgREST requests are those of docs/CONTRACTS.md §4.3, verbatim, with microsecond timestamp filters.
@Suite struct RestQueryTests {
    let me = Seed.camille
    let group = Seed.lilas
    let task = Seed.courses
    /// 2026-09-24T10:00:00.123456Z
    let now = PostgresTimestamp.date(epochMicroseconds: 1_790_244_000_123_456)

    @Test func myGroups() {
        let request = RestQuery.myGroups(me: me)
        #expect(request.method == .get)
        #expect(request.path == "group_members")
        #expect(request.readableQuery == "select=role,group:groups(*)&user_id=eq.11111111-1111-4111-8111-111111111111")
    }

    @Test func members() {
        let request = RestQuery.members(groupId: group)
        #expect(request.path == "group_members")
        #expect(request.readableQuery
            == "select=user_id,role,joined_at,profile:profiles(id,display_name)&group_id=eq.a0000000-0000-4000-8000-000000000001")
    }

    @Test func inviteCode() {
        let request = RestQuery.inviteCode(groupId: group)
        #expect(request.path == "group_invites")
        #expect(request.readableQuery == "select=code&group_id=eq.a0000000-0000-4000-8000-000000000001")
    }

    @Test func groupTasksHideOldDoneTasksWithAMicrosecondCutoff() {
        let recent = RestQuery.groupTasks(groupId: group, includeOldDone: false, now: now)
        #expect(recent.path == "tasks")
        // now − 30 × 86 400 s, inclusive, 6 fractional digits in UTC.
        #expect(recent.readableQuery
            == "select=*,assignees:task_assignees(user_id)&group_id=eq.a0000000-0000-4000-8000-000000000001"
            + "&or=(status.neq.done,completed_at.gte.2026-08-25T10:00:00.123456Z)")
        let all = RestQuery.groupTasks(groupId: group, includeOldDone: true, now: now)
        #expect(all.readableQuery
            == "select=*,assignees:task_assignees(user_id)&group_id=eq.a0000000-0000-4000-8000-000000000001")
    }

    @Test func cutoffIsThirtyTimes86400Seconds() {
        // Across the end of daylight saving time in Europe (2026-10-25): still exactly 2 592 000 s.
        let later = PostgresTimestamp.date(epochMicroseconds: 1_793_700_000_000_001)
        let cutoff = RestQuery.oldDoneCutoff(now: later)
        #expect(PostgresTimestamp.epochMicroseconds(cutoff) == 1_793_700_000_000_001 - 2_592_000_000_000)
    }

    @Test func oneTask() {
        let request = RestQuery.task(id: task)
        #expect(request.readableQuery
            == "select=*,assignees:task_assignees(user_id)&id=eq.b0000000-0000-4000-8000-000000000002")
    }

    @Test func myTasks() {
        let open = RestQuery.myTasks(me: me, includeDone: false)
        #expect(open.path == "tasks")
        #expect(open.readableQuery
            == "select=*,assignees:task_assignees(user_id),mine:task_assignees!inner(assigned_at,user_id),group:groups(name)"
            + "&mine.user_id=eq.11111111-1111-4111-8111-111111111111&status=neq.done")
        let all = RestQuery.myTasks(me: me, includeDone: true)
        #expect(all.readableQuery
            == "select=*,assignees:task_assignees(user_id),mine:task_assignees!inner(assigned_at,user_id),group:groups(name)"
            + "&mine.user_id=eq.11111111-1111-4111-8111-111111111111")
    }

    @Test func assignmentsSinceIsExclusiveWithMicroseconds() {
        let request = RestQuery.assignments(me: me, since: now)
        #expect(request.path == "task_assignees")
        #expect(request.readableQuery
            == "select=task_id,group_id,assigned_by,assigned_at,task:tasks(title,due_at,group:groups(name))"
            + "&user_id=eq.11111111-1111-4111-8111-111111111111&assigned_at=gt.2026-09-24T10:00:00.123456Z"
            + "&or=(assigned_by.is.null,assigned_by.neq.11111111-1111-4111-8111-111111111111)&order=assigned_at.asc")
    }

    @Test func profileAndPushTopic() {
        #expect(RestQuery.myProfile(me: me).readableQuery == "select=id,display_name&id=eq.11111111-1111-4111-8111-111111111111")
        #expect(RestQuery.myProfile(me: me).path == "profiles")
        #expect(RestQuery.pushTopic(me: me).readableQuery == "select=topic&user_id=eq.11111111-1111-4111-8111-111111111111")
        #expect(RestQuery.pushTopic(me: me).path == "push_subscriptions")
    }

    @Test func updateDisplayNameIsAPatchReturningTheRow() throws {
        let request = RestQuery.updateDisplayName(me: me, name: "Camille M.")
        #expect(request.method == .patch)
        #expect(request.path == "profiles")
        #expect(request.readableQuery == "id=eq.11111111-1111-4111-8111-111111111111")
        #expect(request.prefer == "return=representation")
        #expect(String(decoding: try #require(request.body).encoded(), as: UTF8.self) == #"{"display_name":"Camille M."}"#)
    }

    @Test func rpcsArePostsWithNamedParameters() throws {
        let request = RestQuery.rpc("rename_group", ["p_group_id": .uuid(group), "p_name": .string("Coloc")])
        #expect(request.method == .post)
        #expect(request.path == "rpc/rename_group")
        #expect(request.query.isEmpty)
        #expect(String(decoding: try #require(request.body).encoded(), as: UTF8.self)
            == #"{"p_group_id":"a0000000-0000-4000-8000-000000000001","p_name":"Coloc"}"#)
        let noParams = RestQuery.rpc("delete_my_account")
        #expect(String(decoding: try #require(noParams.body).encoded(), as: UTF8.self) == "{}")
    }

    @Test func taskParametersAreAllExplicit() throws {
        let draft = TaskDraft(title: "  Titre  ", details: "   ", priority: .high, dueAt: nil, assigneeIds: [Seed.lucas, Seed.camille])
        let params = try TaskFields(draft).params(adding: ["p_task_id": .uuid(task)])
        let json = String(decoding: try JSONValue.object(params).encoded(), as: UTF8.self)
        #expect(json == #"{"p_assignee_ids":["11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222"],"#
            + #""p_details":null,"p_due_at":null,"p_priority":"high","p_task_id":"b0000000-0000-4000-8000-000000000002","#
            + #""p_title":"Titre"}"#)
        let dated = try TaskFields(TaskDraft(title: "T", details: "D", dueAt: now)).params(adding: [:])
        #expect(dated["p_due_at"] == .string("2026-09-24T10:00:00.123456Z"))
        #expect(dated["p_details"] == .string("D"))
        #expect(dated["p_assignee_ids"] == .array([]))
    }

    @Test func percentEncodingKeepsPostgrestSyntaxAndEncodesPlusAndSpace() throws {
        #expect(RestRequest.percentEncoded("2026-09-24T10:00:00.123456+02:00") == "2026-09-24T10:00:00.123456%2B02:00")
        #expect(RestRequest.percentEncoded("a b&c=d#é") == "a%20b%26c%3Dd%23%C3%A9")
        #expect(RestRequest.percentEncoded("*,assignees:task_assignees!inner(user_id)") == "*,assignees:task_assignees!inner(user_id)")
        let restURL = try #require(URL(string: "http://127.0.0.1:54321/rest/v1/"))
        let url = try #require(RestQuery.task(id: task).url(restURL: restURL))
        #expect(url.absoluteString
            == "http://127.0.0.1:54321/rest/v1/tasks?select=*,assignees:task_assignees(user_id)&id=eq.b0000000-0000-4000-8000-000000000002")
    }
}
