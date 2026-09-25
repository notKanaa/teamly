import Foundation
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

/// The v2 calls against a fake PostgREST (docs/CONTRACTS-V2.md §3, §5, §7–§10): requests sent, validation before any
/// call in the server's order, results completed like a later read, errors.
@Suite struct V2ServiceUnitTests {
    static let noRow = FakeTransport.Response.json(200, "[]")
    static let rule = RecurrenceRule(frequency: .weekly, weekdays: [5, 1, 3], timeZoneId: "Europe/Paris")
    /// 2031-01-06T18:00:00Z
    static let due = Date(timeIntervalSince1970: 1_925_488_800)

    // MARK: - Profile

    @Test func updateAvatarChecksTheEmojiThenPatchesBothColumns() async throws {
        let transport = FakeTransport([.fixture(200, "v2_update_avatar"), .fixture(200, "v2_update_avatar"), Self.noRow])
        let profiles = UnitBackend.services(transport, me: V2Seed.camille).profiles
        for invalid in ["a b", "🦊\u{0}", String(repeating: "🦊", count: 17), "\u{7F}"] {
            await #expect(throws: AppError.invalidAppearance) { try await profiles.updateAvatar(color: .teal, emoji: invalid) }
        }
        #expect(transport.sent.isEmpty, "invalid emojis never reach the server")

        let profile = try await profiles.updateAvatar(color: .teal, emoji: " 🦊\u{3000}")
        #expect(profile == UserProfile(id: V2Seed.camille, displayName: "Camille Fixture", avatarColor: .teal, avatarEmoji: "🦊"))
        let sent = try #require(transport.sent.first)
        #expect(sent.method == "PATCH")
        #expect(sent.target == "profiles?select=id,display_name,avatar_color,avatar_emoji&id=eq.8488c3bb-3233-4bf9-a1e6-24b66878ba02")
        #expect(sent.headers["prefer"] == "return=representation")
        #expect(sent.body == #"{"avatar_color":"teal","avatar_emoji":"🦊"}"#, "the emoji is sent normalized")

        // Automatic color, and a blank emoji is no emoji (NULL).
        _ = try await profiles.updateAvatar(color: nil, emoji: " \u{200B} ")
        #expect(transport.sent.last?.body == #"{"avatar_color":null,"avatar_emoji":null}"#)
        // No row updated: the profile is not the caller's (or no longer exists).
        await #expect(throws: AppError.forbidden) { try await profiles.updateAvatar(color: .pink, emoji: nil) }
    }

