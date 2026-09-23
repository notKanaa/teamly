import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

@Suite struct MockEnvironmentTests {
    let now = DemoDataTests.parisDate(2026, 9, 23, 10)

    @Test func signedOutHasDemoDataAndNoSession() async throws {
        let now = now
        let environment = MockEnvironment.make(scenario: .signedOut, now: { now })
        #expect(environment.scenario == .signedOut)
        #expect(environment.signedInUser == nil)
        let services = environment.services
        #expect(await services.auth.currentUser() == nil)
        var states = services.auth.authStates().makeAsyncIterator()
        #expect(await states.next() == .signedOut)
        await #expect(throws: AppError.notAuthenticated) { try await services.groups.myGroups() }

        try await services.auth.signIn(email: DemoData.camille.email, password: DemoData.password)
        #expect(await states.next() == .signedIn(AuthUser(id: DemoData.camille.id, email: DemoData.camille.email)))
        #expect(try await services.groups.myGroups().count == 2)
    }

    @Test func populatedIsSignedInAsCamille() async throws {
        let environment = MockEnvironment.make(scenario: .populated)
        #expect(environment.signedInUser == DemoData.camille)
        let services = environment.services
        #expect(await services.auth.currentUser()?.id == DemoData.camille.id)
        var states = services.auth.authStates().makeAsyncIterator()
        #expect(await states.next()?.user?.id == DemoData.camille.id)
        let groups = try await services.groups.myGroups()
        #expect(groups.map(\.id) == [DemoData.lilasGroupId, DemoData.sportGroupId])
        #expect(try await services.profiles.myProfile().displayName == "Camille Martin")
    }

    @Test func emptyGroupsIsSignedInWithoutGroups() async throws {
        let environment = MockEnvironment.make(scenario: .emptyGroups)
        #expect(environment.signedInUser == DemoData.newcomer)
        let services = environment.services
        #expect(await services.auth.currentUser()?.id == DemoData.newcomer.id)
        #expect(try await services.groups.myGroups().isEmpty)
        #expect(try await services.tasks.myTasks(includeDone: true).isEmpty)

        let code = try #require(InviteCode("lylas-234"))
        let joined = try await services.groups.join(code: code)
        #expect(joined == JoinResult(groupId: DemoData.lilasGroupId, groupName: DemoData.lilasGroupName, alreadyMember: false))
        #expect(try await services.groups.myGroups().map(\.myRole) == [.member])
    }

    @Test func environmentsAreIndependent() async throws {
        let first = MockEnvironment.make(scenario: .populated)
        let second = MockEnvironment.make(scenario: .populated)
        _ = try await first.services.groups.createGroup(name: "Nouveau groupe")
        #expect(try await first.services.groups.myGroups().count == 3)
        #expect(try await second.services.groups.myGroups().count == 2)
    }

    @Test func otherDevicesShareTheBackend() async throws {
        let environment = MockEnvironment.make(scenario: .populated)
        let lucas = environment.backend.services(for: DemoData.lucas.id)
        let task = try await lucas.tasks.create(
            groupId: DemoData.sportGroupId,
            draft: TaskDraft(title: "Acheter des ballons", assigneeIds: [DemoData.camille.id])
        )
        let mine = try await environment.services.tasks.myTasks(includeDone: false)
        #expect(mine.contains { $0.id == task.id && $0.groupName == DemoData.sportGroupName })
    }

    @Test(arguments: [
        (["App", "-uiTestMockBackend", "-mockScenario", "populated"], MockScenario.populated),
        (["App", "-mockScenario", "emptyGroups"], .emptyGroups),
        (["App", "-mockScenario", "signedOut"], .signedOut),
    ])
    func parsesLaunchArguments(arguments: [String], expected: MockScenario) {
        #expect(MockEnvironment.scenario(fromLaunchArguments: arguments) == expected)
    }

    @Test func ignoresMissingOrUnknownScenario() {
        #expect(MockEnvironment.scenario(fromLaunchArguments: ["App"]) == nil)
        #expect(MockEnvironment.scenario(fromLaunchArguments: ["App", "-mockScenario"]) == nil)
        #expect(MockEnvironment.scenario(fromLaunchArguments: ["App", "-mockScenario", "inconnu"]) == nil)
    }

    @Test func artificialLatencyStillAnswers() async throws {
        let environment = MockEnvironment.make(scenario: .populated, latency: .milliseconds(5))
        let clock = ContinuousClock()
        let start = clock.now
        let groups = try await environment.services.groups.myGroups()
        #expect(groups.count == 2)
        #expect(clock.now - start >= .milliseconds(4)) // lower bound only: never flaky
    }
}
