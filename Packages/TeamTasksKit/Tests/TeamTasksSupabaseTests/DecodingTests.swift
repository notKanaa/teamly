import Foundation
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

/// Decoding of real PostgREST answers (captured fixtures): embedded aliases, nulls, enums, timestamps.
@Suite struct DecodingTests {
    @Test func myGroupsEmbedsTheGroup() throws {
        let rows = try Fixture.decode([MyGroupRow].self, "my_groups")
        #expect(rows.map(\.role) == [.admin, .member])
        let lilas = rows[0].summary
        #expect(lilas.id == Seed.lilas)
        #expect(lilas.myRole == .admin)
        #expect(lilas.group.name == "Coloc' rue des Lilas")
        #expect(lilas.group.createdBy == Seed.camille)
        #expect(PostgresTimestamp.format(lilas.group.createdAt) == "2026-09-13T23:52:26.878215Z")
        #expect(PostgresTimestamp.format(lilas.group.lastActivityAt) == "2026-09-23T23:52:26.878215Z")
    }

    @Test func membersEmbedTheProfile() throws {
        let rows = try Fixture.decode([MemberRow].self, "members")
        let members = rows.map { $0.membership(groupId: Seed.lilas) }
        #expect(members.map(\.user.id) == [Seed.camille, Seed.lucas, Seed.ines])
        #expect(members.map(\.user.displayName) == ["Camille Martin", "Lucas Bernard", "Inès Dubois"])
        #expect(members.map(\.role) == [.admin, .member, .member])
        #expect(members.allSatisfy { $0.groupId == Seed.lilas })
        #expect(PostgresTimestamp.format(members[1].joinedAt) == "2026-09-14T23:52:26.878215Z")
    }

    @Test func groupTasksHaveSortedAssigneesAndNoPersonalFields() throws {
        let tasks = try Fixture.decode([TaskDTO].self, "group_tasks").map { $0.item() }
        #expect(tasks.count == 5)
        let courses = try #require(tasks.first { $0.id == Seed.courses })
        // The server lists Lucas then Camille: the adapter sorts by uuidString.
        #expect(courses.assigneeIds == [Seed.camille, Seed.lucas])
        #expect(courses.status == .inProgress)
        #expect(courses.priority == .medium)
        #expect(courses.details == "Lait, pâtes, lessive et papier toilette.")
        #expect(courses.createdBy == Seed.lucas)
        #expect(tasks.allSatisfy { $0.myAssignedAt == nil && $0.myAssignedBy == nil && $0.groupName == nil })
        let cuisine = try #require(tasks.first { $0.id == Seed.cuisine })
        #expect(cuisine.status == .done)
        #expect(cuisine.details == nil)
        #expect(cuisine.dueAt == nil)
        #expect(cuisine.completedAt.map(PostgresTimestamp.format) == "2026-09-22T23:52:26.878215Z")
        let unassigned = try #require(tasks.first { $0.title == "Réparer la fuite du lavabo" })
        #expect(unassigned.assigneeIds.isEmpty)
    }

    @Test func myTasksFillMyAssignedAtAndGroupName() throws {
        let rows = try Fixture.decode([TaskDTO].self, "my_tasks")
        let tasks = rows.map(\.myTaskItem)
        let courses = try #require(tasks.first { $0.id == Seed.courses })
        #expect(courses.groupName == "Coloc' rue des Lilas")
        #expect(courses.myAssignedAt.map(PostgresTimestamp.format) == "2026-09-21T23:52:26.878215Z")
        #expect(courses.myAssignedBy == Seed.lucas)
        #expect(courses.assigneeIds == [Seed.camille, Seed.lucas], "every assignee, not only me")
        let gymnase = try #require(tasks.first { $0.id == Seed.gymnase })
        #expect(gymnase.groupName == "Projet Asso Sport")
        let poubelles = try #require(tasks.first { $0.id == Seed.poubelles })
        #expect(poubelles.myAssignedBy == Seed.camille, "self-assignment")
        // Without the personal fields, a myTasks item is the plain task.
        var plain = courses
        plain.myAssignedAt = nil
        plain.myAssignedBy = nil
        plain.groupName = nil
        #expect(plain == rows.first { $0.id == Seed.courses }?.item())
    }

