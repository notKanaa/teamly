import Foundation
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

/// The services against a fake PostgREST: requests sent, validation before any call, results and errors.
@Suite struct ServiceUnitTests {
    // MARK: - Groups

    @Test func myGroupsAreSortedByActivityThenName() async throws {
        // Both seed groups have the same last_activity_at: NameOrder decides (Coloc' < Projet).
        let transport = FakeTransport([.fixture(200, "my_groups")])
        let groups = try await UnitBackend.services(transport).groups.myGroups()
        #expect(groups.map(\.id) == [Seed.lilas, Seed.sport])
        #expect(groups.map(\.myRole) == [.admin, .member])
        let sent = try #require(transport.sent.first)
        #expect(sent.method == "GET")
        #expect(sent.target == "group_members?select=role,group:groups(*)&user_id=eq.11111111-1111-4111-8111-111111111111")
        #expect(sent.headers["apikey"] == "sb_publishable_test")
        #expect(sent.headers["authorization"] == "Bearer jeton-de-test")
    }

    @Test func membersAreSortedAdminsFirstThenName() async throws {
        let json = """
        [{"user_id":"33333333-3333-4333-8333-333333333333","role":"member","joined_at":"2026-09-15T23:52:26+00:00","profile":{"id":"33333333-3333-4333-8333-333333333333","display_name":"inès Dubois"}},
         {"user_id":"22222222-2222-4222-8222-222222222222","role":"member","joined_at":"2026-09-14T23:52:26+00:00","profile":{"id":"22222222-2222-4222-8222-222222222222","display_name":"Ines Dubois"}},
         {"user_id":"11111111-1111-4111-8111-111111111111","role":"admin","joined_at":"2026-09-13T23:52:26+00:00","profile":{"id":"11111111-1111-4111-8111-111111111111","display_name":"Zoé"}}]
        """
        let transport = FakeTransport([.json(200, json)])
        let members = try await UnitBackend.services(transport).groups.members(groupId: Seed.lilas)
        // Admin first; "Ines" and "inès" fold to the same key: exact order decides ("I" < "i").
        #expect(members.map(\.user.id) == [Seed.camille, Seed.lucas, Seed.ines])
    }

    @Test func createGroupValidatesThenCallsTheRPC() async throws {
        let transport = FakeTransport([.fixture(200, "create_group")])
        let groups = UnitBackend.services(transport).groups
        await #expect(throws: AppError.invalidName) { try await groups.createGroup(name: "   ") }
        await #expect(throws: AppError.invalidName) { try await groups.createGroup(name: String(repeating: "x", count: 61)) }
        await #expect(throws: AppError.invalidName) { try await groups.createGroup(name: "a\u{0}b") }
        #expect(transport.sent.isEmpty, "invalid names never reach the server")

        let summary = try await groups.createGroup(name: "  Groupe fixture\u{3000}")
        #expect(summary.myRole == .admin)
        #expect(summary.group.name == "Groupe fixture")
        let sent = try #require(transport.sent.first)
        #expect(sent.method == "POST")
        #expect(sent.target == "rpc/create_group")
        #expect(sent.body == #"{"p_name":"Groupe fixture"}"#)
        #expect(sent.headers["content-type"] == "application/json")
    }

