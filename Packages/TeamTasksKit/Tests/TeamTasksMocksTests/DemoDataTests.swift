import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

/// The demo data must match docs/CONTRACTS.md §8 and `supabase/seed.sql` (canonical) exactly.
@Suite struct DemoDataTests {
    static let calendar = DemoData.calendar

    static func parisDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Wednesday 2026-09-23 10:00 in Paris.
    let now = DemoDataTests.parisDate(2026, 9, 23, 10)

    /// `now() - interval 'N days'` of the seed (run in a UTC session: exactly N × 24 hours).
    func ago(days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    func camille() -> AppServices {
        let now = now
        return InMemoryBackend.demo(now: { now }).services(for: DemoData.camille.id)
    }

    @Test func usersIdsEmailsAndDisplayNames() async throws {
        #expect(DemoData.password == "motdepasse123")
        #expect(DemoData.users.map(\.id) == [
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
        ])
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

        #expect(DemoData.lilasGroupId == UUID(uuidString: "a0000000-0000-4000-8000-000000000001"))
        #expect(DemoData.sportGroupId == UUID(uuidString: "a0000000-0000-4000-8000-000000000002"))
        let groups = try await camille.groups.myGroups()
        #expect(groups.map(\.group.name) == ["Coloc' rue des Lilas", "Projet Asso Sport"])
        #expect(groups.map(\.myRole) == [.admin, .member])
        #expect(groups.map(\.id) == [DemoData.lilasGroupId, DemoData.sportGroupId])
        #expect(groups.map(\.group.createdBy) == [DemoData.camille.id, DemoData.lucas.id])
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

    /// seed.sql: groups created 10 / 20 days ago; `joined_at` per member; the AFTER triggers of the member,
    /// task and assignee inserts set `last_activity_at` of both groups to the seed time (an exact tie, broken
    /// by name).
    @Test func groupAndMembershipDates() async throws {
        let services = camille()
        let groups = try await services.groups.myGroups()
        #expect(groups.map(\.group.createdAt) == [ago(days: 10), ago(days: 20)])
        #expect(groups.map(\.group.lastActivityAt) == [now, now])

        let lilas = try await services.groups.members(groupId: DemoData.lilasGroupId)
        #expect(lilas.map(\.user.id) == [DemoData.camille.id, DemoData.ines.id, DemoData.lucas.id])
        #expect(lilas.map(\.joinedAt) == [ago(days: 10), ago(days: 8), ago(days: 9)])
        let sport = try await services.groups.members(groupId: DemoData.sportGroupId)
        #expect(sport.map(\.user.id) == [DemoData.lucas.id, DemoData.camille.id])
        #expect(sport.map(\.joinedAt) == [ago(days: 20), ago(days: 15)])
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
        let inesId = DemoData.ines.id

        let poubelles = try #require(byTitle["Sortir les poubelles"])
        #expect(poubelles.id == DemoData.TaskIDs.sortirPoubelles)
        #expect(poubelles.details == "Poubelle jaune et poubelle verte.")
        #expect(poubelles.assigneeIds == [camilleId])
        #expect(poubelles.priority == .high)
        #expect(poubelles.status == .todo)
        #expect(poubelles.dueAt == Self.parisDate(2026, 9, 23, 20))
        #expect(poubelles.createdBy == camilleId)
        #expect(poubelles.createdAt == ago(days: 3))

        let courses = try #require(byTitle["Faire les courses"])
        #expect(courses.id == DemoData.TaskIDs.faireCourses)
        #expect(courses.details == "Lait, pâtes, lessive et papier toilette.")
        #expect(courses.assigneeIds == [lucasId, camilleId].sorted { $0.uuidString < $1.uuidString })
        #expect(courses.priority == .medium)
        #expect(courses.status == .inProgress)
        #expect(courses.dueAt == Self.parisDate(2026, 9, 24, 18))
        #expect(courses.createdBy == lucasId)
        #expect(courses.createdAt == ago(days: 2))

        let loyer = try #require(byTitle["Payer le loyer"])
        #expect(loyer.id == DemoData.TaskIDs.payerLoyer)
        #expect(loyer.details == nil)
        #expect(loyer.assigneeIds == [inesId])
        #expect(loyer.priority == .high)
        #expect(loyer.status == .todo)
        #expect(loyer.dueAt == Self.parisDate(2026, 9, 22, 18), "yesterday 18:00 in Paris")
        #expect(loyer.createdBy == camilleId)
        #expect(loyer.createdAt == ago(days: 6))

        let fuite = try #require(byTitle["Réparer la fuite du lavabo"])
        #expect(fuite.id == DemoData.TaskIDs.reparerFuite)
        #expect(fuite.details == "Le joint sous le lavabo de la salle de bain goutte.")
        #expect(fuite.assigneeIds.isEmpty)
        #expect(fuite.priority == .low)
        #expect(fuite.dueAt == nil)
        #expect(fuite.status == .todo)
        #expect(fuite.createdBy == inesId)
        #expect(fuite.createdAt == ago(days: 5))

        let cuisine = try #require(byTitle["Nettoyer la cuisine"])
        #expect(cuisine.id == DemoData.TaskIDs.nettoyerCuisine)
        #expect(cuisine.details == nil)
        #expect(cuisine.assigneeIds == [camilleId])
        #expect(cuisine.priority == .medium)
        #expect(cuisine.status == .done)
        #expect(cuisine.dueAt == nil)
        #expect(cuisine.createdBy == lucasId)
        #expect(cuisine.createdAt == ago(days: 4))
        #expect(cuisine.completedAt == Self.parisDate(2026, 9, 22, 19), "yesterday 19:00 in Paris")

        for task in tasks {
            #expect(task.groupId == DemoData.lilasGroupId)
            #expect(task.updatedAt == task.createdAt)
            #expect((task.status == .done) == (task.completedAt != nil))
        }
    }