    @Test func myProfileReadsTheOnboardingFields() async throws {
        let transport = FakeTransport([.fixture(200, "v2_profile")])
        let profile = try await UnitBackend.services(transport, me: V2Seed.camille).profiles.myProfile()
        #expect(profile.avatarColor == .teal && profile.avatarEmoji == "🦊")
        #expect(profile.onboardedAt != nil && profile.createdAt != nil)
        #expect(transport.sent.first?.target
            == "profiles?select=id,display_name,avatar_color,avatar_emoji,onboarded_at,created_at&id=eq.8488c3bb-3233-4bf9-a1e6-24b66878ba02")
    }

    @Test func updateDisplayNameKeepsTheAvatar() async throws {
        let json = #"[{"id":"8488c3bb-3233-4bf9-a1e6-24b66878ba02","display_name":"Camille M.","avatar_color":"teal","avatar_emoji":"🦊"}]"#
        let transport = FakeTransport([.json(200, json)])
        let profile = try await UnitBackend.services(transport, me: V2Seed.camille).profiles.updateDisplayName(" Camille M. ")
        #expect(profile == UserProfile(id: V2Seed.camille, displayName: "Camille M.", avatarColor: .teal, avatarEmoji: "🦊"))
        #expect(transport.sent.first?.body == #"{"display_name":"Camille M."}"#)
    }

    @Test func completeOnboardingCallsTheRPC() async throws {
        let transport = FakeTransport([.json(204, "")])
        try await UnitBackend.services(transport).profiles.completeOnboarding()
        #expect(transport.sent.map(\.target) == ["rpc/complete_onboarding"])
        #expect(transport.sent.first?.method == "POST")
        #expect(transport.sent.first?.body == "{}")
    }

    // MARK: - Groups

    /// Server order: name → color → emoji → quota. A typed color is always valid.
    @Test func createGroupWithAppearance() async throws {
        let transport = FakeTransport([.fixture(200, "v2_create_group"), .fixture(200, "v2_create_group")])
        let groups = UnitBackend.services(transport, me: V2Seed.camille).groups
        await #expect(throws: AppError.invalidName) { try await groups.createGroup(name: " ", color: .coral, emoji: "a b") }
        await #expect(throws: AppError.invalidAppearance) { try await groups.createGroup(name: "Coloc", color: .coral, emoji: "a b") }
        #expect(transport.sent.isEmpty)

        let summary = try await groups.createGroup(name: " Coloc fixture ", color: .coral, emoji: " 🏠 ")
        #expect(summary.myRole == .admin)
        #expect(summary.group.color == .coral)
        #expect(summary.group.emoji == "🏠")
        #expect(transport.sent.first?.target == "rpc/create_group")
        #expect(transport.sent.first?.body == #"{"p_color":"coral","p_emoji":"🏠","p_name":"Coloc fixture"}"#)

        _ = try await groups.createGroup(name: "Sans apparence", color: nil, emoji: "   ")
        #expect(transport.sent.last?.body == #"{"p_color":null,"p_emoji":null,"p_name":"Sans apparence"}"#)
    }

    /// Both keys are always sent (no default on the server); NULL = automatic color / no emoji. The emoji is sent as
    /// typed: the server checks it after the group and the rights (§3), so a member's invalid emoji is `.forbidden`.
    @Test func setAppearanceSendsBothValues() async throws {
        let cleared = #"{"id":"68b726d0-9f22-460c-8410-39efeead2cc1","name":"Coloc fixture","created_by":null,"#
            + #""created_at":"2026-09-25T02:25:54.55822+00:00","last_activity_at":"2026-09-25T02:25:59.1+00:00","color":null,"emoji":null}"#
        let transport = FakeTransport([
            .json(200, cleared),
            .json(403, #"{"code":"42501","details":null,"hint":null,"message":"forbidden"}"#),
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"group_not_found"}"#),
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"invalid_emoji"}"#),
        ])
        let groups = UnitBackend.services(transport).groups
        let group = try await groups.setAppearance(groupId: V2Seed.group, color: nil, emoji: " ")
        #expect(group.color == nil && group.emoji == nil)
        #expect(group.id == V2Seed.group)
        #expect(transport.sent.first?.target == "rpc/set_group_appearance")
        #expect(transport.sent.first?.body == #"{"p_color":null,"p_emoji":" ","p_group_id":"68b726d0-9f22-460c-8410-39efeead2cc1"}"#)
        await #expect(throws: AppError.forbidden) { try await groups.setAppearance(groupId: V2Seed.group, color: .pink, emoji: "a b") }
        #expect(transport.sent[1].body == #"{"p_color":"pink","p_emoji":"a b","p_group_id":"68b726d0-9f22-460c-8410-39efeead2cc1"}"#)
        await #expect(throws: AppError.notFound) { try await groups.setAppearance(groupId: UUID(), color: .pink, emoji: nil) }
        // U+0000 cannot reach Postgres (22P05 before any check): an emoji holding it is sent as U+0001, which the
        // server refuses at its turn.
        await #expect(throws: AppError.invalidAppearance) {
            try await groups.setAppearance(groupId: V2Seed.group, color: nil, emoji: "🏠\u{0}")
        }
        #expect(transport.sent[3].body == #"{"p_color":null,"p_emoji":"\u0001","p_group_id":"68b726d0-9f22-460c-8410-39efeead2cc1"}"#)
    }

    @Test func activityIsReadNewestFirst() async throws {
        let transport = FakeTransport([.fixture(200, "v2_activity")])
        let events = try await UnitBackend.services(transport).groups.activity(groupId: V2Seed.group)
        #expect(events.count == 11)
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.id > $1.id })
        #expect(transport.sent.first?.target
            == "group_activity?select=id,kind,actor_id,subject_id,task_id,task_title,item_title,created_at"
            + "&group_id=eq.68b726d0-9f22-460c-8410-39efeead2cc1&order=id.desc&limit=50")
    }

    // MARK: - Task create / update

    /// Title → details → due date → recurrence (shape, then due date) → rotation, before any call.
    @Test func createChecksTheV2FieldsInServerOrder() async throws {
        let transport = FakeTransport()
        let tasks = UnitBackend.services(transport).tasks
        let (lucas, camille) = (Seed.lucas, Seed.camille)
        let cases: [(TaskDraft, AppError)] = [
            (TaskDraft(title: " ", recurrence: RecurrenceRule(frequency: .daily, interval: 0, timeZoneId: "Europe/Paris")), .invalidTitle),
            (TaskDraft(title: "T", dueAt: Date(timeIntervalSince1970: -1), recurrence: Self.rule), .invalidInput),
            (TaskDraft(title: "T", recurrence: RecurrenceRule(frequency: .daily, interval: 53, timeZoneId: "Europe/Paris")), .invalidRecurrence),
            (TaskDraft(title: "T", dueAt: Self.due, recurrence: RecurrenceRule(frequency: .daily, weekdays: [1], timeZoneId: "UTC")), .invalidRecurrence),
            (TaskDraft(title: "T", dueAt: Self.due, recurrence: RecurrenceRule(frequency: .weekly, weekdays: [], timeZoneId: "UTC")), .invalidRecurrence),
            (TaskDraft(title: "T", dueAt: Self.due, recurrence: RecurrenceRule(frequency: .weekly, weekdays: [8], timeZoneId: "UTC")), .invalidRecurrence),
            (TaskDraft(title: "T", dueAt: Self.due, recurrence: RecurrenceRule(frequency: .daily, timeZoneId: "europe/paris")), .invalidRecurrence),
            (TaskDraft(title: "T", dueAt: Self.due, recurrence: RecurrenceRule(frequency: .daily, timeZoneId: "UTC+3")), .invalidRecurrence),
            (TaskDraft(title: "T", recurrence: Self.rule, rotation: [lucas]), .recurrenceNeedsDueDate),
            (TaskDraft(title: "T", dueAt: Self.due, rotation: [lucas, camille]), .invalidRotation),
            (TaskDraft(title: "T", dueAt: Self.due, recurrence: Self.rule, rotation: [lucas]), .invalidRotation),
            (TaskDraft(title: "T", dueAt: Self.due, recurrence: Self.rule, rotation: [lucas, camille, lucas]), .invalidRotation),
            (TaskDraft(title: "T", dueAt: Self.due, recurrence: Self.rule, rotation: (0...Limits.rotationMax).map { _ in UUID() }), .invalidRotation),
        ]
        for (draft, expected) in cases {
            await #expect(throws: expected) { try await tasks.create(groupId: Seed.lilas, draft: draft) }
        }
        #expect(transport.sent.isEmpty)
    }

    /// The checklist comes after the server's membership checks (rotation members, assignees): the server checks it,
    /// an error found by the client first could differ.
    @Test func createLeavesTheChecklistToTheServer() async throws {
        let transport = FakeTransport([
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"assignee_not_member"}"#),
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"invalid_item_title"}"#),
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"too_many_items"}"#),
        ])
        let tasks = UnitBackend.services(transport).tasks
        let blank = TaskDraft(title: "T", assigneeIds: [UUID()], checklist: ["Laver", "   "])
        await #expect(throws: AppError.assigneeNotMember) { try await tasks.create(groupId: Seed.lilas, draft: blank) }
        let nul = TaskDraft(title: "T", checklist: ["La\u{0}ver", "Ranger"])
        await #expect(throws: AppError.invalidChecklistItem) { try await tasks.create(groupId: Seed.lilas, draft: nul) }
        let many = TaskDraft(title: "T", checklist: (1...31).map { "Élément \($0)" })
        await #expect(throws: AppError.tooManyChecklistItems) { try await tasks.create(groupId: Seed.lilas, draft: many) }
        #expect(transport.sent.count == 3)
        #expect(transport.sent[0].body?.contains(#""p_checklist":["Laver","   "]"#) == true, "titles are sent as typed")
        // U+0000 cannot reach Postgres (22P05 before any check): the title is sent empty, refused at its turn.
        #expect(transport.sent[1].body?.contains(#""p_checklist":["","Ranger"]"#) == true)
    }

    /// A rotation without the checklist: the result is known from the row (the turn holder alone), no read.
    @Test func createWithARotationAssignsTheFirstTurn() async throws {
        let transport = FakeTransport([.fixture(200, "v2_create_task")])
        let draft = TaskDraft(
            title: " Vaisselle ", dueAt: Self.due, assigneeIds: [V2Seed.camille], recurrence: Self.rule,
            rotation: [V2Seed.lucas, V2Seed.camille]
        )
        let task = try await UnitBackend.services(transport, me: V2Seed.camille).tasks.create(groupId: V2Seed.group, draft: draft)
        #expect(task.assigneeIds == [V2Seed.lucas], "the draft's assignees are ignored with a rotation")
        #expect(task.turnUserId == V2Seed.lucas)
        #expect(task.rotation == [V2Seed.lucas, V2Seed.camille])
        #expect(task.recurrence == RecurrenceRule(frequency: .weekly, weekdays: [1, 3, 5], timeZoneId: "Europe/Paris"))
        #expect(task.seriesId == V2Seed.vaisselle)
        #expect(task.checklist.isEmpty)
        #expect(transport.sent.count == 1)
        #expect(transport.sent[0].body == #"{"p_assignee_ids":["8488c3bb-3233-4bf9-a1e6-24b66878ba02"],"p_checklist":[],"#
            + #""p_details":null,"p_due_at":"2031-01-06T18:00:00.000000Z","p_group_id":"68b726d0-9f22-460c-8410-39efeead2cc1","#
            + #""p_priority":"medium","p_recurrence":{"freq":"weekly","interval":1,"tz":"Europe/Paris","weekdays":[1,3,5]},"#
            + #""p_rotation":["4962fff7-82c6-41db-8ab8-c333313f833e","8488c3bb-3233-4bf9-a1e6-24b66878ba02"],"#
            + #""p_title":"Vaisselle"}"#)
    }

    /// With a checklist, the new items' ids come from a read of the task.
    @Test func createWithAChecklistReadsTheItems() async throws {
        let read = try String(decoding: Fixture.data("v2_group_tasks"), as: UTF8.self)
        let transport = FakeTransport([.fixture(200, "v2_create_task"), .json(200, read)])
        let draft = TaskDraft(
            title: "Vaisselle", dueAt: Self.due, recurrence: Self.rule, rotation: [V2Seed.lucas, V2Seed.camille],
            checklist: ["Laver", "Essuyer", "Ranger"]
        )
        let task = try await UnitBackend.services(transport, me: V2Seed.camille).tasks.create(groupId: V2Seed.group, draft: draft)
        // The first row of the canned read stands for the created task's embedded resources.
        #expect(task.id == V2Seed.vaisselle, "the fields are the row's")
        #expect(task.checklist.map(\.id) == [V2Seed.nextLaver, V2Seed.nextRanger])
        #expect(task.assigneeIds == [V2Seed.camille])
        #expect(transport.sent.map(\.target) == [
            "rpc/create_task", "tasks?select=\(RestQueryTests.taskSelect)&id=eq.0592ffc5-6947-4f7d-a3cc-4680d3366bd1",
        ])
        #expect(transport.sent[0].body?.contains(#""p_checklist":["Laver","Essuyer","Ranger"]"#) == true)
    }

    /// The task exists even when the read of its items fails: no error (a retry would create it twice).
    @Test func createSurvivesAFailedRead() async throws {
        let transport = FakeTransport([.fixture(200, "v2_create_task"), .failure(.notConnectedToInternet)])
        let draft = TaskDraft(
            title: "Vaisselle", dueAt: Self.due, recurrence: Self.rule, rotation: [V2Seed.lucas, V2Seed.camille], checklist: ["Laver"]
        )
        let task = try await UnitBackend.services(transport).tasks.create(groupId: V2Seed.group, draft: draft)
        #expect(task.id == V2Seed.vaisselle)
        #expect(task.assigneeIds == [V2Seed.lucas])
        #expect(task.checklist.isEmpty)
    }

    /// `update` sends the full state: a nil rule is `{}` (it removes the rule and the rotation), an empty rotation `[]`.
    @Test func updateSendsTheFullState() async throws {
        let read = try String(decoding: Fixture.data("v2_group_tasks"), as: UTF8.self)
        let transport = FakeTransport([.fixture(200, "v2_create_task"), .json(200, read), .fixture(200, "v2_create_task"), Self.noRow])
        let tasks = UnitBackend.services(transport).tasks
        let kept = TaskDraft(
            title: "Vaisselle", dueAt: Self.due, assigneeIds: [V2Seed.lucas], recurrence: Self.rule,
            rotation: [V2Seed.lucas, V2Seed.camille], checklist: ["ignored by update"]
        )
        let task = try await tasks.update(taskId: V2Seed.vaisselle, draft: kept)
        #expect(task.rotation == [V2Seed.lucas, V2Seed.camille])
        #expect(task.checklist.map(\.id) == [V2Seed.nextLaver, V2Seed.nextRanger], "completed with the read")
        #expect(transport.sent[0].body == #"{"p_assignee_ids":["4962fff7-82c6-41db-8ab8-c333313f833e"],"p_details":null,"#
            + #""p_due_at":"2031-01-06T18:00:00.000000Z","p_priority":"medium","#
            + #""p_recurrence":{"freq":"weekly","interval":1,"tz":"Europe/Paris","weekdays":[1,3,5]},"#
            + #""p_rotation":["4962fff7-82c6-41db-8ab8-c333313f833e","8488c3bb-3233-4bf9-a1e6-24b66878ba02"],"#
            + #""p_task_id":"0592ffc5-6947-4f7d-a3cc-4680d3366bd1","p_title":"Vaisselle"}"#)

        // Removing the rule: the stored rotation sent back is left to the server (kept as « unchanged », then removed
        // with the rule; a new one would be refused). The task was deleted right after: no assignee, no item.
        let plain = TaskDraft(title: "Vaisselle", dueAt: nil, rotation: [V2Seed.lucas, V2Seed.camille])
        let removed = try await tasks.update(taskId: V2Seed.vaisselle, draft: plain)
        #expect(removed.assigneeIds.isEmpty && removed.checklist.isEmpty)
        #expect(transport.sent[2].body?.contains(#""p_recurrence":{}"#) == true)
        #expect(transport.sent[2].body?.contains(
            #""p_rotation":["4962fff7-82c6-41db-8ab8-c333313f833e","8488c3bb-3233-4bf9-a1e6-24b66878ba02"]"#
        ) == true)
        #expect(transport.sent.count == 4)
    }

    /// With a rule, a rotation is checked before the call (a stored rotation always passes the count and duplicate
    /// checks); a rule needs a due date.
    @Test func updateChecksTheRuleAndTheRotation() async throws {
        let transport = FakeTransport()
        let tasks = UnitBackend.services(transport).tasks
        await #expect(throws: AppError.recurrenceNeedsDueDate) {
            try await tasks.update(taskId: V2Seed.vaisselle, draft: TaskDraft(title: "T", recurrence: Self.rule))
        }
        await #expect(throws: AppError.invalidRotation) {
            try await tasks.update(
                taskId: V2Seed.vaisselle, draft: TaskDraft(title: "T", dueAt: Self.due, recurrence: Self.rule, rotation: [V2Seed.lucas])
            )
        }
        await #expect(throws: AppError.invalidRecurrence) {
            try await tasks.update(
                taskId: V2Seed.vaisselle,
                draft: TaskDraft(title: "T", dueAt: Self.due, recurrence: RecurrenceRule(frequency: .monthly, weekdays: [1], timeZoneId: "UTC"))
            )
        }
        #expect(transport.sent.isEmpty)
    }

    @Test func setStatusCompletesTheRowWithTheChecklist() async throws {
        let read = try String(decoding: Fixture.data("v2_group_tasks"), as: UTF8.self)
        let transport = FakeTransport([.fixture(200, "v2_set_task_status"), .json(200, read)])
        let task = try await UnitBackend.services(transport).tasks.setStatus(taskId: V2Seed.vaisselle, status: .done)
        #expect(task.status == .done)
        #expect(task.completedBy == V2Seed.lucas)
        #expect(task.nextOccurrenceId == V2Seed.vaisselleNext)
        #expect(task.checklist.count == 2)
        #expect(transport.sent.map(\.target) == [
            "rpc/set_task_status", "tasks?select=\(RestQueryTests.taskSelect)&id=eq.0592ffc5-6947-4f7d-a3cc-4680d3366bd1",
        ])
    }

    // MARK: - Checklist

    @Test func checklistRPCs() async throws {
        let item = try String(decoding: Fixture.data("v2_checklist_item"), as: UTF8.self)
        let transport = FakeTransport([.json(200, item), .json(200, item), .json(200, item), .json(200, "null")])
        let tasks = UnitBackend.services(transport).tasks
        let added = try await tasks.addChecklistItem(taskId: V2Seed.vaisselle, title: "  Laver ")
        #expect(added.id == V2Seed.laver)
        _ = try await tasks.renameChecklistItem(itemId: V2Seed.laver, title: String(repeating: "x", count: 200))
        let checked = try await tasks.setChecklistItemDone(itemId: V2Seed.laver, done: true)
        #expect(checked.isDone && checked.doneBy == V2Seed.lucas)
        try await tasks.deleteChecklistItem(itemId: V2Seed.laver)
        #expect(transport.sent.map(\.target) == [
            "rpc/add_checklist_item", "rpc/rename_checklist_item", "rpc/set_checklist_item_done", "rpc/delete_checklist_item",
        ])
        #expect(transport.sent[0].body == #"{"p_task_id":"0592ffc5-6947-4f7d-a3cc-4680d3366bd1","p_title":"  Laver "}"#, "the server trims")
        #expect(transport.sent[1].body == #"{"p_item_id":"59da297d-d4ce-4f28-8763-e6f6b9ac7b5c","p_title":""# + String(repeating: "x", count: 200) + #""}"#)
        #expect(transport.sent[2].body == #"{"p_done":true,"p_item_id":"59da297d-d4ce-4f28-8763-e6f6b9ac7b5c"}"#)
        #expect(transport.sent[3].body == #"{"p_item_id":"59da297d-d4ce-4f28-8763-e6f6b9ac7b5c"}"#)
    }

    /// Titles are checked by the server, after the task (or item) and the rights (§3): another member's blank title is
    /// `.forbidden`, a non-member's `.notFound`. A title holding U+0000 is sent empty (refused at its turn).
    @Test func checklistTitlesAreCheckedByTheServer() async throws {
        let invalid = #"{"code":"P0001","details":null,"hint":null,"message":"invalid_item_title"}"#
        let transport = FakeTransport([
            .json(403, #"{"code":"42501","details":null,"hint":null,"message":"forbidden"}"#),
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"task_not_found"}"#),
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"item_not_found"}"#),
            .json(400, invalid), .json(400, invalid), .json(400, invalid),
        ])
        let tasks = UnitBackend.services(transport).tasks
        await #expect(throws: AppError.forbidden) { try await tasks.addChecklistItem(taskId: V2Seed.vaisselle, title: " ") }
        await #expect(throws: AppError.notFound) { try await tasks.addChecklistItem(taskId: UUID(), title: "") }
        await #expect(throws: AppError.notFound) { try await tasks.renameChecklistItem(itemId: UUID(), title: "") }
        await #expect(throws: AppError.invalidChecklistItem) {
            try await tasks.addChecklistItem(taskId: V2Seed.vaisselle, title: String(repeating: "x", count: 201))
        }
        await #expect(throws: AppError.invalidChecklistItem) { try await tasks.addChecklistItem(taskId: V2Seed.vaisselle, title: "La\u{0}ver") }
        await #expect(throws: AppError.invalidChecklistItem) { try await tasks.renameChecklistItem(itemId: V2Seed.laver, title: "\u{0}") }
        #expect(transport.sent.count == 6)
        #expect(transport.sent[0].body == #"{"p_task_id":"0592ffc5-6947-4f7d-a3cc-4680d3366bd1","p_title":" "}"#)
        #expect(transport.sent[4].body == #"{"p_task_id":"0592ffc5-6947-4f7d-a3cc-4680d3366bd1","p_title":""}"#)
        #expect(transport.sent[5].body == #"{"p_item_id":"59da297d-d4ce-4f28-8763-e6f6b9ac7b5c","p_title":""}"#)
    }

    @Test func checklistErrorsAreMapped() async throws {
        let transport = FakeTransport([
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"item_not_found"}"#),
            .json(403, #"{"code":"42501","details":null,"hint":null,"message":"forbidden"}"#),
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"too_many_items"}"#),
            .json(400, #"{"code":"P0001","details":null,"hint":null,"message":"task_not_found"}"#),
        ])
        let tasks = UnitBackend.services(transport).tasks
        await #expect(throws: AppError.notFound) { try await tasks.setChecklistItemDone(itemId: UUID(), done: true) }
        await #expect(throws: AppError.forbidden) { try await tasks.deleteChecklistItem(itemId: V2Seed.laver) }
        await #expect(throws: AppError.tooManyChecklistItems) { try await tasks.addChecklistItem(taskId: V2Seed.vaisselle, title: "Un de trop") }
        await #expect(throws: AppError.notFound) { try await tasks.addChecklistItem(taskId: UUID(), title: "Laver") }
    }

    // MARK: - Weekly recap

    @Test func completionsSinceIsInclusiveWithMicroseconds() async throws {
        let transport = FakeTransport([.fixture(200, "v2_completions")])
        let since = PostgresTimestamp.date(epochMicroseconds: 1_789_343_546_878_215)
        let completions = try await UnitBackend.services(transport).tasks.completions(groupId: V2Seed.group, since: since)
        #expect(completions.map(\.taskId) == [V2Seed.vaisselle, V2Seed.courses])
        #expect(completions.map(\.completedBy) == [V2Seed.lucas, V2Seed.camille])
        #expect(transport.sent.first?.target
            == "tasks?select=id,completed_by,completed_at&group_id=eq.68b726d0-9f22-460c-8410-39efeead2cc1"
            + "&status=eq.done&completed_at=gte.2026-09-13T23:52:26.878215Z")
    }

    // MARK: - Signed out

    @Test func signedOutV2CallsNeverReachTheServer() async throws {
        let transport = FakeTransport()
        let services = UnitBackend.signedOutServices(transport)
        await #expect(throws: AppError.notAuthenticated) { try await services.profiles.updateAvatar(color: .teal, emoji: nil) }
        await #expect(throws: AppError.notAuthenticated) { try await services.profiles.completeOnboarding() }
        await #expect(throws: AppError.notAuthenticated) { try await services.groups.createGroup(name: "G", color: .teal, emoji: nil) }
        await #expect(throws: AppError.notAuthenticated) { try await services.groups.activity(groupId: V2Seed.group) }
        await #expect(throws: AppError.notAuthenticated) { try await services.tasks.addChecklistItem(taskId: V2Seed.vaisselle, title: "T") }
        await #expect(throws: AppError.notAuthenticated) { try await services.tasks.completions(groupId: V2Seed.group, since: Date()) }
        #expect(transport.sent.isEmpty)
    }
}
