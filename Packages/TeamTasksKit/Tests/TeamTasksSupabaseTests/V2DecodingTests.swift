import Foundation
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

/// Ids of the `v2_*` fixtures (captured from the local stack, see Fixtures/README.md).
enum V2Seed {
    static let camille = uuid("8488c3bb-3233-4bf9-a1e6-24b66878ba02")
    static let lucas = uuid("4962fff7-82c6-41db-8ab8-c333313f833e")
    static let ines = uuid("172cbf9f-558c-41be-aa1a-a6853ad46599")
    static let group = uuid("68b726d0-9f22-460c-8410-39efeead2cc1")
    /// « Vaisselle », weekly, rotation Lucas → Camille: the occurrence Lucas completed…
    static let vaisselle = uuid("0592ffc5-6947-4f7d-a3cc-4680d3366bd1")
    /// …and the next one, Camille's turn.
    static let vaisselleNext = uuid("8db5b772-ee05-494c-b245-1ed6cc55a5c0")
    /// « Loyer », monthly on the 31st.
    static let loyer = uuid("ed860957-87ac-47e3-9a53-e6df80f0c6fd")
    /// « Courses », a plain task done by Camille.
    static let courses = uuid("4eaa1208-91b7-42b5-b4d1-f0d71eef5156")
    /// « Poubelles », assigned to Camille by Lucas.
    static let poubelles = uuid("f35897a4-bef4-490a-9db3-d1804fa4e253")
    /// « Laver », checked by Lucas on the completed occurrence.
    static let laver = uuid("59da297d-d4ce-4f28-8763-e6f6b9ac7b5c")
    static let ranger = uuid("eba5281d-6f0c-4f6e-9039-7538f1d10938")
    static let nextLaver = uuid("ba2bc23c-7d54-4def-bfaf-37ed0cb408bd")
    static let nextRanger = uuid("833fe118-88df-4878-88fd-305065d06ab5")
}

/// Decoding of the v2 answers (docs/CONTRACTS-V2.md §10), captured from the local stack: appearance, onboarding,
/// recurrence, rotation, checklist, activity, completions, and the tolerance to values added by a later version.
@Suite struct V2DecodingTests {
    @Test func groupRowsCarryTheirAppearance() throws {
        let group = try Fixture.decode(GroupRow.self, "v2_create_group").teamGroup
        #expect(group.id == V2Seed.group)
        #expect(group.color == .coral)
        #expect(group.emoji == "🏠", "stored normalized (trimmed)")
        #expect(group.resolvedColor == .coral)
    }

    /// A color added by a later version reads as nil, the automatic color: the row stays readable.
    @Test func unknownColorReadsAsAutomatic() throws {
        let json = try String(decoding: Fixture.data("v2_create_group"), as: UTF8.self)
        let newer = json.replacingOccurrences(of: #""color":"coral""#, with: #""color":"magenta""#)
        #expect(newer != json)
        let group = try RestDecoding.decode(GroupRow.self, from: Data(newer.utf8)).teamGroup
        #expect(group.color == nil)
        #expect(group.resolvedColor == ColorKey.automatic(for: V2Seed.group))
        #expect(group.emoji == "🏠")
    }

    @Test func myProfileHasTheAvatarAndTheOnboardingFields() throws {
        let profile = try #require(try Fixture.decode([ProfileRow].self, "v2_profile").first).profile
        #expect(profile.id == V2Seed.camille)
        #expect(profile.displayName == "Camille Fixture")
        #expect(profile.avatarColor == .teal)
        #expect(profile.avatarEmoji == "🦊")
        #expect(profile.onboardedAt.map(PostgresTimestamp.format) == "2026-09-25T02:25:54.729884Z")
        #expect(profile.createdAt.map(PostgresTimestamp.format) == "2026-09-25T02:25:54.131314Z")
    }

    @Test func patchResultHasTheAvatarOnly() throws {
        let profile = try #require(try Fixture.decode([ProfileRow].self, "v2_update_avatar").first).profile
        #expect(profile == UserProfile(id: V2Seed.camille, displayName: "Camille Fixture", avatarColor: .teal, avatarEmoji: "🦊"))
    }

    @Test func membersCarryTheirAvatar() throws {
        let members = try Fixture.decode([MemberRow].self, "v2_members").map { $0.membership(groupId: V2Seed.group) }
        #expect(members.map(\.user) == [
            UserProfile(id: V2Seed.camille, displayName: "Camille Fixture", avatarColor: .teal, avatarEmoji: "🦊"),
            UserProfile(id: V2Seed.lucas, displayName: "Lucas Fixture"),
            UserProfile(id: V2Seed.ines, displayName: "Inès Fixture"),
        ])
        #expect(members.allSatisfy { $0.user.onboardedAt == nil && $0.user.createdAt == nil }, "only myProfile reads them")

