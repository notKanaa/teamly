package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.logic.TaskSort
import io.github.notkanaa.equipe.core.logic.TaskStatusFilter
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID
import io.github.notkanaa.equipe.core.viewmodel.VMFaults.Op
import io.github.notkanaa.equipe.core.viewmodel.VMFixtures as F
import io.github.notkanaa.equipe.mocks.DemoData.TaskIds as T

/** Port of the GroupDetailViewModelTests suite of ViewModels/GroupDetailViewModelTests.swift. */
@OptIn(ExperimentalCoroutinesApi::class)
class GroupDetailViewModelTest {
    @Test
    fun loadsTasksMembersAndRole() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupDetailViewModel(harness.makeSession(), F.lilas, harness.scope)
        assertEquals("Groupe", model.ui.title)
        model.load()
        val state = model.ui
        assertEquals(LoadState.Loaded, state.loadState)
        assertEquals("Coloc' rue des Lilas", state.title)
        assertEquals(MemberRole.ADMIN, state.myRole)
        assertEquals(3, state.members.size)

        val rows = state.rows
        assertEquals(
            listOf(T.payerLoyer, T.sortirPoubelles, T.faireCourses, T.nettoyerCuisine, T.reparerFuite),
            rows.map { it.id },
        )
        assertEquals(
            listOf("Inès Dubois", "Vous", "Vous, Lucas Bernard", "Vous", "Non assignée"),
            rows.map { it.assigneesText },
        )
        assertEquals(listOf("Hier à 18:00", "Aujourd’hui à 20:00", "Demain à 18:00", null, null), rows.map { it.dueText })
        assertEquals(listOf(true, false, false, false, false), rows.map { it.isOverdue })
        assertTrue(rows.all { it.canEdit && it.canChangeStatus && it.canDelete && !it.isNew && it.groupName == null })
        assertTrue(state.canCreateTask && state.canRename && state.canDeleteGroup)
        assertTrue(state.canManageMembers && state.canSeeInviteCode)
        assertEquals("Inès Dubois", state.memberName(F.ines.id))
        assertEquals("Ancien membre", state.memberName(UUID.randomUUID()))
        val courses = state.tasks.first { it.id == T.faireCourses }
        assertEquals(listOf("Vous", "Lucas Bernard"), state.assigneeNames(courses))
        assertFalse(state.isEmpty)
    }

    @Test
    fun memberPermissions() = runTest {
        val harness = VMHarness(backgroundScope)
        val summary = harness.services.groups.myGroups().first { it.id == F.sport }
        val model = GroupDetailViewModel(harness.makeSession(), F.sport, harness.scope, group = summary)
        assertEquals("Projet Asso Sport", model.ui.title)
        assertEquals(MemberRole.MEMBER, model.ui.myRole)
        model.load()
        val state = model.ui
        assertEquals(MemberRole.MEMBER, state.myRole)
        assertTrue(state.canCreateTask)
        assertFalse(state.canRename || state.canDeleteGroup || state.canManageMembers || state.canSeeInviteCode)

        val rows = state.rows
        assertEquals(listOf(T.reserverGymnase, T.creerAffiche), rows.map { it.id })
        // Assignee of « Réserver le gymnase » (created by Lucas): status only.
        assertTrue(rows[0].canChangeStatus && !rows[0].canEdit && !rows[0].canDelete)
        // « Créer l'affiche » is neither mine nor assigned to me.
        assertTrue(!rows[1].canChangeStatus && !rows[1].canEdit && !rows[1].canDelete)

        assertFalse(model.setStatus(TaskStatus.DONE, rows[1].task))
        assertEquals(AppError.Forbidden.messageFR, model.errorMessage)
        assertFalse(model.delete(rows[0].task))
        assertFalse(model.rename("Autre nom"))
        assertFalse(model.deleteGroup())
        assertEquals(0, harness.faults.calls(Op.SET_STATUS))
        assertEquals(0, harness.faults.calls(Op.DELETE_TASK))
        assertEquals(0, harness.faults.calls(Op.RENAME))
        assertEquals(0, harness.faults.calls(Op.DELETE_GROUP))

        assertTrue(model.setStatus(TaskStatus.IN_PROGRESS, rows[0].task))
        assertEquals(TaskStatus.IN_PROGRESS, model.ui.tasks.first { it.id == T.reserverGymnase }.status)
    }

    @Test
    fun filterChipsAndSort() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupDetailViewModel(harness.makeSession(), F.lilas, harness.scope)
        model.load()
        assertFalse(model.ui.hasActiveFilter)
        assertEquals(6, model.ui.filterChips.size)

        model.toggleFilterChip(TaskFilterChip.Kind.Status(TaskStatusFilter.TODO))
        assertTrue(model.ui.hasActiveFilter)
        assertEquals(listOf(T.payerLoyer, T.sortirPoubelles, T.reparerFuite), model.ui.rows.map { it.id })
        model.toggleFilterChip(TaskFilterChip.Kind.AssignedToMe)
        assertEquals(listOf(T.sortirPoubelles), model.ui.rows.map { it.id })
        model.toggleFilterChip(TaskFilterChip.Kind.Overdue)
        assertTrue(model.ui.rows.isEmpty())
        assertEquals(GroupDetailViewModel.NO_MATCH_MESSAGE, model.ui.emptyRowsMessage)
        assertEquals(
            listOf(
                TaskFilterChip.Kind.Status(TaskStatusFilter.TODO),
                TaskFilterChip.Kind.AssignedToMe,
                TaskFilterChip.Kind.Overdue,
            ),
            model.ui.filterChips.filter { it.isSelected }.map { it.kind },
        )

        model.resetFilter()
        assertEquals(5, model.ui.rows.size)
        model.toggleFilterChip(TaskFilterChip.Kind.Status(TaskStatusFilter.DONE))
        assertEquals(listOf(T.nettoyerCuisine), model.ui.rows.map { it.id })
        model.resetFilter()

        model.sort = TaskSort.RECENTLY_CREATED
        assertEquals(
            listOf(T.faireCourses, T.sortirPoubelles, T.nettoyerCuisine, T.reparerFuite, T.payerLoyer),
            model.ui.rows.map { it.id },
        )
    }

    @Test
    fun emptyGroup() = runTest {
        val harness = VMHarness(backgroundScope)
        val created = harness.services.groups.createGroup("Vide")
        val model = GroupDetailViewModel(harness.makeSession(), created.id, harness.scope)
        model.load()
        assertTrue(model.ui.isEmpty)
        assertTrue(model.ui.rows.isEmpty())
        assertEquals(GroupDetailViewModel.EMPTY_MESSAGE, model.ui.emptyRowsMessage)
    }

    @Test
    fun includeOldDoneReloads() = runTest {
        val harness = VMHarness(backgroundScope)
        // « Réparer la fuite » was completed 40 days ago.
        harness.clock.set(F.now.minusSeconds(40L * 86_400))
        harness.device(F.camille).tasks.setStatus(T.reparerFuite, TaskStatus.DONE)
        harness.clock.set(F.now.plusSeconds(60))

        val model = GroupDetailViewModel(harness.makeSession(), F.lilas, harness.scope)
        model.load()
        assertEquals(4, model.ui.tasks.size)
        assertFalse(model.ui.tasks.any { it.id == T.reparerFuite })

        val key = model.refreshKey
        model.includeOldDone = true
        assertNotEquals(key, model.refreshKey)
        assertTrue(model.needsRefresh)
        model.load()
        assertEquals(2, harness.faults.calls(Op.TASKS))
        assertTrue(model.ui.tasks.any { it.id == T.reparerFuite })
    }

    @Test
    fun reloadsWhenTheGroupChanges() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = GroupDetailViewModel(session, F.lilas, harness.scope)
        model.load()
        model.load()
        assertEquals(1, harness.faults.calls(Op.TASKS))

        harness.device(F.lucas).tasks.create(F.lilas, TaskDraft(title = "Acheter du pain"))
        session.feed.bump(F.lilas)
        model.load()
        assertEquals(2, harness.faults.calls(Op.TASKS))
        assertTrue(model.ui.tasks.any { it.title == "Acheter du pain" })

        session.feed.bump(F.sport)
        model.load()
        assertEquals(2, harness.faults.calls(Op.TASKS))

        session.feed.bumpAll()
        model.load()
        assertEquals(3, harness.faults.calls(Op.TASKS))
    }

    @Test
    fun changesStatusAndBumpsTheFeed() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = GroupDetailViewModel(session, F.lilas, harness.scope)
        model.load()
        val courses = model.ui.tasks.first { it.id == T.faireCourses }
        val groupRevision = session.feed.groupRevision(F.lilas)
        val myTasksRevision = session.feed.myTasksRevision.value

        assertTrue(model.setStatus(TaskStatus.DONE, courses))
        assertEquals(TaskStatus.DONE, model.ui.tasks.first { it.id == courses.id }.status)
        assertEquals(groupRevision + 1, session.feed.groupRevision(F.lilas))
        assertEquals(myTasksRevision + 1, session.feed.myTasksRevision.value)
        assertTrue(model.ui.busyTaskIds.isEmpty())

        // Deleted elsewhere: the task leaves the list and the message says so.
        harness.device(F.lucas).tasks.delete(courses.id)
        assertFalse(model.setStatus(TaskStatus.TODO, courses))
        assertEquals(AppError.NotFound.messageFR, model.errorMessage)
        assertFalse(model.ui.tasks.any { it.id == courses.id })
    }

    @Test
    fun deletesATask() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupDetailViewModel(harness.makeSession(), F.lilas, harness.scope)
        model.load()
        val fuite = model.ui.tasks.first { it.id == T.reparerFuite }
        assertTrue(model.delete(fuite))
        assertFalse(model.ui.tasks.any { it.id == fuite.id })
        assertEquals(4, harness.services.tasks.tasks(F.lilas, includeOldDone = true).size)

        harness.faults.fail(Op.DELETE_TASK, AppError.Network)
        val loyer = model.ui.tasks.first { it.id == T.payerLoyer }
        assertFalse(model.delete(loyer))
        assertEquals(AppError.Network.messageFR, model.errorMessage)
        assertTrue(model.ui.tasks.any { it.id == loyer.id })
    }

    @Test
    fun adminRenamesAndDeletesTheGroup() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = GroupDetailViewModel(session, F.lilas, harness.scope)
        model.load()

        assertFalse(model.rename("   "))
        assertEquals(AppError.InvalidName.messageFR, model.errorMessage)
        assertEquals(0, harness.faults.calls(Op.RENAME))

        val memberships = session.feed.membershipsRevision.value
        assertTrue(model.rename(" Coloc' des Lilas "))
        assertEquals("Coloc' des Lilas", model.ui.title)
        assertEquals(memberships + 1, session.feed.membershipsRevision.value)
        assertTrue(model.ui.deleteGroupConfirmationMessage.contains("« Coloc' des Lilas »"))

        assertTrue(model.deleteGroup())
        assertTrue(model.ui.isGone)
        assertEquals(listOf(F.sport), harness.services.groups.myGroups().map { it.id })

        // A gone screen no longer loads.
        val calls = harness.faults.calls(Op.TASKS)
        model.reload()
        model.load()
        assertEquals(calls, harness.faults.calls(Op.TASKS))
    }

    @Test
    fun removedFromTheGroupMeansGone() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = GroupDetailViewModel(session, F.sport, harness.scope)
        model.load()
        assertFalse(model.ui.isGone)
        harness.device(F.lucas).groups.removeMember(F.sport, F.camille.id)
        session.feed.bump(F.sport)
        model.load()
        assertTrue(model.ui.isGone)
        assertNull(model.error)
    }

    @Test
    fun firstLoadFailure() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupDetailViewModel(harness.makeSession(), F.lilas, harness.scope)
        harness.faults.fail(Op.MEMBERS, AppError.Network)
        model.load()
        assertEquals(LoadState.Failed(AppError.Network.messageFR), model.ui.loadState)
        model.reload()
        assertEquals(LoadState.Loaded, model.ui.loadState)
        assertEquals(5, model.ui.rows.size)
    }

    @Test
    fun appliesTasksFromOtherScreens() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupDetailViewModel(harness.makeSession(), F.lilas, harness.scope)
        model.load()
        val poubelles = model.ui.tasks.first { it.id == T.sortirPoubelles }.copy(title = "Sortir les poubelles jaunes")
        model.apply(poubelles)
        assertEquals("Sortir les poubelles jaunes", model.ui.tasks.first { it.id == T.sortirPoubelles }.title)
        val foreign = poubelles.copy(groupId = F.sport, id = UUID.randomUUID())
        model.apply(foreign)
        assertEquals(5, model.ui.tasks.size)
    }

    // region Kotlin additions

    /** `autoRefresh()` is the `.task(id: refreshKey)` of the Swift screens: the toggle and the feed both reload. */
    @Test
    fun autoRefreshFollowsTheGroupRevisionAndTheToggle() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = GroupDetailViewModel(session, F.lilas, harness.scope)
        val observer = backgroundScope.launch { model.autoRefresh() }
        runCurrent()
        assertEquals(1, harness.faults.calls(Op.TASKS))
        session.feed.bump(F.sport)
        runCurrent()
        assertEquals(1, harness.faults.calls(Op.TASKS))
        session.feed.bump(F.lilas)
        runCurrent()
        assertEquals(2, harness.faults.calls(Op.TASKS))
        model.includeOldDone = true
        runCurrent()
        assertEquals(3, harness.faults.calls(Op.TASKS))
        assertFalse(model.needsRefresh)
        observer.cancel()
    }

    /** A service answering `CancellationException` shows nothing: the action rethrows it and resets its flags. */
    @Test
    fun cancelledActionShowsNothing() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupDetailViewModel(harness.makeSession(), F.lilas, harness.scope)
        model.load()
        val courses = model.ui.tasks.first { it.id == T.faireCourses }
        harness.faults.fail(Op.SET_STATUS, kotlin.coroutines.cancellation.CancellationException())
        assertCancels { model.setStatus(TaskStatus.DONE, courses) }
        assertNull(model.error)
        assertTrue(model.ui.busyTaskIds.isEmpty())
        assertEquals(TaskStatus.IN_PROGRESS, model.ui.tasks.first { it.id == courses.id }.status)
    }

    // endregion
}

