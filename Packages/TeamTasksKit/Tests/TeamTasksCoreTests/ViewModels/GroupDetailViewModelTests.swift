import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

@MainActor
@Suite struct GroupDetailViewModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    @Test func loadsTasksMembersAndRole() async {
        let harness = VMHarness()
        let model = GroupDetailViewModel(session: harness.makeSession(), groupId: F.lilas)
        #expect(model.title == "Groupe")
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.title == "Coloc' rue des Lilas")
        #expect(model.myRole == .admin)
        #expect(model.members.count == 3)

        let rows = model.rows
        #expect(rows.map(\.id) == [T.payerLoyer, T.sortirPoubelles, T.faireCourses, T.nettoyerCuisine, T.reparerFuite])
        #expect(rows.map(\.assigneesText) == ["Inès Dubois", "Toi", "Toi, Lucas Bernard", "Toi", "Non assignée"])
        #expect(rows.map(\.dueText) == ["Hier à 18:00", "Aujourd’hui à 20:00", "Demain à 18:00", nil, nil])
        #expect(rows.map(\.isOverdue) == [true, false, false, false, false])
        #expect(rows.allSatisfy { $0.canEdit && $0.canChangeStatus && $0.canDelete && !$0.isNew && $0.groupName == nil })
        #expect(model.canCreateTask && model.canRename && model.canDeleteGroup)
        #expect(model.canManageMembers && model.canSeeInviteCode)
        #expect(model.memberName(F.ines.id) == "Inès Dubois")
        #expect(model.memberName(UUID()) == "Ancien membre")
        let courses = model.tasks.first { $0.id == T.faireCourses }!
        #expect(model.assigneeNames(for: courses) == ["Toi", "Lucas Bernard"])
        #expect(!model.isEmpty)
    }

    @Test func memberPermissions() async throws {
        let harness = VMHarness()
        let summary = try #require(try await harness.services.groups.myGroups().first { $0.id == F.sport })
        let model = GroupDetailViewModel(session: harness.makeSession(), groupId: F.sport, group: summary)
        #expect(model.title == "Projet Asso Sport")
        #expect(model.myRole == .member)
        await model.load()
        #expect(model.myRole == .member)
        #expect(model.canCreateTask)
        #expect(!model.canRename && !model.canDeleteGroup && !model.canManageMembers && !model.canSeeInviteCode)

        let rows = model.rows
        #expect(rows.map(\.id) == [T.reserverGymnase, T.creerAffiche])
        // Assignee of « Réserver le gymnase » (created by Lucas): status only.
        #expect(rows[0].canChangeStatus && !rows[0].canEdit && !rows[0].canDelete)
        // « Créer l'affiche » is neither mine nor assigned to me.
        #expect(!rows[1].canChangeStatus && !rows[1].canEdit && !rows[1].canDelete)

        #expect(await !model.setStatus(.done, for: rows[1].task))
        #expect(model.errorMessage == AppError.forbidden.messageFR)
        #expect(await !model.delete(rows[0].task))
        #expect(await !model.rename(to: "Autre nom"))
        #expect(await !model.deleteGroup())
        #expect(harness.faults.calls(.setStatus) == 0)
        #expect(harness.faults.calls(.deleteTask) == 0)
        #expect(harness.faults.calls(.rename) == 0)
        #expect(harness.faults.calls(.deleteGroup) == 0)

        #expect(await model.setStatus(.inProgress, for: rows[0].task))
        #expect(model.tasks.first { $0.id == T.reserverGymnase }?.status == .inProgress)
    }

    @Test func filterChipsAndSort() async {
        let harness = VMHarness()
        let model = GroupDetailViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        #expect(!model.hasActiveFilter)
        #expect(model.filterChips.count == 6)

        model.toggleFilterChip(.status(.todo))
        #expect(model.hasActiveFilter)
        #expect(model.rows.map(\.id) == [T.payerLoyer, T.sortirPoubelles, T.reparerFuite])
        model.toggleFilterChip(.assignedToMe)
        #expect(model.rows.map(\.id) == [T.sortirPoubelles])
        model.toggleFilterChip(.overdue)
        #expect(model.rows.isEmpty)
        #expect(model.emptyRowsMessage == GroupDetailViewModel.noMatchMessage)
        #expect(model.filterChips.filter(\.isSelected).map(\.kind) == [.status(.todo), .assignedToMe, .overdue])

        model.resetFilter()
        #expect(model.rows.count == 5)
        model.toggleFilterChip(.status(.done))
        #expect(model.rows.map(\.id) == [T.nettoyerCuisine])
        model.resetFilter()

        model.sort = .recentlyCreated
        #expect(model.rows.map(\.id) == [T.faireCourses, T.sortirPoubelles, T.nettoyerCuisine, T.reparerFuite, T.payerLoyer])
    }

    @Test func emptyGroup() async throws {
        let harness = VMHarness()
        let created = try await harness.services.groups.createGroup(name: "Vide")
        let model = GroupDetailViewModel(session: harness.makeSession(), groupId: created.id)
        await model.load()
        #expect(model.isEmpty)
        #expect(model.rows.isEmpty)
        #expect(model.emptyRowsMessage == GroupDetailViewModel.emptyMessage)
    }

    @Test func includeOldDoneReloads() async throws {
        let harness = VMHarness()
        // « Réparer la fuite » was completed 40 days ago.
        harness.clock.set(F.now.addingTimeInterval(-40 * 86_400))
        _ = try await harness.device(F.camille).tasks.setStatus(taskId: T.reparerFuite, status: .done)
        harness.clock.set(F.now.addingTimeInterval(60))

        let model = GroupDetailViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        #expect(model.tasks.count == 4)
        #expect(!model.tasks.contains { $0.id == T.reparerFuite })

        let key = model.refreshKey
        model.includeOldDone = true
        #expect(model.refreshKey != key)
        #expect(model.needsRefresh)
        await model.load()
        #expect(harness.faults.calls(.tasks) == 2)
        #expect(model.tasks.contains { $0.id == T.reparerFuite })
    }

    @Test func reloadsWhenTheGroupChanges() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = GroupDetailViewModel(session: session, groupId: F.lilas)
        await model.load()
        await model.load()
        #expect(harness.faults.calls(.tasks) == 1)

        _ = try await harness.device(F.lucas).tasks.create(groupId: F.lilas, draft: TaskDraft(title: "Acheter du pain"))
        session.feed.bump(groupId: F.lilas)
        await model.load()
        #expect(harness.faults.calls(.tasks) == 2)
        #expect(model.tasks.contains { $0.title == "Acheter du pain" })

        session.feed.bump(groupId: F.sport)
        await model.load()
        #expect(harness.faults.calls(.tasks) == 2)

        session.feed.bumpAll()
        await model.load()
        #expect(harness.faults.calls(.tasks) == 3)
    }

    @Test func changesStatusAndBumpsTheFeed() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = GroupDetailViewModel(session: session, groupId: F.lilas)
        await model.load()
        let courses = try #require(model.tasks.first { $0.id == T.faireCourses })
        let groupRevision = session.feed.groupRevision(F.lilas)
        let myTasksRevision = session.feed.myTasksRevision

        #expect(await model.setStatus(.done, for: courses))
        #expect(model.tasks.first { $0.id == courses.id }?.status == .done)
        #expect(session.feed.groupRevision(F.lilas) == groupRevision + 1)
        #expect(session.feed.myTasksRevision == myTasksRevision + 1)
        #expect(model.busyTaskIds.isEmpty)

        // Deleted elsewhere: the task leaves the list and the message says so.
        try await harness.device(F.lucas).tasks.delete(taskId: courses.id)
        #expect(await !model.setStatus(.todo, for: courses))
        #expect(model.errorMessage == AppError.notFound.messageFR)
        #expect(!model.tasks.contains { $0.id == courses.id })
    }

    @Test func deletesATask() async throws {
        let harness = VMHarness()
        let model = GroupDetailViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        let fuite = try #require(model.tasks.first { $0.id == T.reparerFuite })
        #expect(await model.delete(fuite))
        #expect(!model.tasks.contains { $0.id == fuite.id })
        #expect(try await harness.services.tasks.tasks(groupId: F.lilas, includeOldDone: true).count == 4)

        harness.faults.fail(.deleteTask, with: AppError.network)
        let loyer = try #require(model.tasks.first { $0.id == T.payerLoyer })
        #expect(await !model.delete(loyer))
        #expect(model.errorMessage == AppError.network.messageFR)
        #expect(model.tasks.contains { $0.id == loyer.id })
    }

    @Test func adminRenamesAndDeletesTheGroup() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = GroupDetailViewModel(session: session, groupId: F.lilas)
        await model.load()

        #expect(await !model.rename(to: "   "))
        #expect(model.errorMessage == AppError.invalidName.messageFR)
        #expect(harness.faults.calls(.rename) == 0)

        let memberships = session.feed.membershipsRevision
        #expect(await model.rename(to: " Coloc' des Lilas "))
        #expect(model.title == "Coloc' des Lilas")
        #expect(session.feed.membershipsRevision == memberships + 1)
        #expect(model.deleteGroupConfirmationMessage.contains("«\u{00A0}Coloc' des Lilas\u{00A0}»"))

        #expect(await model.deleteGroup())
        #expect(model.isGone)
        #expect(try await harness.services.groups.myGroups().map(\.id) == [F.sport])

        // A gone screen no longer loads.
        let calls = harness.faults.calls(.tasks)
        await model.reload()
        await model.load()
        #expect(harness.faults.calls(.tasks) == calls)
    }

    @Test func removedFromTheGroupMeansGone() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = GroupDetailViewModel(session: session, groupId: F.sport)
        await model.load()
        #expect(!model.isGone)
        try await harness.device(F.lucas).groups.removeMember(groupId: F.sport, userId: F.camille.id)
        session.feed.bump(groupId: F.sport)
        await model.load()
        #expect(model.isGone)
        #expect(model.error == nil)
    }

    @Test func firstLoadFailure() async {
        let harness = VMHarness()
        let model = GroupDetailViewModel(session: harness.makeSession(), groupId: F.lilas)
        harness.faults.fail(.members, with: AppError.network)
        await model.load()
        #expect(model.loadState == .failed(AppError.network.messageFR))
        await model.reload()
        #expect(model.loadState == .loaded)
        #expect(model.rows.count == 5)
    }

    @Test func appliesTasksFromOtherScreens() async throws {
        let harness = VMHarness()
        let model = GroupDetailViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        var poubelles = try #require(model.tasks.first { $0.id == T.sortirPoubelles })
        poubelles.title = "Sortir les poubelles jaunes"
        model.apply(poubelles)
        #expect(model.tasks.first { $0.id == T.sortirPoubelles }?.title == "Sortir les poubelles jaunes")
        var foreign = poubelles
        foreign.groupId = F.sport
        foreign.id = UUID()
        model.apply(foreign)
        #expect(model.tasks.count == 5)
    }
}

