import Foundation
import Testing
@testable import TeamTasksCore

@MainActor
@Suite struct DeepLinkTests {
    let groupId = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    let taskId = UUID(uuidString: "B0000000-0000-4000-8000-000000000003")!

    @Test func parsesTaskLinks() throws {
        let url = try #require(URL(string: "equipe://task/\(groupId.uuidString)/\(taskId.uuidString)"))
        #expect(DeepLink(url: url) == .task(groupId: groupId, taskId: taskId))

        // Case-insensitive scheme and host, lowercase UUIDs, trailing slash.
        let loose = try #require(URL(string: "EQUIPE://Task/\(groupId.uuidString.lowercased())/\(taskId.uuidString.lowercased())/"))
        #expect(DeepLink(url: loose) == .task(groupId: groupId, taskId: taskId))
    }

    @Test func parsesGroupAndMyTasksLinks() throws {
        #expect(DeepLink(url: try #require(URL(string: "equipe://group/\(groupId.uuidString)"))) == .group(groupId))
        #expect(DeepLink(url: try #require(URL(string: "equipe://mytasks"))) == .myTasks)
    }

    @Test func rejectsForeignOrMalformedLinks() throws {
        let g = groupId.uuidString
        let t = taskId.uuidString
        let rejected = [
            "https://task/\(g)/\(t)",
            "equipe://task/\(g)",
            "equipe://task/\(g)/\(t)/extra",
            "equipe://task/not-a-uuid/\(t)",
            "equipe://other/\(g)/\(t)",
            "equipe://group/\(g)/\(t)",
            "equipe://mytasks/\(g)",
        ]
        for string in rejected {
            let url = try #require(URL(string: string))
            #expect(DeepLink(url: url) == nil, "\(string)")
        }
    }

    @Test func urlRoundTrips() {
        for link in [DeepLink.task(groupId: groupId, taskId: taskId), .group(groupId), .myTasks] {
            #expect(DeepLink(url: link.url) == link)
        }
        #expect(DeepLink.task(groupId: groupId, taskId: taskId).url.absoluteString
            == "equipe://task/\(groupId.uuidString)/\(taskId.uuidString)")
    }

    @Test func notificationUserInfo() {
        let both: [AnyHashable: Any] = ["taskId": taskId.uuidString, "groupId": groupId.uuidString, "other": 3]
        #expect(DeepLink(notificationUserInfo: both) == .task(groupId: groupId, taskId: taskId))
        #expect(DeepLink(notificationUserInfo: ["groupId": groupId.uuidString]) == .group(groupId))
        #expect(DeepLink(notificationUserInfo: [:]) == .myTasks)
        #expect(DeepLink(notificationUserInfo: ["taskId": taskId.uuidString]) == .myTasks)
        #expect(DeepLink(notificationUserInfo: ["taskId": "x", "groupId": "y"]) == .myTasks)
        #expect(DeepLink(notificationUserInfo: ["taskId": 12, "groupId": groupId.uuidString]) == .group(groupId))
    }
}

@MainActor
@Suite struct RouterTests {
    let groupId = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    let otherGroupId = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!
    let taskId = UUID(uuidString: "B0000000-0000-4000-8000-000000000003")!

    @Test func startsOnGroupsTabWithEmptyPaths() {
        let router = Router()
        #expect(router.selectedTab == .groups)
        #expect(router.groupsPath.isEmpty)
        #expect(router.myTasksPath.isEmpty)
        #expect(!router.isActive)
        #expect(router.pendingDeepLink == nil)
        #expect(AppTab.allCases.map(\.title) == ["Groupes", "Mes tâches", "Réglages"])
    }

    @Test func deepLinkWaitsForASession() {
        let router = Router()
        router.selectedTab = .settings
        router.open(.task(groupId: groupId, taskId: taskId))
        #expect(router.pendingDeepLink == .task(groupId: groupId, taskId: taskId))
        #expect(router.selectedTab == .settings)
        #expect(router.groupsPath.isEmpty)

        router.activate()
        #expect(router.isActive)
        #expect(router.pendingDeepLink == nil)
        #expect(router.selectedTab == .groups)
        #expect(router.groupsPath == [.group(groupId), .task(groupId: groupId, taskId: taskId)])
    }

