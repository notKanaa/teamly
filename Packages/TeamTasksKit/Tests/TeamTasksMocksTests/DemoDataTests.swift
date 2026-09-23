import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

/// The demo data must match docs/CONTRACTS.md §8 exactly.
@Suite struct DemoDataTests {
    static let calendar = DemoData.calendar

    static func parisDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Wednesday 2026-09-23 10:00 in Paris.
    let now = DemoDataTests.parisDate(2026, 9, 23, 10)

    func camille() -> AppServices {
        let now = now
        return InMemoryBackend.demo(now: { now }).services(for: DemoData.camille.id)
    }

    @Test func usersEmailsAndDisplayNames() async throws {
        #expect(DemoData.password == "motdepasse123")
        #expect(DemoData.users.map(\.email) == ["camille@example.com", "lucas@example.com", "ines@example.com"])
        #expect(DemoData.users.map(\.displayName) == ["Camille Martin", "Lucas Bernard", "Inès Dubois"])
        let backend = InMemoryBackend.demo()
        for user in DemoData.users {
            let services = backend.services(for: nil)
            try await services.auth.signIn(email: user.email, password: DemoData.password)
            let current = await services.auth.currentUser()
            #expect(current == AuthUser(id: user.id, email: user.email))
            let profile = try await services.profiles.myProfile()
            #expect(profile == UserProfile(id: user.id, displayName: user.displayName))
        }
        #expect(backend.userId(forEmail: DemoData.newcomer.email) == nil)
    }

    @Test func groupsRolesAndInviteCodes() async throws {
        let backend = InMemoryBackend.demo()
        let camille = backend.services(for: DemoData.camille.id)
        let lucas = backend.services(for: DemoData.lucas.id)
        let ines = backend.services(for: DemoData.ines.id)

        let groups = try await camille.groups.myGroups()
        #expect(groups.map(\.group.name) == ["Coloc' rue des Lilas", "Projet Asso Sport"])
        #expect(groups.map(\.myRole) == [.admin, .member])
        #expect(groups.map(\.id) == [DemoData.lilasGroupId, DemoData.sportGroupId])
        let inesGroups = try await ines.groups.myGroups()
        #expect(inesGroups.map(\.id) == [DemoData.lilasGroupId])

        let lilas = try await camille.groups.members(groupId: DemoData.lilasGroupId)
        #expect(lilas.map(\.user.displayName) == ["Camille Martin", "Inès Dubois", "Lucas Bernard"])
        #expect(lilas.map(\.role) == [.admin, .member, .member])
        let sport = try await camille.groups.members(groupId: DemoData.sportGroupId)
        #expect(sport.map(\.user.displayName) == ["Lucas Bernard", "Camille Martin"])
        #expect(sport.map(\.role) == [.admin, .member])

        #expect(try await camille.groups.inviteCode(groupId: DemoData.lilasGroupId).value == "LYLAS234")
        #expect(try await lucas.groups.inviteCode(groupId: DemoData.sportGroupId).value == "SPRT5678")
        await #expect(throws: AppError.forbidden) { try await camille.groups.inviteCode(groupId: DemoData.sportGroupId) }
        await #expect(throws: AppError.forbidden) { try await ines.groups.inviteCode(groupId: DemoData.lilasGroupId) }
    }

