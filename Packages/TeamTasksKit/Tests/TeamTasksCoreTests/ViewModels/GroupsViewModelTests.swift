import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

@MainActor
@Suite struct GroupsListViewModelTests {
    typealias F = VMFixtures

    @Test func loadsTheGroupsOnce() async {
        let harness = VMHarness()
        let model = GroupsListViewModel(session: harness.makeSession())
        #expect(model.loadState == .idle)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.groups.map(\.id) == [F.lilas, F.sport])
        #expect(model.groups.map(\.myRole) == [.admin, .member])
        #expect(!model.isEmpty)
        #expect(!model.needsRefresh)

        // Idempotent: the key changed (groups listed) but nothing new happened.
        await model.load()
        await model.load()
        #expect(harness.faults.calls(.myGroups) == 1)
        #expect(harness.faults.calls(.overviews) == 1)
    }

    // MARK: - v2 overviews (docs/CONTRACTS-V2.md §10)

    /// One read of every card's figures, from Monday 00:00 of the current week (injected calendar), shown with the
    /// groups.
    @Test func overviewsOfTheCards() async throws {
        let harness = VMHarness()
        let model = GroupsListViewModel(session: harness.makeSession())
        #expect(model.headerText == nil)
        #expect(model.overview(of: F.lilas) == nil)
        await model.load()
        #expect(harness.faults.calls(.overviews) == 1)
        // Thursday 24 September 2026 → Monday 21 September 00:00 in Paris.
        #expect(harness.faults.recordedDates(.overviews) == [F.date(2026, 9, 21)])
        #expect(model.overviewsWeekStart == F.date(2026, 9, 21))

        let lilas = try #require(model.overview(of: F.lilas))
        #expect(lilas.members.map(\.user.id) == [F.camille.id, F.ines.id, F.lucas.id], "admins first, then by name")
        #expect(lilas.openTaskCount == 4)
        #expect(lilas.doneTaskCount == 1, "« Nettoyer la cuisine », done yesterday")
        #expect(lilas.memberCount == 3)
        #expect(lilas.memberAvatars.map(\.initials) == ["CM", "ID", "LB"])
        #expect(lilas.memberAvatars.map(\.color) == lilas.members.map(\.user.resolvedColor))
        #expect(lilas.moreMembersText == nil)
        #expect(lilas.summaryText == "3 membres · 4 à faire")
        #expect(lilas.weekTaskCount == 5)
        #expect(lilas.weekProgressText == "1 faite sur 5")
        #expect(lilas.weekProgress == 0.2)
        #expect(GroupOverview.weekTitle == "Cette semaine")

        let sport = try #require(model.overview(of: F.sport))
        #expect(sport.members.map(\.user.id) == [F.lucas.id, F.camille.id])
        #expect(sport.summaryText == "2 membres · 2 à faire")
        #expect(sport.weekProgressText == "0 faite sur 2")
        #expect(sport.weekProgress == 0)
        #expect(model.headerText == "2 groupes · 6 tâches à faire")
    }

    /// The figures reload with the list: a task completed in a group, a new group.
    @Test func overviewsReloadWithTheList() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = GroupsListViewModel(session: session)
        await model.load()

        _ = try await harness.device(F.lucas).tasks.setStatus(taskId: VMFixtures.Tasks.faireCourses, status: .done)
        session.feed.bump(groupId: F.lilas)
        #expect(model.needsRefresh)
        await model.load()
        #expect(harness.faults.calls(.overviews) == 2)
        #expect(model.overview(of: F.lilas)?.weekProgressText == "2 faites sur 5")
        #expect(model.overview(of: F.lilas)?.summaryText == "3 membres · 3 à faire")
        #expect(model.headerText == "2 groupes · 5 tâches à faire")