    @Test func activeRouterAppliesLinksImmediately() throws {
        let router = Router()
        router.activate()
        router.selectedTab = .myTasks

        #expect(router.open(url: try #require(URL(string: "equipe://task/\(groupId.uuidString)/\(taskId.uuidString)"))))
        #expect(router.selectedTab == .groups)
        #expect(router.groupsPath == [.group(groupId), .task(groupId: groupId, taskId: taskId)])

        #expect(!router.open(url: try #require(URL(string: "https://example.com"))))
        #expect(router.groupsPath.count == 2)

        router.openNotification(userInfo: ["groupId": otherGroupId.uuidString])
        #expect(router.groupsPath == [.group(otherGroupId)])

        router.openNotification(userInfo: [:])
        #expect(router.selectedTab == .myTasks)
        #expect(router.myTasksPath.isEmpty)
    }

    @Test func navigationHelpers() {
        let router = Router()
        router.showMembers(groupId: groupId)
        #expect(router.groupsPath == [.group(groupId), .members(groupId: groupId)])
        router.showGroup(otherGroupId)
        #expect(router.groupsPath == [.group(otherGroupId)])
        router.myTasksPath = [.task(groupId: groupId, taskId: taskId)]
        router.selectedTab = .myTasks
        router.popToRoot()
        #expect(router.myTasksPath.isEmpty)
        #expect(router.groupsPath == [.group(otherGroupId)])
        router.popToRoot(of: .groups)
        #expect(router.groupsPath.isEmpty)
    }

    @Test func removesRoutesOfAGoneGroupOrTask() {
        let router = Router()
        router.groupsPath = [.group(otherGroupId), .group(groupId), .task(groupId: groupId, taskId: taskId), .members(groupId: groupId)]
        router.myTasksPath = [.task(groupId: groupId, taskId: taskId)]
        router.removeRoutes(forGroup: groupId)
        #expect(router.groupsPath == [.group(otherGroupId)])
        #expect(router.myTasksPath.isEmpty)

        router.groupsPath = [.group(groupId), .task(groupId: groupId, taskId: taskId), .members(groupId: groupId)]
        router.removeRoutes(forTask: taskId)
        #expect(router.groupsPath == [.group(groupId)])
    }

    @Test func deactivateResetsNavigation() {
        let router = Router()
        router.activate()
        router.showTask(groupId: groupId, taskId: taskId)
        router.myTasksPath = [.task(groupId: groupId, taskId: taskId)]
        router.selectedTab = .settings
        router.deactivate()
        #expect(!router.isActive)
        #expect(router.selectedTab == .groups)
        #expect(router.groupsPath.isEmpty)
        #expect(router.myTasksPath.isEmpty)

        router.open(.group(groupId))
        #expect(router.pendingDeepLink == .group(groupId))
    }

    @Test func routesKnowTheirGroup() {
        #expect(AppRoute.group(groupId).groupId == groupId)
        #expect(AppRoute.task(groupId: groupId, taskId: taskId).groupId == groupId)
        #expect(AppRoute.members(groupId: groupId).groupId == groupId)
    }
}

@MainActor
@Suite struct ErrorStateTests {
    @Test func cancellationsAreNeverShown() {
        #expect(ErrorState(from: CancellationError()) == nil)
        #expect(ErrorState(from: AppError.wrap(CancellationError())) == nil)
        #expect(ErrorState(from: URLError(.cancelled)) == nil)
        #expect(ErrorState.isCancellation(CancellationError()))
        #expect(!ErrorState.isCancellation(AppError.network))
    }

    @Test func messagesComeFromAppError() throws {
        let state = try #require(ErrorState(from: AppError.lastAdmin))
        #expect(state.message == AppError.lastAdmin.messageFR)
        #expect(state.error == .lastAdmin)

        struct Opaque: Error {}
        let wrapped = try #require(ErrorState(from: Opaque()))
        #expect(wrapped.message.hasPrefix("Une erreur est survenue."))

        let custom = ErrorState(message: "Texte", error: nil)
        #expect(custom.message == "Texte")
        #expect(custom != ErrorState(message: "Texte", error: nil))
    }

    @Test func presentingProtocolHelpers() {
        let harness = VMHarness(.signedOut)
        let model = LoginViewModel(services: harness.services)
        #expect(!model.isShowingError)
        model.present(AppError.network)
        #expect(model.isShowingError)
        #expect(model.errorMessage == AppError.network.messageFR)
        #expect(model.present(CancellationError()) == nil)
        #expect(model.errorMessage == AppError.network.messageFR)

        // Views bind alerts with `$model.isShowingError`.
        let keyPath: ReferenceWritableKeyPath<LoginViewModel, Bool> = \.isShowingError
        model[keyPath: keyPath] = false
        #expect(model.error == nil)
        model.present(message: "Oups")
        model.dismissError()
        #expect(model.errorMessage == nil)
    }