        let json = try String(decoding: Fixture.data("v2_members"), as: UTF8.self)
        let newer = json.replacingOccurrences(of: #""avatar_color": "teal""#, with: #""avatar_color": "magenta""#)
        #expect(newer != json)
        let tolerant = try RestDecoding.decode([MemberRow].self, from: Data(newer.utf8))
        #expect(tolerant.map { $0.membership(groupId: V2Seed.group).user.avatarColor } == [nil, nil, nil])
        #expect(tolerant.first?.membership(groupId: V2Seed.group).user.avatarEmoji == "🦊")
    }

    @Test func groupTasksCarryRecurrenceRotationAndChecklist() throws {
        let tasks = try Fixture.decode([TaskDTO].self, "v2_group_tasks").map { $0.item() }
        #expect(tasks.count == 5)
        let weekly = RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [1, 3, 5], timeZoneId: "Europe/Paris")

        // The occurrence spawned when Lucas completed his turn: Camille's turn, the checklist copied unchecked (gap kept).
        let next = try #require(tasks.first { $0.id == V2Seed.vaisselleNext })
        #expect(next.recurrence == weekly)
        #expect(next.rotation == [V2Seed.lucas, V2Seed.camille], "turn order kept")
        #expect(next.turnUserId == V2Seed.camille)
        #expect(next.assigneeIds == [V2Seed.camille])
        #expect(next.seriesId == V2Seed.vaisselle)
        #expect(next.nextOccurrenceId == nil)
        #expect(next.completedBy == nil)
        #expect(next.checklist == [
            ChecklistItem(id: V2Seed.nextLaver, title: "Laver", position: 1),
            ChecklistItem(id: V2Seed.nextRanger, title: "Ranger", position: 3),
        ])
        #expect(next.isRecurring && next.hasRotation)

        // The completed occurrence: the server lists « Ranger » first, the adapter sorts by position.
        let done = try #require(tasks.first { $0.id == V2Seed.vaisselle })
        #expect(done.status == .done)
        #expect(done.completedBy == V2Seed.lucas)
        #expect(done.nextOccurrenceId == V2Seed.vaisselleNext)
        #expect(done.seriesId == V2Seed.vaisselle)
        #expect(done.checklist.map(\.id) == [V2Seed.laver, V2Seed.ranger])
        let laver = try #require(done.checklist.first)
        #expect(laver.isDone)
        #expect(laver.doneBy == V2Seed.lucas)
        #expect(laver.doneAt.map(PostgresTimestamp.format) == "2026-09-25T02:25:55.092936Z")

        // Monthly on the 31st: the server's month day is part of the rule.
        let loyer = try #require(tasks.first { $0.id == V2Seed.loyer })
        #expect(loyer.recurrence == RecurrenceRule(frequency: .monthly, timeZoneId: "Europe/Paris", monthDay: 31))
        #expect(loyer.rotation.isEmpty && loyer.turnUserId == nil)
        #expect(loyer.seriesId == V2Seed.loyer)
        #expect(loyer.assigneeIds == [V2Seed.camille], "Inès left the group")

        // A plain task: the v2 columns are JSON null.
        let courses = try #require(tasks.first { $0.id == V2Seed.courses })
        #expect(courses.recurrence == nil)
        #expect(courses.rotation.isEmpty)
        #expect(courses.turnUserId == nil && courses.seriesId == nil && courses.nextOccurrenceId == nil)
        #expect(courses.completedBy == V2Seed.camille)
        #expect(courses.checklist.isEmpty)
        #expect(tasks.allSatisfy { $0.groupColor == nil && $0.groupEmoji == nil && $0.groupName == nil })
    }

    /// v1 rows (no v2 column) and JSON-null v2 columns decode the same: a plain task.
    @Test func jsonNullRecurrenceIsAPlainTask() throws {
        let v1 = try Fixture.decode(TaskDTO.self, "create_task").item()
        let json = try String(decoding: Fixture.data("create_task"), as: UTF8.self)
        let nulls = json.replacingOccurrences(
            of: #""completed_at":null}"#,
            with: #""completed_at":null,"repeat_freq":null,"repeat_interval":1,"repeat_weekdays":null,"#
                + #""repeat_month_day":null,"repeat_tz":null,"series_id":null,"next_occurrence_id":null,"rotation":null,"#
                + #""turn_user_id":null,"completed_by":null}"#
        )
        #expect(nulls != json)
        let v2 = try RestDecoding.decode(TaskDTO.self, from: Data(nulls.utf8)).item()
        #expect(v2 == v1)
        #expect(v2.recurrence == nil && v2.rotation.isEmpty && v2.checklist.isEmpty)
    }

    @Test func rpcRowsCarryTheV2Columns() throws {
        let created = try Fixture.decode(TaskDTO.self, "v2_create_task")
        #expect(created.assignees == nil && created.checklist == nil, "bare row")
        #expect(created.rotation == [V2Seed.lucas, V2Seed.camille])
        #expect(created.turnUserId == V2Seed.lucas, "rotation[1] takes the first turn")
        #expect(created.recurrence?.weekdays == [1, 3, 5])
        #expect(created.item().seriesId == V2Seed.vaisselle)

        let done = try Fixture.decode(TaskDTO.self, "v2_set_task_status").item()
        #expect(done.status == .done)
        #expect(done.completedBy == V2Seed.lucas)
        #expect(done.nextOccurrenceId == V2Seed.vaisselleNext)
    }

    @Test func myTasksCarryTheGroupAppearance() throws {
        let rows = try Fixture.decode([TaskDTO].self, "v2_my_tasks")
        let tasks = rows.map(\.myTaskItem)
        #expect(tasks.count == 4)
        #expect(tasks.allSatisfy { $0.groupName == "Coloc fixture" && $0.groupColor == .coral && $0.groupEmoji == "🏠" })
        let turn = try #require(tasks.first { $0.id == V2Seed.vaisselleNext })
        #expect(turn.myAssignedBy == nil, "a turn handed out by the server")
        #expect(turn.checklist.map(\.position) == [1, 3])
        // Without the personal fields, a myTasks item is the group task.
        let groupTasks = try Fixture.decode([TaskDTO].self, "v2_group_tasks").map { $0.item() }
        for task in tasks {
            var plain = task
            plain.myAssignedAt = nil
            plain.myAssignedBy = nil
            plain.groupName = nil
            plain.groupColor = nil
            plain.groupEmoji = nil
            #expect(plain == groupTasks.first { $0.id == task.id })
        }
    }

    @Test func assignmentsFlagRotationTurns() throws {
        let events = try Fixture.decode([AssignmentRow].self, "v2_assignments").compactMap(\.event)
        #expect(events.map(\.taskId) == [V2Seed.vaisselleNext, V2Seed.poubelles])
        #expect(events[0].taskHasRotation)
        #expect(events[0].assignedBy == nil)
        #expect(events[0].isRotationTurn, "« C’est ton tour »")
        #expect(events[0].groupName == "Coloc fixture")
        #expect(!events[1].taskHasRotation)
        #expect(events[1].assignedBy == V2Seed.lucas)
        #expect(!events[1].isRotationTurn)
    }

    @Test func activityEvents() throws {
        let rows = try Fixture.decode([ActivityRow].self, "v2_activity")
        let events = rows.map(\.event)
        #expect(events.count == 11)
        #expect(events.map(\.id) == Array((185...195).reversed()).map(Int64.init), "newest first")
        #expect(events.map(\.kind) == [
            .memberLeft, .taskCreated, .taskCompleted, .taskCreated, .taskCreated, .turnStarted, .taskCompleted,
            .checklistItemDone, .taskCreated, .memberJoined, .memberJoined,
        ])
        let turn = try #require(events.first { $0.kind == .turnStarted })
        #expect(turn.actorId == nil)
        #expect(turn.subjectId == V2Seed.camille)
        #expect(turn.taskId == V2Seed.vaisselleNext)
        #expect(turn.taskTitle == "Vaisselle")
        let checked = try #require(events.first { $0.kind == .checklistItemDone })
        #expect(checked.actorId == V2Seed.lucas)
        #expect(checked.itemTitle == "Laver")
        #expect(checked.taskId == V2Seed.vaisselle)
        #expect(PostgresTimestamp.format(checked.createdAt) == "2026-09-25T02:25:55.092936Z")
        let left = try #require(events.first)
        #expect(left.actorId == V2Seed.ines && left.subjectId == V2Seed.ines)
        #expect(left.taskId == nil && left.taskTitle == nil && left.itemTitle == nil)
    }

    @Test func completionsAndChecklistRows() throws {
        let completions = try Fixture.decode([CompletionRow].self, "v2_completions").map(\.completion)
        let first = try #require(PostgresTimestamp.parse("2026-09-25T02:25:55.124686+00:00"))
        let second = try #require(PostgresTimestamp.parse("2026-09-25T02:25:55.241404+00:00"))
        #expect(completions == [
            TaskCompletion(taskId: V2Seed.vaisselle, completedBy: V2Seed.lucas, completedAt: first),
            TaskCompletion(taskId: V2Seed.courses, completedBy: V2Seed.camille, completedAt: second),
        ])
        let item = try Fixture.decode(ChecklistItemRow.self, "v2_checklist_item").item
        #expect(item.id == V2Seed.laver)
        #expect(item.title == "Laver")
        #expect(item.position == 1)
        #expect(item.isDone)
        #expect(item.doneBy == V2Seed.lucas)
        #expect(item.doneAt.map(PostgresTimestamp.format) == "2026-09-25T02:25:55.092936Z")
    }

    /// A rule without its time zone cannot be stored (check constraint): such an answer is malformed.
    @Test func frequencyWithoutTimeZoneIsMalformed() throws {
        let json = try String(decoding: Fixture.data("v2_create_task"), as: UTF8.self)
        let broken = json.replacingOccurrences(of: #""repeat_tz":"Europe/Paris""#, with: #""repeat_tz":null"#)
        #expect(broken != json)
        #expect(throws: AppError.unknown(SupabaseErrorMapping.unexpectedAnswer)) {
            try RestDecoding.decode(TaskDTO.self, from: Data(broken.utf8))
        }
    }
}