        let created = try await harness.device(F.camille).groups.createGroup(name: "Vacances")
        session.feed.bumpMemberships()
        await model.load()
        #expect(harness.faults.calls(.overviews) == 3)
        let vacances = try #require(model.overview(of: created.id))
        #expect(vacances.summaryText == "1 membre · rien à faire")
        #expect(vacances.weekProgressText == "Rien de prévu")
        #expect(vacances.memberAvatars.count == 1)
        #expect(model.headerText == "3 groupes · 5 tâches à faire")
    }

    /// A failed overview read never fails the list: the groups show without figures, then the next load reads again; a
    /// later failure keeps the figures of the week.
    @Test func aFailedOverviewReadKeepsTheList() async throws {
        let harness = VMHarness()
        let model = GroupsListViewModel(session: harness.makeSession())
        harness.faults.fail(.overviews, with: AppError.network)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.groups.count == 2)
        #expect(model.overviews.isEmpty)
        #expect(model.overview(of: F.lilas) == nil)
        #expect(model.headerText == "2 groupes")
        #expect(model.error == nil)
        #expect(model.needsRefresh)

        await model.load()
        #expect(harness.faults.calls(.myGroups) == 2)
        #expect(harness.faults.calls(.overviews) == 2)
        #expect(model.headerText == "2 groupes · 6 tâches à faire")
        #expect(!model.needsRefresh)

        harness.faults.fail(.overviews, with: AppError.network)
        await model.reload()
        #expect(model.overview(of: F.lilas)?.openTaskCount == 4)
        #expect(model.headerText == "2 groupes · 6 tâches à faire")
        #expect(model.error == nil)
        #expect(model.needsRefresh)
    }

    /// A new week reads the figures again, counting the tasks done since the new Monday.
    @Test func aNewWeekReadsTheFiguresAgain() async throws {
        let harness = VMHarness()
        let model = GroupsListViewModel(session: harness.makeSession())
        await model.load()
        #expect(model.overview(of: F.lilas)?.doneTaskCount == 1)
        harness.clock.advance(by: 7 * 86_400)
        #expect(model.needsRefresh)
        await model.load()
        #expect(harness.faults.recordedDates(.overviews) == [F.date(2026, 9, 21), F.date(2026, 9, 28)])
        #expect(model.overviewsWeekStart == F.date(2026, 9, 28))
        #expect(model.overview(of: F.lilas)?.doneTaskCount == 0)
        #expect(model.overview(of: F.lilas)?.openTaskCount == 4)
    }

    @Test func noGroupNoOverviewRead() async throws {
        let harness = VMHarness(.emptyGroups)
        let model = GroupsListViewModel(session: harness.makeSession())
        await model.load()
        #expect(model.isEmpty)
        #expect(model.headerText == nil)
        #expect(harness.faults.calls(.overviews) == 0)

        _ = try await harness.services.groups.createGroup(name: "Solo")
        await model.reload()
        #expect(model.headerText == "1 groupe · aucune tâche à faire")
        #expect(harness.faults.calls(.overviews) == 1)
    }

    /// A card shows at most 3 circles: every avatar up to 3 members, else 2 avatars and « +N ».
    @Test func avatarsOfTheCards() {
        func overview(members count: Int, open: Int = 0, done: Int = 0) -> GroupOverview {
            let group = UUID()
            let members = (0..<count).map { index in
                Membership(
                    groupId: group, user: UserProfile(id: UUID(), displayName: "Membre \(index)", avatarEmoji: index == 0 ? "🦊" : nil),
                    role: index == 0 ? .admin : .member, joinedAt: F.now
                )
            }
            return GroupOverview(groupId: group, members: members, openTaskCount: open, doneTaskCount: done)
        }
        #expect(GroupOverview.avatarSlots == 3)
        #expect(overview(members: 1).memberAvatars.map(\.symbol) == ["🦊"])
        #expect(overview(members: 3).memberAvatars.map(\.symbol) == ["🦊", "M1", "M2"])
        #expect(overview(members: 3).moreMembersText == nil)
        #expect(overview(members: 4).memberAvatars.map(\.symbol) == ["🦊", "M1"])
        #expect(overview(members: 4).moreMembersText == "+2")
        #expect(overview(members: 12).moreMembersText == "+10")
        #expect(overview(members: 1).membersText == "1 membre")
        #expect(overview(members: 2, open: 1, done: 1).summaryText == "2 membres · 1 à faire")
        #expect(overview(members: 2, open: 1, done: 1).weekProgressText == "1 faite sur 2")
        #expect(overview(members: 2, open: 0, done: 3).weekProgressText == "3 faites sur 3")
        #expect(overview(members: 2, open: 0, done: 3).weekProgress == 1)
        #expect(overview(members: 2).openText == "rien à faire")
    }

    /// The counting shared by the backends: open = not done; done = completed at or after `doneSince`.
    @Test func overviewCounting() {
        let group = UUID()
        let since = F.date(2026, 9, 21)
        let lucas = Membership(groupId: group, user: UserProfile(id: F.lucas.id, displayName: "Lucas Bernard"), role: .member, joinedAt: F.now)
        let camille = Membership(groupId: group, user: UserProfile(id: F.camille.id, displayName: "Camille Martin"), role: .admin, joinedAt: F.now)
        let overview = GroupOverview(groupId: group, members: [lucas, camille], tasks: [
            .init(status: .todo, completedAt: nil),
            .init(status: .inProgress, completedAt: nil),
            .init(status: .done, completedAt: since),
            .init(status: .done, completedAt: since.addingTimeInterval(-1)),
            .init(status: .done, completedAt: nil),
        ], doneSince: since)
        #expect(overview.members == [camille, lucas], "sorted like members(groupId:)")
        #expect(overview.openTaskCount == 2)
        #expect(overview.doneTaskCount == 1)
    }

    @Test func emptyState() async {
        let harness = VMHarness(.emptyGroups)
        let model = GroupsListViewModel(session: harness.makeSession())
        await model.load()
        #expect(model.isEmpty)
        #expect(GroupsListViewModel.emptyMessage.contains("code d’invitation"))
    }

    @Test func reloadsOnMembershipsAndGroupActivity() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = GroupsListViewModel(session: session)
        await model.load()
        let key = model.refreshKey

        // Lucas renames a group on another device; the realtime signal bumps that group's revision.
        _ = try await harness.device(F.lucas).groups.rename(groupId: F.sport, name: "Asso Sport")
        session.feed.bump(groupId: F.sport)
        #expect(model.refreshKey != key)
        #expect(model.needsRefresh)
        await model.load()
        #expect(harness.faults.calls(.myGroups) == 2)
        #expect(model.groups.contains { $0.group.name == "Asso Sport" })

        // A membership change (here a group created elsewhere) reloads too.
        _ = try await harness.device(F.camille).groups.createGroup(name: "Vacances")
        session.feed.bumpMemberships()
        await model.load()
        #expect(model.groups.count == 3)
        #expect(harness.faults.calls(.myGroups) == 3)
        // The new group in the list changes the key but does not trigger another fetch.
        await model.load()
        #expect(harness.faults.calls(.myGroups) == 3)
        #expect(!model.needsRefresh)
    }

    @Test func firstLoadFailureThenRetry() async {
        let harness = VMHarness()
        let model = GroupsListViewModel(session: harness.makeSession())
        harness.faults.fail(.myGroups, with: AppError.network)
        await model.load()
        #expect(model.loadState == .failed(AppError.network.messageFR))
        #expect(model.error == nil)
        await model.reload()
        #expect(model.loadState == .loaded)
        #expect(model.groups.count == 2)
    }

    @Test func laterFailureKeepsTheContent() async {
        let harness = VMHarness()
        let model = GroupsListViewModel(session: harness.makeSession())
        await model.load()
        harness.faults.fail(.myGroups, with: AppError.network)
        await model.reload()
        #expect(model.loadState == .loaded)
        #expect(model.groups.count == 2)
        #expect(model.errorMessage == AppError.network.messageFR)
    }

    @Test func cancellationIsIgnored() async {
        let harness = VMHarness()
        let model = GroupsListViewModel(session: harness.makeSession())
        harness.faults.fail(.myGroups, with: CancellationError())
        await model.load()
        #expect(model.loadState == .idle)
        #expect(model.error == nil)
        harness.faults.fail(.myGroups, with: AppError.wrap(CancellationError()))
        await model.load()
        #expect(model.loadState == .idle)
        #expect(model.error == nil)
        await model.load()
        #expect(model.loadState == .loaded)
    }

    @Test func concurrentLoadsShareOneFetch() async {
        let harness = VMHarness()
        let model = GroupsListViewModel(session: harness.makeSession())
        harness.faults.hold(.myGroups)
        let first = Task { await model.load() }
        let second = Task { await model.load() }
        await VMWait.until("fetch started") { harness.faults.waiting(.myGroups) == 1 }
        #expect(model.loadState == .loading)
        await VMWait.settle()
        harness.faults.release(.myGroups)
        await first.value
        await second.value
        #expect(harness.faults.calls(.myGroups) == 1)
        #expect(model.loadState == .loaded)
    }

    @Test func reloadDuringAFetchRunsOnceMore() async {
        let harness = VMHarness()
        let model = GroupsListViewModel(session: harness.makeSession())
        harness.faults.hold(.myGroups)
        let first = Task { await model.load() }
        await VMWait.until("fetch started") { harness.faults.waiting(.myGroups) == 1 }
        let pull = Task { await model.reload() }
        let pullAgain = Task { await model.reload() }
        await VMWait.settle()
        harness.faults.release(.myGroups)
        await first.value
        await pull.value
        await pullAgain.value
        #expect(harness.faults.calls(.myGroups) == 2)
    }

    @Test func cancellingTheCallerDoesNotCancelTheFetch() async {
        let harness = VMHarness()
        let model = GroupsListViewModel(session: harness.makeSession())
        harness.faults.hold(.myGroups)
        let caller = Task { await model.load() }
        await VMWait.until("fetch started") { harness.faults.waiting(.myGroups) == 1 }
        caller.cancel()
        await VMWait.settle()
        harness.faults.release(.myGroups)
        await caller.value
        #expect(model.loadState == .loaded)
        #expect(model.error == nil)
        #expect(model.groups.count == 2)
    }
}