    @Test func loadStateHelpers() {
        #expect(LoadState.loading.isLoading)
        #expect(LoadState.loaded.isLoaded)
        #expect(LoadState.failed("x").failureMessage == "x")
        #expect(LoadState.idle.failureMessage == nil)
    }

    @Test func presentationLabels() {
        #expect(TaskStatus.allCases.map(\.label) == ["À faire", "En cours", "Terminée"])
        #expect(TaskStatus.todo.next == .inProgress)
        #expect(TaskStatus.done.next == .todo)
        #expect(TaskPriority.pickerOrder.map(\.label) == ["Haute", "Moyenne", "Basse"])
        #expect(MemberRole.admin.label == "Admin")
        #expect(MemberRole.member.label == "Membre")
    }

    @Test func memberDirectoryNames() {
        let me = UUID()
        let lucas = UUID()
        let ines = UUID()
        let group = UUID()
        let date = VMFixtures.now
        let directory = MemberDirectory(
            members: [
                Membership(groupId: group, user: UserProfile(id: me, displayName: "Camille Martin"), role: .admin, joinedAt: date),
                Membership(groupId: group, user: UserProfile(id: lucas, displayName: "Lucas Bernard"), role: .member, joinedAt: date),
                Membership(groupId: group, user: UserProfile(id: ines, displayName: "Inès Dubois"), role: .member, joinedAt: date),
            ],
            currentUserId: me
        )
        #expect(directory.myRole == .admin)
        #expect(directory.names(of: [lucas, me, ines]) == ["Toi", "Inès Dubois", "Lucas Bernard"])
        #expect(directory.assigneesText([]) == "Non assignée")
        #expect(directory.assigneesText([lucas]) == "Lucas Bernard")
        #expect(directory.name(of: UUID()) == "Ancien membre")
        #expect(directory.name(of: nil) == "Ancien membre")
    }

    @Test func filterChips() {
        var filter = TaskFilter.all
        #expect(TaskFilterChip.chips(for: filter).map(\.label)
            == ["Toutes", "À faire", "En cours", "Terminées", "Assignées à moi", "En retard"])
        #expect(TaskFilterChip.chips(for: filter).filter(\.isSelected).map(\.kind) == [.status(.all)])

        filter = TaskFilterChip.toggling(.status(.todo), in: filter)
        #expect(filter.status == .todo)
        filter = TaskFilterChip.toggling(.status(.todo), in: filter)
        #expect(filter.status == .all)
        filter = TaskFilterChip.toggling(.status(.all), in: filter)
        #expect(filter.status == .all)
        filter = TaskFilterChip.toggling(.assignedToMe, in: filter)
        filter = TaskFilterChip.toggling(.overdue, in: filter)
        #expect(filter.onlyAssignedToMe && filter.onlyOverdue)
        #expect(TaskFilterChip.chips(for: filter).filter(\.isSelected).map(\.kind) == [.status(.all), .assignedToMe, .overdue])
    }

    @Test func dateTexts() {
        let now = VMFixtures.now
        let calendar = VMFixtures.calendar
        #expect(DateText.relative(VMFixtures.date(2026, 9, 24, 20), now: now, calendar: calendar) == "Aujourd’hui à 20:00")
        #expect(DateText.relative(VMFixtures.date(2026, 9, 25, 18), now: now, calendar: calendar) == "Demain à 18:00")
        #expect(DateText.relativeLowercase(VMFixtures.date(2026, 9, 23, 9, 30), now: now, calendar: calendar) == "hier à 09:30")
        #expect(DateText.relative(VMFixtures.date(2026, 9, 28, 18), now: now, calendar: calendar) == "Lundi à 18:00")
        #expect(DateText.relative(VMFixtures.date(2026, 10, 1, 18), now: now, calendar: calendar) == "Jeudi 1er octobre à 18:00")
        #expect(DateText.relative(VMFixtures.date(2026, 9, 20, 18), now: now, calendar: calendar) == "Dimanche 20 septembre à 18:00")
        #expect(DateText.relativeInSentence(VMFixtures.date(2026, 9, 23, 9, 30), now: now, calendar: calendar) == "hier à 09:30")
        #expect(DateText.relativeInSentence(VMFixtures.date(2026, 9, 14, 10), now: now, calendar: calendar) == "le lundi 14 septembre à 10:00")
    }
}