    @Test func sportTasks() async throws {
        let services = camille()
        let tasks = try await services.tasks.tasks(groupId: DemoData.sportGroupId, includeOldDone: false)
        let byTitle = Dictionary(uniqueKeysWithValues: tasks.map { ($0.title, $0) })
        #expect(Set(byTitle.keys) == ["Réserver le gymnase", "Créer l'affiche du tournoi"])

        let gymnase = try #require(byTitle["Réserver le gymnase"])
        #expect(gymnase.id == DemoData.TaskIDs.reserverGymnase)
        #expect(gymnase.details == "Samedi après-midi, pour le tournoi.")
        #expect(gymnase.assigneeIds == [DemoData.camille.id])
        #expect(gymnase.priority == .high)
        #expect(gymnase.status == .todo)
        #expect(gymnase.dueAt == Self.parisDate(2026, 9, 26, 18))
        #expect(gymnase.createdBy == DemoData.lucas.id)
        #expect(gymnase.createdAt == ago(days: 7))

        let affiche = try #require(byTitle["Créer l'affiche du tournoi"])
        #expect(affiche.id == DemoData.TaskIDs.creerAffiche)
        #expect(affiche.details == nil)
        #expect(affiche.assigneeIds == [DemoData.lucas.id])
        #expect(affiche.priority == .low)
        #expect(affiche.status == .inProgress)
        #expect(affiche.dueAt == Self.parisDate(2026, 9, 30, 12))
        #expect(affiche.createdBy == DemoData.lucas.id)
        #expect(affiche.createdAt == ago(days: 7))

        for task in tasks {
            #expect(task.updatedAt == task.createdAt)
        }
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
            // seed.sql: assigned_at = the task's created_at.
            #expect(task.myAssignedAt == task.createdAt)
            #expect(task.groupName == (task.groupId == DemoData.lilasGroupId ? DemoData.lilasGroupName : DemoData.sportGroupName))
        }
        // Assigned to Camille by Lucas, oldest first; her self-assignment (poubelles) is excluded.
        let events = try await services.tasks.assignments(since: .distantPast)
        #expect(events.map(\.taskTitle) == ["Réserver le gymnase", "Nettoyer la cuisine", "Faire les courses"])
        #expect(events.map(\.assignedAt) == [ago(days: 7), ago(days: 4), ago(days: 2)])
        #expect(events.allSatisfy { $0.assignedBy == DemoData.lucas.id })
    }

    /// seed.sql: « Nettoyer la cuisine » was created by Lucas, so he may edit and delete it (plain member of Lilas).
    @Test func lucasManagesTheTaskHeCreated() async throws {
        let now = now
        let backend = InMemoryBackend.demo(now: { now })
        let lucas = backend.services(for: DemoData.lucas.id)
        let edited = try await lucas.tasks.update(
            taskId: DemoData.TaskIDs.nettoyerCuisine, draft: TaskDraft(title: "Nettoyer la cuisine !", assigneeIds: [DemoData.camille.id])
        )
        #expect(edited.title == "Nettoyer la cuisine !")
        try await lucas.tasks.delete(taskId: DemoData.TaskIDs.nettoyerCuisine)
        await #expect(throws: AppError.forbidden) {
            try await lucas.tasks.delete(taskId: DemoData.TaskIDs.payerLoyer) // created by Camille
        }
    }

    /// "Tomorrow 18:00", the overdue rent ("yesterday 18:00") and the kitchen done "yesterday 19:00" are Paris
    /// wall-clock times, also across the October DST change.
    @Test func relativeDatesFollowTheSeed() async throws {
        let beforeDSTChange = Self.parisDate(2026, 10, 24, 10)
        let services = InMemoryBackend.demo(now: { beforeDSTChange }).services(for: DemoData.camille.id)
        let courses = try await services.tasks.task(id: DemoData.TaskIDs.faireCourses)
        #expect(courses.dueAt == Self.parisDate(2026, 10, 25, 18))
        let delay = try #require(courses.dueAt).timeIntervalSince(beforeDSTChange)
        #expect(delay == TimeInterval(33 * 3600))
        let poubelles = try await services.tasks.task(id: DemoData.TaskIDs.sortirPoubelles)
        #expect(poubelles.dueAt == Self.parisDate(2026, 10, 24, 20))

        let afterDSTChange = Self.parisDate(2026, 10, 25, 12)
        let later = InMemoryBackend.demo(now: { afterDSTChange }).services(for: DemoData.camille.id)
        let loyer = try await later.tasks.task(id: DemoData.TaskIDs.payerLoyer)
        #expect(loyer.dueAt == Self.parisDate(2026, 10, 24, 18))
        let cuisine = try await later.tasks.task(id: DemoData.TaskIDs.nettoyerCuisine)
        #expect(cuisine.completedAt == Self.parisDate(2026, 10, 24, 19))
        let gymnase = try await later.tasks.task(id: DemoData.TaskIDs.reserverGymnase)
        #expect(gymnase.dueAt == Self.parisDate(2026, 10, 28, 18))
    }

    /// The screenshots are taken at the CI run time: the overdue rent reads « Hier à 18:00 » and the kitchen
    /// « Terminée hier à 19:00 », not the seeding time (review UX-08).
    @Test func pastDemoDatesShowRoundTimesWhateverTheSeedTime() async throws {
        for now in [Self.parisDate(2026, 9, 24, 5, 19), Self.parisDate(2026, 9, 24, 23, 59), Self.parisDate(2026, 9, 24, 0, 1)] {
            let services = InMemoryBackend.demo(now: { now }).services(for: DemoData.camille.id)
            let loyer = try await services.tasks.task(id: DemoData.TaskIDs.payerLoyer)
            let dueAt = try #require(loyer.dueAt)
            #expect(DateText.relative(dueAt, now: now, calendar: Self.calendar) == "Hier à 18:00")
            #expect(dueAt < now, "always overdue")
            let cuisine = try await services.tasks.task(id: DemoData.TaskIDs.nettoyerCuisine)
            let completedAt = try #require(cuisine.completedAt)
            #expect(DateText.relativeInSentence(completedAt, now: now, calendar: Self.calendar) == "hier à 19:00")
            #expect(completedAt < now && completedAt > cuisine.createdAt)
        }
    }

    @Test func demoGroupsTieOnActivityAndAreOrderedByName() async throws {
        let services = camille()
        let groups = try await services.groups.myGroups()
        #expect(groups.map(\.group.lastActivityAt) == [now, now])
        #expect(groups.map(\.group.name) == [DemoData.lilasGroupName, DemoData.sportGroupName])
    }
}