@MainActor
@Suite struct CreateGroupViewModelTests {
    @Test func validatesTheName() async {
        let harness = VMHarness()
        let model = CreateGroupViewModel(session: harness.makeSession())
        #expect(!model.canSubmit)
        model.name = "   "
        #expect(!model.canSubmit)
        model.name = String(repeating: "x", count: 61)
        #expect(model.canSubmit)
        #expect(await model.create() == nil)
        #expect(model.nameError == "Le nom du groupe doit contenir entre 1 et 60 caractères.")
        #expect(harness.faults.calls(.createGroup) == 0)
        model.name = "Vacances 2027"
        #expect(model.nameError == nil)
    }

    @Test func createsTheGroupAsAdmin() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = CreateGroupViewModel(session: session)
        model.name = "  Vacances 2027 "
        let revision = session.feed.membershipsRevision
        let group = try #require(await model.create())
        #expect(group.group.name == "Vacances 2027")
        #expect(group.myRole == .admin)
        #expect(model.createdGroup == group)
        #expect(session.feed.membershipsRevision == revision + 1)
        #expect(try await harness.services.groups.myGroups().count == 3)
    }

    @Test func serverErrorsAreShown() async {
        let harness = VMHarness()
        let model = CreateGroupViewModel(session: harness.makeSession())
        model.name = "Vacances"
        harness.faults.fail(.createGroup, with: AppError.network)
        #expect(await model.create() == nil)
        #expect(model.errorMessage == AppError.network.messageFR)
        harness.faults.fail(.createGroup, with: AppError.invalidName)
        #expect(await model.create() == nil)
        #expect(model.nameError == AppError.invalidName.messageFR)
    }
}