    @Test func assignmentsEmbedTaskAndGroup() throws {
        let events = try Fixture.decode([AssignmentRow].self, "assignments").compactMap(\.event)
        #expect(events.map(\.taskId) == [Seed.gymnase, Seed.cuisine, Seed.courses])
        #expect(events[0].taskTitle == "Réserver le gymnase")
        #expect(events[0].groupName == "Projet Asso Sport")
        #expect(events[0].groupId == Seed.sport)
        #expect(events[0].assignedBy == Seed.lucas)
        #expect(events[0].dueAt.map(PostgresTimestamp.format) == "2026-09-27T16:00:00.000000Z")
        #expect(events[1].dueAt == nil)
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.assignedAt < $1.assignedAt })
    }

    @Test func assignmentWithADeletedAssignerKeepsANilAssignedBy() throws {
        let json = """
        [{"task_id":"b0000000-0000-4000-8000-000000000001","group_id":"a0000000-0000-4000-8000-000000000001",\
        "assigned_by":null,"assigned_at":"2026-09-20T23:52:26.8+00:00",\
        "task":{"group": {"name": "Coloc' rue des Lilas"}, "title": "Sortir les poubelles", "due_at": null}}]
        """
        let rows = try RestDecoding.makeDecoder().decode([AssignmentRow].self, from: Data(json.utf8))
        let event = try #require(rows.first?.event)
        #expect(event.assignedBy == nil)
        #expect(PostgresTimestamp.format(event.assignedAt) == "2026-09-20T23:52:26.800000Z")
    }

    @Test func profileAndInviteAndTopic() throws {
        let profile = try Fixture.decode([ProfileRow].self, "profile")
        #expect(profile.map(\.profile) == [UserProfile(id: Seed.camille, displayName: "Camille Martin")])
        let invite = try Fixture.decode([InviteRow].self, "invite_code")
        #expect(invite.map(\.code) == ["LYLAS234"])
        #expect(try Fixture.decode(String.self, "regenerate") == "NYCXWUA4")
    }

    @Test func rpcRowsAreBareRows() throws {
        let group = try Fixture.decode(GroupRow.self, "create_group")
        #expect(group.name == "Groupe fixture")
        #expect(group.createdAt == group.lastActivityAt)
        let created = try Fixture.decode(TaskDTO.self, "create_task")
        #expect(created.assignees == nil)
        #expect(created.item().assigneeIds.isEmpty)
        #expect(created.item(assigneeIds: [Seed.lucas, Seed.camille, Seed.lucas]).assigneeIds == [Seed.camille, Seed.lucas])
        #expect(created.dueAt == Date(timeIntervalSince1970: 1_924_992_000))
        let done = try Fixture.decode(TaskDTO.self, "set_task_status")
        #expect(done.status == .done)
        #expect(done.completedAt == done.updatedAt)
    }

    @Test func joinResults() throws {
        let joined = try Fixture.decode(JoinRow.self, "join_joined").result()
        #expect(joined == JoinResult(groupId: Seed.sport, groupName: "Projet Asso Sport", alreadyMember: false))
        let again = try Fixture.decode(JoinRow.self, "join_already_member").result()
        #expect(again == JoinResult(groupId: Seed.lilas, groupName: "Coloc' rue des Lilas", alreadyMember: true))
        let invalid = try Fixture.decode(JoinRow.self, "join_invalid_code")
        #expect(throws: AppError.invalidCode) { try invalid.result() }
    }

    @Test func unexpectedJSONIsAnUnknownError() {
        #expect(throws: AppError.unknown("réponse inattendue du serveur")) {
            try RestDecoding.decode([TaskDTO].self, from: Data(#"{"message":"oops"}"#.utf8))
        }
    }
}