    @Test func lilasTasks() async throws {
        let services = camille()
        let tasks = try await services.tasks.tasks(groupId: DemoData.lilasGroupId, includeOldDone: false)
        let byTitle = Dictionary(uniqueKeysWithValues: tasks.map { ($0.title, $0) })
        #expect(Set(byTitle.keys) == [
            "Sortir les poubelles", "Faire les courses", "Payer le loyer", "Réparer la fuite du lavabo", "Nettoyer la cuisine",
        ])
        let camilleId = DemoData.camille.id
        let lucasId = DemoData.lucas.id

        let poubelles = try #require(byTitle["Sortir les poubelles"])
        #expect(poubelles.assigneeIds == [camilleId])
        #expect(poubelles.priority == .high)
        #expect(poubelles.status == .todo)
        #expect(poubelles.dueAt == Self.parisDate(2026, 9, 23, 20))

        let courses = try #require(byTitle["Faire les courses"])
        #expect(courses.assigneeIds == [lucasId, camilleId].sorted { $0.uuidString < $1.uuidString })
        #expect(courses.priority == .medium)
        #expect(courses.status == .inProgress)
        #expect(courses.dueAt == Self.parisDate(2026, 9, 24, 10))

        let loyer = try #require(byTitle["Payer le loyer"])
        #expect(loyer.assigneeIds == [DemoData.ines.id])
        #expect(loyer.priority == .high)
        #expect(loyer.status == .todo)
        #expect(loyer.dueAt == Self.parisDate(2026, 9, 22, 10))
        #expect(try #require(loyer.dueAt) < now)

        let fuite = try #require(byTitle["Réparer la fuite du lavabo"])
        #expect(fuite.assigneeIds.isEmpty)
        #expect(fuite.priority == .low)
        #expect(fuite.dueAt == nil)
        #expect(fuite.status == .todo)

        let cuisine = try #require(byTitle["Nettoyer la cuisine"])
        #expect(cuisine.assigneeIds == [camilleId])
        #expect(cuisine.priority == .medium)
        #expect(cuisine.status == .done)
        let completedAt = try #require(cuisine.completedAt)
        #expect(Self.calendar.isDate(completedAt, inSameDayAs: Self.parisDate(2026, 9, 22, 12)))

        for task in tasks {
            #expect(task.groupId == DemoData.lilasGroupId)
            #expect(task.createdAt <= now)
            #expect((task.status == .done) == (task.completedAt != nil))
        }
    }

    @Test func sportTasks() async throws {
        let services = camille()
        let tasks = try await services.tasks.tasks(groupId: DemoData.sportGroupId, includeOldDone: false)
        let byTitle = Dictionary(uniqueKeysWithValues: tasks.map { ($0.title, $0) })
        #expect(Set(byTitle.keys) == ["Réserver le gymnase", "Créer l'affiche du tournoi"])

        let gymnase = try #require(byTitle["Réserver le gymnase"])
        #expect(gymnase.assigneeIds == [DemoData.camille.id])
        #expect(gymnase.priority == .high)
        #expect(gymnase.status == .todo)
        #expect(gymnase.dueAt == Self.parisDate(2026, 9, 26, 10))

        let affiche = try #require(byTitle["Créer l'affiche du tournoi"])
        #expect(affiche.assigneeIds == [DemoData.lucas.id])
        #expect(affiche.priority == .low)
        #expect(affiche.status == .inProgress)
        #expect(affiche.dueAt == Self.parisDate(2026, 9, 30, 10))
    }

    @Test func camillesTasksAndAssignments() async throws {
        let services = camille()
        let open = try await services.tasks.myTasks(includeDone: false)
        #expect(Set(open.map(\.title)) == ["Sortir les poubelles", "Faire les courses", "Réserver le gymnase"])
        let all = try await services.tasks.myTasks(includeDone: true)
        #expect(Set(all.map(\.title)) == [
            "Sortir les poubelles", "Faire les courses", "Réserver le gymnase", "Nettoyer la cuisine",
        ])
        for task in all {
            #expect(task.myAssignedAt != nil)
            #expect(task.groupName == (task.groupId == DemoData.lilasGroupId ? DemoData.lilasGroupName : DemoData.sportGroupName))
        }
        // Assigned to Camille by Lucas, oldest first; her self-assignments are excluded.
        let events = try await services.tasks.assignments(since: .distantPast)
        #expect(events.map(\.taskTitle) == ["Réserver le gymnase", "Faire les courses"])
        #expect(events.allSatisfy { $0.assignedBy == DemoData.lucas.id })
    }

    /// "Tomorrow" is a calendar day in Paris, also across the October DST change.
    @Test func relativeDatesUseTheParisCalendar() async throws {
        let beforeDSTChange = Self.parisDate(2026, 10, 24, 10)
        let services = InMemoryBackend.demo(now: { beforeDSTChange }).services(for: DemoData.camille.id)
        let courses = try await services.tasks.task(id: DemoData.TaskIDs.faireCourses)
        #expect(courses.dueAt == Self.parisDate(2026, 10, 25, 10))
        let delay = try #require(courses.dueAt).timeIntervalSince(beforeDSTChange)
        #expect(delay == TimeInterval(25 * 3600))
        let poubelles = try await services.tasks.task(id: DemoData.TaskIDs.sortirPoubelles)
        #expect(poubelles.dueAt == Self.parisDate(2026, 10, 24, 20))
    }

    @Test func demoGroupsAreOrderedByActivity() async throws {
        let services = camille()
        let groups = try await services.groups.myGroups()
        #expect(groups[0].group.lastActivityAt > groups[1].group.lastActivityAt)
        #expect(groups.allSatisfy { $0.group.lastActivityAt <= now })
    }
}