@MainActor
@Suite struct JoinGroupViewModelTests {
    typealias F = VMFixtures

    @Test(arguments: [
        ("", ""),
        ("abcd", "ABCD"),
        ("abcde", "ABCD-E"),
        ("lylas234", "LYLA-S234"),
        (" ly-las 234 xyz", "LYLA-S234"),
        ("LYLA-", "LYLA"),
        ("straße", "STRA-SSE"),
        ("é!?", ""),
    ])
    func formatsTheCodeLive(input: String, expected: String) {
        #expect(JoinGroupViewModel.format(input) == expected)
    }

    @Test func codeFieldIsFormatted() {
        let harness = VMHarness(.emptyGroups)
        let model = JoinGroupViewModel(session: harness.makeSession())
        model.code = "lylas23"
        #expect(model.code == "LYLA-S23")
        #expect(!model.isCodeComplete)
        #expect(!model.canSubmit)
        model.code = "lylas2345"
        #expect(model.code == "LYLA-S234")
        #expect(model.isCodeComplete)
        #expect(model.canSubmit)
    }

    @Test func joinsAGroup() async throws {
        let harness = VMHarness(.emptyGroups)
        let session = harness.makeSession()
        let model = JoinGroupViewModel(session: session, code: "lylas234")
        let revision = session.feed.membershipsRevision
        let result = try #require(await model.join())
        #expect(result.groupId == F.lilas)
        #expect(!result.alreadyMember)
        #expect(model.resultMessage == "Tu as rejoint «\u{00A0}Coloc' rue des Lilas\u{00A0}».")
        #expect(session.feed.membershipsRevision == revision + 1)
        #expect(try await harness.services.groups.myGroups().map(\.id) == [F.lilas])
    }