    @Test func joinSendsTheNormalizedCode() async throws {
        let transport = FakeTransport([
            .fixture(200, "join_joined"), .fixture(200, "join_already_member"), .fixture(200, "join_invalid_code"),
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"rate_limited"}"#),
        ])
        let groups = UnitBackend.services(transport).groups
        let code = try #require(InviteCode(" sprt-5678 "))
        let joined = try await groups.join(code: code)
        #expect(joined == JoinResult(groupId: Seed.sport, groupName: "Projet Asso Sport", alreadyMember: false))
        #expect(transport.sent.first?.body == #"{"p_code":"SPRT5678"}"#)
        #expect(try await groups.join(code: code).alreadyMember)
        await #expect(throws: AppError.invalidCode) { try await groups.join(code: code) }
        await #expect(throws: AppError.rateLimited) { try await groups.join(code: code) }
    }

    @Test func inviteCodeIsForbiddenWithoutRows() async throws {
        let transport = FakeTransport([.json(200, "[]"), .fixture(200, "invite_code"), .fixture(200, "regenerate")])
        let groups = UnitBackend.services(transport).groups
        await #expect(throws: AppError.forbidden) { try await groups.inviteCode(groupId: Seed.sport) }
        #expect(try await groups.inviteCode(groupId: Seed.lilas).value == "LYLAS234")
        #expect(try await groups.regenerateInviteCode(groupId: Seed.lilas).value == "NYCXWUA4")
        #expect(transport.sent.last?.body == #"{"p_group_id":"a0000000-0000-4000-8000-000000000001"}"#)
    }

    @Test func memberRPCsUseNamedParameters() async throws {
        let transport = FakeTransport([.json(204, ""), .json(204, ""), .json(204, ""), .json(200, "null")])
        let groups = UnitBackend.services(transport).groups
        try await groups.setRole(groupId: Seed.lilas, userId: Seed.lucas, role: .admin)
        try await groups.removeMember(groupId: Seed.lilas, userId: Seed.ines)
        try await groups.leave(groupId: Seed.sport)
        try await groups.deleteGroup(groupId: Seed.sport)
        #expect(transport.sent.map(\.target) == ["rpc/set_member_role", "rpc/remove_member", "rpc/leave_group", "rpc/delete_group"])
        #expect(transport.sent[0].body
            == #"{"p_group_id":"a0000000-0000-4000-8000-000000000001","p_role":"admin","p_user_id":"22222222-2222-4222-8222-222222222222"}"#)
        #expect(transport.sent[1].body
            == #"{"p_group_id":"a0000000-0000-4000-8000-000000000001","p_user_id":"33333333-3333-4333-8333-333333333333"}"#)
    }

    @Test func serverErrorsAreMapped() async throws {
        let transport = FakeTransport([
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"last_admin"}"#),
            .json(403, #"{"code":"42501","details":null,"hint":null,"message":"forbidden"}"#),
            .json(401, #"{"code":"42501","details":null,"hint":null,"message":"permission denied for function leave_group"}"#),
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"group_not_found"}"#),
            .failure(.notConnectedToInternet),
        ])
        let groups = UnitBackend.services(transport).groups
        await #expect(throws: AppError.lastAdmin) { try await groups.leave(groupId: Seed.lilas) }
        await #expect(throws: AppError.forbidden) { try await groups.leave(groupId: Seed.lilas) }
        await #expect(throws: AppError.notAuthenticated) { try await groups.leave(groupId: Seed.lilas) }
        await #expect(throws: AppError.notFound) { try await groups.rename(groupId: Seed.lilas, name: "Nom") }
        await #expect(throws: AppError.network) { try await groups.myGroups() }
    }

    // MARK: - Tasks

    @Test func createTaskValidatesInServerOrderBeforeAnyCall() async throws {
        let transport = FakeTransport()
        let tasks = UnitBackend.services(transport).tasks
        await #expect(throws: AppError.invalidTitle) {
            try await tasks.create(groupId: Seed.lilas, draft: TaskDraft(title: "a\u{0}", details: String(repeating: "x", count: 5001)))
        }
        await #expect(throws: AppError.invalidDetails) {
            try await tasks.create(groupId: Seed.lilas, draft: TaskDraft(title: "Titre", details: "d\u{0}"))
        }
        await #expect(throws: AppError.invalidInput) {
            try await tasks.create(groupId: Seed.lilas, draft: TaskDraft(title: "Titre", dueAt: Date(timeIntervalSince1970: -1)))
        }
        await #expect(throws: AppError.invalidInput) {
            try await tasks.update(taskId: Seed.courses, draft: TaskDraft(title: "Titre", dueAt: Date(timeIntervalSince1970: 253_402_300_800)))
        }
        #expect(transport.sent.isEmpty)
    }

    @Test func createTaskCompletesTheBareRowWithTheDraftAssignees() async throws {
        let transport = FakeTransport([.fixture(200, "create_task")])
        let draft = TaskDraft(
            title: " Tâche fixture ", details: "", priority: .high, dueAt: Date(timeIntervalSince1970: 1_924_992_000),
            assigneeIds: [Seed.lucas, Seed.camille]
        )
        let task = try await UnitBackend.services(transport).tasks.create(groupId: Seed.lilas, draft: draft)
        #expect(task.assigneeIds == [Seed.camille, Seed.lucas])
        #expect(task.title == "Tâche fixture")
        #expect(task.myAssignedAt == nil && task.groupName == nil)
        let sent = try #require(transport.sent.first)
        #expect(sent.target == "rpc/create_task")
        #expect(sent.body == #"{"p_assignee_ids":["11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222"],"#
            + #""p_details":null,"p_due_at":"2031-01-01T00:00:00.000000Z","p_group_id":"a0000000-0000-4000-8000-000000000001","#
            + #""p_priority":"high","p_title":"Tâche fixture"}"#)
    }

    @Test func updateTaskSendsTheFullDraft() async throws {
        let transport = FakeTransport([.fixture(200, "create_task")])
        let draft = TaskDraft(title: "Titre", details: " Détails ", priority: .low, dueAt: nil, assigneeIds: [])
        let task = try await UnitBackend.services(transport).tasks.update(taskId: Seed.courses, draft: draft)
        #expect(task.assigneeIds.isEmpty)
        #expect(transport.sent.first?.target == "rpc/update_task")
        #expect(transport.sent.first?.body == #"{"p_assignee_ids":[],"p_details":"Détails","p_due_at":null,"#
            + #""p_priority":"low","p_task_id":"b0000000-0000-4000-8000-000000000002","p_title":"Titre"}"#)
    }

    @Test func setStatusReadsTheAssigneesOfTheTask() async throws {
        let read = """
        [{"id":"94d0d49f-a303-4611-9621-ced98f3d9086","group_id":"e82a930a-a452-4f1c-9884-fbff6d79b8f2","title":"Tâche fixture",\
        "details":null,"status":"done","priority":"high","due_at":"2031-01-01T00:00:00+00:00",\
        "created_by":"214442fe-11cc-44fe-949d-af4109d9d950","created_at":"2026-09-24T00:24:04.369866+00:00",\
        "updated_at":"2026-09-24T00:24:04.385321+00:00","completed_at":"2026-09-24T00:24:04.385321+00:00",\
        "assignees":[{"user_id":"33333333-3333-4333-8333-333333333333"},{"user_id":"11111111-1111-4111-8111-111111111111"}]}]
        """
        let transport = FakeTransport([.fixture(200, "set_task_status"), .json(200, read)])
        let taskId = uuid("94d0d49f-a303-4611-9621-ced98f3d9086")
        let task = try await UnitBackend.services(transport).tasks.setStatus(taskId: taskId, status: .done)
        #expect(task.status == .done)
        #expect(task.assigneeIds == [Seed.camille, Seed.ines])
        #expect(task.completedAt != nil)
        #expect(transport.sent.map(\.target) == [
            "rpc/set_task_status",
            "tasks?select=*,assignees:task_assignees(user_id)&id=eq.94d0d49f-a303-4611-9621-ced98f3d9086",
        ])
        #expect(transport.sent[0].body == #"{"p_status":"done","p_task_id":"94d0d49f-a303-4611-9621-ced98f3d9086"}"#)
    }

    @Test func groupTasksUseTheOldDoneCutoffUnlessIncluded() async throws {
        let transport = FakeTransport([.fixture(200, "group_tasks"), .fixture(200, "group_tasks")])
        let tasks = UnitBackend.services(transport).tasks
        let recent = try await tasks.tasks(groupId: Seed.lilas, includeOldDone: false)
        _ = try await tasks.tasks(groupId: Seed.lilas, includeOldDone: true)
        #expect(recent.count == 5)
        #expect(zip(recent, recent.dropFirst()).allSatisfy { $0.createdAt <= $1.createdAt })
        #expect(transport.sent[0].target.hasSuffix("&or=(status.neq.done,completed_at.gte.2026-08-25T10:00:00.123456Z)"))
        #expect(!transport.sent[1].target.contains("or="))
    }

    @Test func oneTaskIsNotFoundWithoutRows() async throws {
        let transport = FakeTransport([.json(200, "[]")])
        await #expect(throws: AppError.notFound) { try await UnitBackend.services(transport).tasks.task(id: Seed.courses) }
    }

    @Test func assignmentsSendSinceWithMicroseconds() async throws {
        let transport = FakeTransport([.fixture(200, "assignments")])
        let since = PostgresTimestamp.date(epochMicroseconds: 1_789_343_546_878_215)
        let events = try await UnitBackend.services(transport).tasks.assignments(since: since)
        #expect(events.count == 3)
        #expect(transport.sent.first?.target.contains("&assigned_at=gt.2026-09-13T23:52:26.878215Z&") == true)
    }

    @Test func myTasksFilterDoneTasks() async throws {
        let transport = FakeTransport([.fixture(200, "my_tasks")])
        let tasks = try await UnitBackend.services(transport).tasks.myTasks(includeDone: false)
        #expect(tasks.allSatisfy { $0.groupName != nil && $0.myAssignedAt != nil })
        #expect(transport.sent.first?.target.hasSuffix("&status=neq.done") == true)
    }

    // MARK: - Profile & push

    @Test func updateDisplayNameIsAPatch() async throws {
        let transport = FakeTransport([
            .json(200, #"[{"id":"11111111-1111-4111-8111-111111111111","display_name":"Camille M."}]"#),
            .json(200, "[]"),
        ])
        let profiles = UnitBackend.services(transport).profiles
        await #expect(throws: AppError.invalidDisplayName) { try await profiles.updateDisplayName(" \u{200B} ") }
        let profile = try await profiles.updateDisplayName("  Camille M.  ")
        #expect(profile == UserProfile(id: Seed.camille, displayName: "Camille M."))
        let sent = try #require(transport.sent.first)
        #expect(sent.method == "PATCH")
        #expect(sent.target == "profiles?select=id,display_name&id=eq.11111111-1111-4111-8111-111111111111")
        #expect(sent.headers["prefer"] == "return=representation")
        #expect(sent.body == #"{"display_name":"Camille M."}"#)
        await #expect(throws: AppError.forbidden) { try await profiles.updateDisplayName("Camille") }
    }

    @Test func myProfileWithoutRowMeansTheAccountIsGone() async throws {
        let transport = FakeTransport([.fixture(200, "profile"), .json(200, "[]")])
        let profiles = UnitBackend.services(transport).profiles
        #expect(try await profiles.myProfile() == UserProfile(id: Seed.camille, displayName: "Camille Martin"))
        await #expect(throws: AppError.notAuthenticated) { try await profiles.myProfile() }
    }

    @Test func pushTopic() async throws {
        let transport = FakeTransport([
            .json(200, "[]"), .json(200, #""equipe-abcdefghijklmnopqrstuvwx""#), .json(204, ""),
        ])
        let push = UnitBackend.services(transport).push
        #expect(try await push.currentTopic() == nil)
        #expect(try await push.enable() == "equipe-abcdefghijklmnopqrstuvwx")
        try await push.disable()
        #expect(transport.sent.map(\.target) == [
            "push_subscriptions?select=topic&user_id=eq.11111111-1111-4111-8111-111111111111", "rpc/enable_push", "rpc/disable_push",
        ])
    }

    // MARK: - Signed out

    /// Without a local session, the adapters answer `.notAuthenticated` without calling the server.
    @Test func signedOutCallsNeverReachTheServer() async throws {
        let transport = FakeTransport()
        let services = UnitBackend.signedOutServices(transport)
        await #expect(throws: AppError.notAuthenticated) { try await services.groups.myGroups() }
        await #expect(throws: AppError.notAuthenticated) { try await services.groups.createGroup(name: "Groupe") }
        await #expect(throws: AppError.notAuthenticated) { try await services.profiles.myProfile() }
        await #expect(throws: AppError.notAuthenticated) { try await services.tasks.myTasks(includeDone: true) }
        await #expect(throws: AppError.notAuthenticated) { try await services.push.enable() }
        await #expect(throws: AppError.notAuthenticated) { try await services.auth.deleteAccount() }
        #expect(transport.sent.isEmpty)
    }
}