/// Forward compatibility of the v2 list reads (docs/CONTRACTS.md §9): an activity kind or a repetition frequency added
/// by a later version leaves only its row out; a color never does.
@Suite struct V2LossyDecodingTests {
    @Test func unknownActivityKindLeavesOnlyThoseEventsOut() async throws {
        let json = try String(decoding: Fixture.data("v2_activity"), as: UTF8.self)
        let newer = json.replacingOccurrences(of: #""kind":"member_joined""#, with: #""kind":"member_promoted""#)
        #expect(newer != json)
        let events = try await UnitBackend.services(FakeTransport([.json(200, newer)])).groups.activity(groupId: V2Seed.group)
        #expect(events.count == 9)
        #expect(!events.contains { $0.kind == .memberJoined })
        #expect(events.map(\.id) == Array((187...195).reversed()).map(Int64.init))
    }

    @Test func unknownFrequencyLeavesTheTaskOut() async throws {
        let json = try String(decoding: Fixture.data("v2_group_tasks"), as: UTF8.self)
        let newer = json.replacingOccurrences(of: #""repeat_freq":"monthly""#, with: #""repeat_freq":"yearly""#)
        #expect(newer != json)
        let tasks = try await UnitBackend.services(FakeTransport([.json(200, newer)])).tasks
            .tasks(groupId: V2Seed.group, includeOldDone: true)
        #expect(tasks.count == 4)
        #expect(!tasks.contains { $0.id == V2Seed.loyer })

        // A single read of that task is an unexpected answer (an edit would overwrite its rule).
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(newer.utf8)) as? [[String: Any]])
        let loyer = try #require(rows.first { $0["id"] as? String == V2Seed.loyer.uuidString.lowercased() })
        let single = String(decoding: try JSONSerialization.data(withJSONObject: [loyer]), as: UTF8.self)
        let service = UnitBackend.services(FakeTransport([.json(200, single)])).tasks
        await #expect(throws: AppError.unknown(SupabaseErrorMapping.unexpectedAnswer)) { try await service.task(id: V2Seed.loyer) }
    }