    @Test func alreadyMemberIsASuccess() async throws {
        let harness = VMHarness()
        let model = JoinGroupViewModel(session: harness.makeSession(), code: "LYLA-S234")
        let result = try #require(await model.join())
        #expect(result.alreadyMember)
        #expect(model.resultMessage == "Tu fais déjà partie de «\u{00A0}Coloc' rue des Lilas\u{00A0}».")
        #expect(model.error == nil)
    }

    @Test func invalidCodes() async {
        let harness = VMHarness(.emptyGroups)
        let model = JoinGroupViewModel(session: harness.makeSession())

        model.code = "ABC"
        #expect(await model.join() == nil)
        #expect(model.errorMessage == JoinGroupViewModel.incompleteCodeMessage)

        // 0 is not in the alphabet: refused locally.
        model.code = "ABCD-EFG0"
        #expect(await model.join() == nil)
        #expect(model.errorMessage == "Code d’invitation invalide.")
        #expect(harness.faults.calls(.join) == 0)

        // Well-formed but unknown: refused by the server.
        model.code = "ABCD-EFGH"
        #expect(await model.join() == nil)
        #expect(model.errorMessage == "Code d’invitation invalide.")
        #expect(harness.faults.calls(.join) == 1)
        #expect(model.result == nil)
    }

    @Test func rateLimited() async {
        let harness = VMHarness(.emptyGroups)
        let model = JoinGroupViewModel(session: harness.makeSession(), code: "ABCD-EFGH")
        for _ in 0..<InMemoryBackend.maxFailedJoinsPerHour {
            _ = await model.join()
        }
        model.code = "LYLA-S234"
        #expect(await model.join() == nil)
        #expect(model.errorMessage == "Trop de tentatives. Réessaie dans une heure.")
    }
}
