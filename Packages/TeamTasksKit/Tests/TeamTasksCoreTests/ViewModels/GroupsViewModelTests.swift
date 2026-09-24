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
        #expect(model.resultMessage == "Vous avez rejoint «\u{00A0}Coloc' rue des Lilas\u{00A0}».")
        #expect(session.feed.membershipsRevision == revision + 1)
        #expect(try await harness.services.groups.myGroups().map(\.id) == [F.lilas])
    }

    @Test func alreadyMemberIsASuccess() async throws {
        let harness = VMHarness()
        let model = JoinGroupViewModel(session: harness.makeSession(), code: "LYLA-S234")
        let result = try #require(await model.join())
        #expect(result.alreadyMember)
        #expect(model.resultMessage == "Vous faites déjà partie de «\u{00A0}Coloc' rue des Lilas\u{00A0}».")
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
        #expect(model.errorMessage == "Trop de tentatives. Réessayez dans une heure.")
    }
}