    @Test func unknownGroupColorKeepsTheTaskInMyTasks() async throws {
        let json = try String(decoding: Fixture.data("v2_my_tasks"), as: UTF8.self)
        let newer = json.replacingOccurrences(of: #""color": "coral""#, with: #""color": "magenta""#)
        #expect(newer != json)
        let tasks = try await UnitBackend.services(FakeTransport([.json(200, newer)])).tasks.myTasks(includeDone: true)
        #expect(tasks.count == 4)
        #expect(tasks.allSatisfy { $0.groupColor == nil && $0.groupEmoji == "🏠" })
    }

    @Test func unknownGroupColorKeepsTheGroupInMyGroups() async throws {
        let json = #"[{"role":"admin","group":{"id":"68b726d0-9f22-460c-8410-39efeead2cc1","name":"Coloc fixture","#
            + #""created_by":null,"created_at":"2026-09-25T02:25:54.55822+00:00","#
            + #""last_activity_at":"2026-09-25T02:25:54.55822+00:00","color":"magenta","emoji":"🏠"}}]"#
        let groups = try await UnitBackend.services(FakeTransport([.json(200, json)])).groups.myGroups()
        #expect(groups.map(\.id) == [V2Seed.group])
        #expect(groups.first?.group.color == nil)
        #expect(groups.first?.group.emoji == "🏠")
    }
}