@MainActor
@Suite struct MembersViewModelTests {
    typealias F = VMFixtures

    @Test func adminSeesMembersAndInviteCode() async {
        let harness = VMHarness()
        let model = MembersViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.groupName == "Coloc' rue des Lilas")
        #expect(model.members.map(\.user.displayName) == ["Camille Martin", "Inès Dubois", "Lucas Bernard"])
        #expect(model.isAdmin && model.canManageMembers && model.canSeeInviteCode)
        #expect(model.inviteCodeText == "LYLA-S234")
        #expect(model.shareText == "Rejoins mon groupe «\u{00A0}Coloc' rue des Lilas\u{00A0}» sur Équipe avec le code LYLA-S234")
        #expect(model.displayName(of: model.members[0]) == "Camille Martin (toi)")
        #expect(model.displayName(of: model.members[1]) == "Inès Dubois")
        #expect(!model.canRemove(model.members[0]))
        #expect(model.canRemove(model.members[1]))
        // The last admin cannot demote themselves.
        #expect(!model.canChangeRole(of: model.members[0]))
        #expect(model.canChangeRole(of: model.members[1]))
        #expect(model.roleActionTitle(for: model.members[1]) == "Nommer admin")
        #expect(model.roleActionTitle(for: model.members[0]) == "Retirer le rôle d’admin")
        #expect(model.isLastAdmin)
        #expect(!model.isLastMember)
        #expect(!model.canLeave)
        #expect(model.leaveConfirmationMessage == AppError.lastAdmin.messageFR)
    }

    @Test func regeneratesTheInviteCode() async throws {
        let harness = VMHarness()
        let model = MembersViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        let old = try #require(model.inviteCode)
        #expect(await model.regenerateInviteCode())
        let new = try #require(model.inviteCode)
        #expect(new != old)
        #expect(model.shareText?.hasSuffix(new.formatted) == true)
        #expect(try await harness.services.groups.inviteCode(groupId: F.lilas) == new)
    }

    @Test func rolesRemovalAndLeaving() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = MembersViewModel(session: session, groupId: F.lilas)
        await model.load()

        // Leaving as the only admin: the server refuses with the French explanation.
        #expect(await !model.leave())
        #expect(model.errorMessage == AppError.lastAdmin.messageFR)
        #expect(!model.didLeave && !model.isGone)

        let lucas = try #require(model.members.first { $0.user.id == F.lucas.id })
        let memberships = session.feed.membershipsRevision
        #expect(await model.setRole(.admin, for: lucas))
        #expect(model.members.map(\.user.displayName) == ["Camille Martin", "Lucas Bernard", "Inès Dubois"])
        #expect(model.adminCount == 2)
        #expect(!model.isLastAdmin)
        #expect(model.canChangeRole(of: model.members[0]))
        #expect(session.feed.membershipsRevision == memberships + 1)

        let ines = try #require(model.members.first { $0.user.id == F.ines.id })
        #expect(await model.remove(ines))
        #expect(model.members.count == 2)
        #expect(try await harness.services.groups.members(groupId: F.lilas).count == 2)

        // Removing someone already gone: the server answers « not member » and the row disappears.
        harness.faults.fail(.removeMember, with: AppError.notMember)
        let lucasNow = try #require(model.members.first { $0.user.id == F.lucas.id })
        #expect(await !model.remove(lucasNow))
        #expect(model.errorMessage == AppError.notMember.messageFR)
        await model.reload()
        #expect(model.members.count == 2)

        // Camille gives up her admin role: no more invite code.
        let me = try #require(model.members.first { model.isMe($0) })
        #expect(await model.toggleRole(of: me))
        #expect(model.myRole == .member)
        #expect(model.inviteCode == nil)
        #expect(!model.canManageMembers)

        #expect(model.canLeave)
        #expect(await model.leave())
        #expect(model.didLeave && model.isGone)
        #expect(try await harness.services.groups.myGroups().map(\.id) == [F.sport])
    }

    @Test func memberView() async throws {
        let harness = VMHarness()
        let model = MembersViewModel(session: harness.makeSession(), groupId: F.sport)
        await model.load()
        #expect(model.myRole == .member)
        #expect(model.inviteCode == nil)
        #expect(model.shareText == nil)
        #expect(harness.faults.calls(.inviteCode) == 0)
        #expect(model.members.map(\.role) == [.admin, .member])
        #expect(!model.canRemove(model.members[0]))
        #expect(!model.canChangeRole(of: model.members[0]))

        #expect(await !model.regenerateInviteCode())
        #expect(model.errorMessage == AppError.forbidden.messageFR)
        #expect(await !model.remove(model.members[0]))
        #expect(await !model.setRole(.member, for: model.members[0]))
        #expect(harness.faults.calls(.removeMember) == 0)
        #expect(harness.faults.calls(.setRole) == 0)

        #expect(model.leaveConfirmationMessage
            == "Tu ne verras plus «\u{00A0}Projet Asso Sport\u{00A0}» ni ses tâches. Tes assignations dans ce groupe seront retirées.")
        #expect(await model.leave())
        #expect(model.isGone)
    }

    @Test func lastMemberLeavingDeletesTheGroup() async throws {
        let harness = VMHarness()
        let created = try await harness.services.groups.createGroup(name: "Solo")
        let model = MembersViewModel(session: harness.makeSession(), groupId: created.id)
        await model.load()
        #expect(model.isLastMember)
        #expect(!model.isLastAdmin)
        #expect(model.canLeave)
        #expect(model.leaveConfirmationMessage
            == "Il ne reste que toi\u{00A0}: le groupe «\u{00A0}Solo\u{00A0}» et toutes ses tâches seront supprimés.")
        #expect(await model.leave())
        #expect(try await harness.services.groups.myGroups().count == 2)
    }

    @Test func reloadsOnGroupRevisionAndFailsCleanly() async {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = MembersViewModel(session: session, groupId: F.lilas)
        harness.faults.fail(.inviteCode, with: AppError.network)
        await model.load()
        #expect(model.loadState == .failed(AppError.network.messageFR))
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(harness.faults.calls(.members) == 2)
        await model.load()
        #expect(harness.faults.calls(.members) == 2)
        session.feed.bump(groupId: F.lilas)
        await model.load()
        #expect(harness.faults.calls(.members) == 3)
    }

    @Test func removedMemberScreenIsGone() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = MembersViewModel(session: session, groupId: F.sport)
        await model.load()
        try await harness.device(F.lucas).groups.removeMember(groupId: F.sport, userId: F.camille.id)
        await model.reload()
        #expect(model.isGone)
    }
}