/** Port of the MembersViewModelTests suite of ViewModels/GroupDetailViewModelTests.swift. */
class MembersViewModelTest {
    @Test
    fun adminSeesMembersAndInviteCode() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = MembersViewModel(harness.makeSession(), F.lilas, harness.scope)
        model.load()
        val state = model.ui
        assertEquals(LoadState.Loaded, state.loadState)
        assertEquals("Coloc' rue des Lilas", state.groupName)
        assertEquals(listOf("Camille Martin", "Inès Dubois", "Lucas Bernard"), state.members.map { it.user.displayName })
        assertTrue(state.isAdmin && state.canManageMembers && state.canSeeInviteCode)
        assertEquals("LYLA-S234", state.inviteCodeText)
        assertEquals("Rejoins mon groupe « Coloc' rue des Lilas » sur Équipe avec le code LYLA-S234", state.shareText)
        assertEquals("Camille Martin (vous)", state.displayName(state.members[0]))
        assertEquals("Inès Dubois", state.displayName(state.members[1]))
        assertFalse(state.canRemove(state.members[0]))
        assertTrue(state.canRemove(state.members[1]))
        // The last admin cannot demote themselves.
        assertFalse(state.canChangeRole(state.members[0]))
        assertTrue(state.canChangeRole(state.members[1]))
        assertEquals("Nommer admin", state.roleActionTitle(state.members[1]))
        assertEquals("Retirer le rôle d’admin", state.roleActionTitle(state.members[0]))
        assertTrue(state.isLastAdmin)
        assertFalse(state.isLastMember)
        assertFalse(state.canLeave)
        assertEquals(AppError.LastAdmin.messageFR, state.leaveConfirmationMessage)
        assertEquals("Membres", state.title)
    }

    @Test
    fun regeneratesTheInviteCode() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = MembersViewModel(harness.makeSession(), F.lilas, harness.scope)
        model.load()
        val old = model.ui.inviteCode!!
        assertTrue(model.regenerateInviteCode())
        val new = model.ui.inviteCode!!
        assertNotEquals(old, new)
        assertTrue(model.ui.shareText!!.endsWith(new.formatted))
        assertEquals(new, harness.services.groups.inviteCode(F.lilas))
    }

    @Test
    fun rolesRemovalAndLeaving() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = MembersViewModel(session, F.lilas, harness.scope)
        model.load()

        // Leaving as the only admin: the server refuses with the French explanation.
        assertFalse(model.leave())
        assertEquals(AppError.LastAdmin.messageFR, model.errorMessage)
        assertFalse(model.ui.didLeave || model.ui.isGone)

        val lucas = model.ui.members.first { it.user.id == F.lucas.id }
        val memberships = session.feed.membershipsRevision.value
        assertTrue(model.setRole(MemberRole.ADMIN, lucas))
        assertEquals(listOf("Camille Martin", "Lucas Bernard", "Inès Dubois"), model.ui.members.map { it.user.displayName })
        assertEquals(2, model.ui.adminCount)
        assertFalse(model.ui.isLastAdmin)
        assertTrue(model.ui.canChangeRole(model.ui.members[0]))
        assertEquals(memberships + 1, session.feed.membershipsRevision.value)

        val ines = model.ui.members.first { it.user.id == F.ines.id }
        assertTrue(model.remove(ines))
        assertEquals(2, model.ui.members.size)
        assertEquals(2, harness.services.groups.members(F.lilas).size)

        // Removing someone already gone: the server answers « not member » and the row disappears.
        harness.faults.fail(Op.REMOVE_MEMBER, AppError.NotMember)
        val lucasNow = model.ui.members.first { it.user.id == F.lucas.id }
        assertFalse(model.remove(lucasNow))
        assertEquals(AppError.NotMember.messageFR, model.errorMessage)
        model.reload()
        assertEquals(2, model.ui.members.size)

        // Camille gives up her admin role: no more invite code.
        val me = model.ui.members.first { model.ui.isMe(it) }
        assertTrue(model.toggleRole(me))
        assertEquals(MemberRole.MEMBER, model.ui.myRole)
        assertNull(model.ui.inviteCode)
        assertFalse(model.ui.canManageMembers)

        assertTrue(model.ui.canLeave)
        assertTrue(model.leave())
        assertTrue(model.ui.didLeave && model.ui.isGone)
        assertEquals(listOf(F.sport), harness.services.groups.myGroups().map { it.id })
    }

    @Test
    fun memberView() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = MembersViewModel(harness.makeSession(), F.sport, harness.scope)
        model.load()
        val state = model.ui
        assertEquals(MemberRole.MEMBER, state.myRole)
        assertNull(state.inviteCode)
        assertNull(state.shareText)
        assertEquals(0, harness.faults.calls(Op.INVITE_CODE))
        assertEquals(listOf(MemberRole.ADMIN, MemberRole.MEMBER), state.members.map { it.role })
        assertFalse(state.canRemove(state.members[0]))
        assertFalse(state.canChangeRole(state.members[0]))

        assertFalse(model.regenerateInviteCode())
        assertEquals(AppError.Forbidden.messageFR, model.errorMessage)
        assertFalse(model.remove(state.members[0]))
        assertFalse(model.setRole(MemberRole.MEMBER, state.members[0]))
        assertEquals(0, harness.faults.calls(Op.REMOVE_MEMBER))
        assertEquals(0, harness.faults.calls(Op.SET_ROLE))

        assertTrue(model.ui.leaveConfirmationMessage.contains("Vous ne verrez plus « Projet Asso Sport »"))
        assertTrue(model.leave())
        assertTrue(model.ui.isGone)
    }

    @Test
    fun lastMemberLeavingDeletesTheGroup() = runTest {
        val harness = VMHarness(backgroundScope)
        val created = harness.services.groups.createGroup("Solo")
        val model = MembersViewModel(harness.makeSession(), created.id, harness.scope)
        model.load()
        assertTrue(model.ui.isLastMember)
        assertFalse(model.ui.isLastAdmin)
        assertTrue(model.ui.canLeave)
        assertEquals(
            "Vous êtes le dernier membre : le groupe « Solo » et toutes ses tâches seront supprimés.",
            model.ui.leaveConfirmationMessage,
        )
        assertTrue(model.leave())
        assertEquals(2, harness.services.groups.myGroups().size)
    }

    @Test
    fun reloadsOnGroupRevisionAndFailsCleanly() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = MembersViewModel(session, F.lilas, harness.scope)
        harness.faults.fail(Op.INVITE_CODE, AppError.Network)
        model.load()
        assertEquals(LoadState.Failed(AppError.Network.messageFR), model.ui.loadState)
        model.load()
        assertEquals(LoadState.Loaded, model.ui.loadState)
        assertEquals(2, harness.faults.calls(Op.MEMBERS))
        model.load()
        assertEquals(2, harness.faults.calls(Op.MEMBERS))
        session.feed.bump(F.lilas)
        model.load()
        assertEquals(3, harness.faults.calls(Op.MEMBERS))
    }

    @Test
    fun removedMemberScreenIsGone() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = MembersViewModel(session, F.sport, harness.scope)
        model.load()
        harness.device(F.lucas).groups.removeMember(F.sport, F.camille.id)
        model.reload()
        assertTrue(model.ui.isGone)
    }
}
