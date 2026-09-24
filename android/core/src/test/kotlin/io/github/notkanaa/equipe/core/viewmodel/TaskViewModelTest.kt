package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.logic.DueBucket
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.mocks.MockScenario
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant
import kotlin.time.Duration.Companion.seconds
import io.github.notkanaa.equipe.core.viewmodel.VMFaults.Op
import io.github.notkanaa.equipe.core.viewmodel.VMFixtures as F
import io.github.notkanaa.equipe.mocks.DemoData.TaskIds as T

/** Port of the TaskEditorViewModelTests suite of ViewModels/TaskViewModelTests.swift. */
class TaskEditorViewModelTest {
    @Test
    fun newTaskDefaults() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = TaskEditorViewModel(harness.makeSession(), TaskEditorMode.Create(F.lilas), harness.scope)
        val state = model.ui
        assertFalse(state.isEditing)
        assertEquals("Nouvelle tâche", state.navigationTitle)
        assertEquals("Créer", state.saveButtonTitle)
        assertEquals(TaskPriority.MEDIUM, state.priority)
        assertFalse(state.hasDueDate)
        assertEquals(F.date(2026, 9, 25, 18), state.dueDate)
        assertFalse(state.hasChanges)
        assertFalse(state.canSave)
        assertEquals(LoadState.Idle, state.loadState)

        model.load()
        assertEquals(LoadState.Loaded, model.ui.loadState)
        assertEquals(listOf("Camille Martin (vous)", "Inès Dubois", "Lucas Bernard"), model.ui.assigneeOptions.map { it.name })
        assertEquals(listOf(true, false, false), model.ui.assigneeOptions.map { it.isMe })
        assertEquals("Non assignée", model.ui.assigneesSummary)
        model.load()
        assertEquals(1, harness.faults.calls(Op.MEMBERS))
    }

    @Test
    fun validatesBeforeCallingTheService() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = TaskEditorViewModel(harness.makeSession(), TaskEditorMode.Create(F.lilas), harness.scope)
        model.title = "   "
        model.details = "d".repeat(5001)
        model.hasDueDate = true
        model.dueDate = Instant.ofEpochSecond(253_402_300_800L) // year 10000
        assertNull(model.save())
        assertEquals("Le titre doit contenir entre 1 et 200 caractères.", model.ui.titleError)
        assertEquals("La description ne doit pas dépasser 5000 caractères.", model.ui.detailsError)
        assertEquals(TaskEditorViewModel.INVALID_DUE_DATE_MESSAGE, model.ui.dueDateError)
        assertEquals(0, harness.faults.calls(Op.CREATE_TASK))

        model.title = "Arroser les plantes"
        assertNull(model.ui.titleError)
        model.details = "Deux fois par semaine."
        assertNull(model.ui.detailsError)
        model.hasDueDate = false
        assertNull(model.ui.dueDateError)
    }

    @Test
    fun createsATask() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = TaskEditorViewModel(session, TaskEditorMode.Create(F.lilas), harness.scope)
        model.load()
        model.title = "  Arroser les plantes "
        model.details = "Deux fois par semaine."
        model.priority = TaskPriority.HIGH
        model.hasDueDate = true
        model.toggleAssignee(F.lucas.id)
        model.toggleAssignee(F.camille.id)
        assertEquals("Vous, Lucas Bernard", model.ui.assigneesSummary)
        assertTrue(model.ui.hasChanges)
        assertTrue(model.ui.canSave)
        val groupRevision = session.feed.groupRevision(F.lilas)

        val task = model.save()
        assertNotNull(task)
        task!!
        assertEquals("Arroser les plantes", task.title)
        assertEquals("Deux fois par semaine.", task.details)
        assertEquals(TaskPriority.HIGH, task.priority)
        assertEquals(F.date(2026, 9, 25, 18), task.dueAt)
        assertEquals(setOf(F.lucas.id, F.camille.id), task.assigneeIds.toSet())
        assertEquals(F.camille.id, task.createdBy)
        assertEquals(task, model.ui.savedTask)
        assertEquals(groupRevision + 1, session.feed.groupRevision(F.lilas))
        assertEquals(task, harness.services.tasks.task(task.id))
    }

    @Test
    fun assigneeLimit() = runTest {
        val harness = VMHarness(backgroundScope)
        // 20 more members in « Coloc' rue des Lilas ».
        for (index in 1..20) {
            val account = harness.backend.createAccount(
                email = "colocataire$index@example.com",
                password = DemoData.password,
                displayName = "Colocataire $index",
            )
            harness.backend.services(account.id).groups.join(InviteCode.parse("LYLAS234")!!)
        }
        val model = TaskEditorViewModel(harness.makeSession(), TaskEditorMode.Create(F.lilas), harness.scope)
        model.load()
        assertEquals(23, model.ui.members.size)
        for (member in model.ui.members.take(20)) {
            model.toggleAssignee(member.user.id)
        }
        assertTrue(model.ui.assigneeLimitReached)
        val extra = model.ui.members[20].user.id
        model.toggleAssignee(extra)
        assertFalse(model.ui.isAssigned(extra))
        assertEquals("20 personnes assignées au maximum.", model.ui.assigneesError)
        model.toggleAssignee(model.ui.members[0].user.id)
        assertNull(model.ui.assigneesError)
        assertFalse(model.ui.assigneeLimitReached)

        model.title = "Grand ménage"
        model.toggleAssignee(extra)
        val task = model.save()
        assertEquals(20, task!!.assigneeIds.size)
    }

    @Test
    fun serverAssigneeErrorsReloadTheMembers() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = TaskEditorViewModel(harness.makeSession(), TaskEditorMode.Create(F.lilas), harness.scope)
        model.load()
        model.title = "Tâche"
        model.toggleAssignee(F.ines.id)
        harness.faults.fail(Op.CREATE_TASK, AppError.AssigneeNotMember)
        assertNull(model.save())
        assertEquals(AppError.AssigneeNotMember.messageFR, model.ui.assigneesError)
        assertEquals(2, harness.faults.calls(Op.MEMBERS))

        harness.faults.fail(Op.CREATE_TASK, AppError.Network)
        assertNull(model.save())
        assertEquals(AppError.Network.messageFR, model.errorMessage)
        assertNull(model.ui.savedTask)
    }

    /**
     * After `assignee_not_member` the members are reloaded and the people who left are dropped from the selection
     * (review VM-5): saving again works.
     */
    @Test
    fun departedAssigneeIsDroppedAfterAssigneeNotMember() = runTest {
        val harness = VMHarness(backgroundScope)
        val editor = TaskEditorViewModel(harness.makeSession(), TaskEditorMode.Create(F.lilas), harness.scope)
        editor.load()
        editor.title = "Arroser les plantes"
        editor.toggleAssignee(F.ines.id)
        editor.toggleAssignee(F.lucas.id)
        // Inès leaves the group from her phone before Camille saves.
        harness.device(F.ines).groups.leave(F.lilas)

        assertNull(editor.save())
        assertEquals(TaskEditorViewModel.DEPARTED_ASSIGNEES_MESSAGE, editor.ui.assigneesError)
        assertFalse(editor.ui.assigneeOptions.any { it.id == F.ines.id })
        assertEquals(setOf(F.lucas.id), editor.ui.assigneeIds)
        assertEquals("Lucas Bernard", editor.ui.assigneesSummary)

        val saved = editor.save()
        assertEquals(listOf(F.lucas.id), saved!!.assigneeIds)
        assertNull(editor.ui.assigneesError)
    }

    /** Editing a task whose list row still shows someone who left: loading the members drops them, without counting as a change of the user. */
    @Test
    fun editorDropsAssigneesWhoLeftWhenLoadingTheMembers() = runTest {
        val harness = VMHarness(backgroundScope)
        val courses = harness.services.tasks.task(T.faireCourses)
        assertTrue(courses.assigneeIds.contains(F.lucas.id))
        harness.device(F.lucas).groups.leave(F.lilas)

        val editor = TaskEditorViewModel(harness.makeSession(), TaskEditorMode.Edit(courses), harness.scope)
        editor.load()
        assertEquals(setOf(F.camille.id), editor.ui.assigneeIds)
        assertFalse(editor.ui.hasChanges)
    }

    @Test
    fun editsATask() = runTest {
        val harness = VMHarness(backgroundScope)
        val original = harness.services.tasks.task(T.sortirPoubelles)
        val model = TaskEditorViewModel(harness.makeSession(), TaskEditorMode.Edit(original), harness.scope)
        val state = model.ui
        assertTrue(state.isEditing)
        assertEquals("Modifier la tâche", state.navigationTitle)
        assertEquals("Enregistrer", state.saveButtonTitle)
        assertEquals("Sortir les poubelles", state.title)
        assertEquals(TaskPriority.HIGH, state.priority)
        assertTrue(state.hasDueDate)
        assertEquals(original.dueAt, state.dueDate)
        assertEquals(setOf(F.camille.id), state.assigneeIds)
        assertFalse(state.hasChanges)

        model.load()
        assertTrue(model.ui.canEdit)
        model.title = "Sortir toutes les poubelles"
        model.hasDueDate = false
        assertTrue(model.ui.hasChanges)
        val saved = model.save()
        assertEquals("Sortir toutes les poubelles", saved!!.title)
        assertNull(saved.dueAt)
        assertEquals(1, harness.faults.calls(Op.UPDATE_TASK))
    }

    @Test
    fun nonEditorsCannotSave() = runTest {
        val harness = VMHarness(backgroundScope)
        val affiche = harness.services.tasks.task(T.creerAffiche)
        val model = TaskEditorViewModel(harness.makeSession(), TaskEditorMode.Edit(affiche), harness.scope)
        model.load()
        assertEquals(MemberRole.MEMBER, model.ui.myRole)
        assertFalse(model.ui.canEdit)
        assertFalse(model.ui.canSave)
        assertNull(model.save())
        assertEquals(AppError.Forbidden.messageFR, model.errorMessage)
        assertEquals(0, harness.faults.calls(Op.UPDATE_TASK))
    }

    @Test
    fun editingADeletedTask() = runTest {
        val harness = VMHarness(backgroundScope)
        val fuite = harness.services.tasks.task(T.reparerFuite)
        val model = TaskEditorViewModel(harness.makeSession(), TaskEditorMode.Edit(fuite), harness.scope)
        harness.device(F.ines).tasks.delete(fuite.id)
        model.title = "Réparer la fuite (urgent)"
        assertNull(model.save())
        assertTrue(model.ui.isGone)
        assertEquals(TaskEditorViewModel.GONE_MESSAGE, model.errorMessage)
    }

    @Test
    fun defaultDueDateIsTomorrowEvening() {
        val calendar = F.calendar
        assertEquals(F.date(2026, 9, 25, 18), TaskEditorViewModel.defaultDueDate(F.date(2026, 9, 24, 23, 30), calendar))
        assertEquals(F.date(2027, 1, 1, 18), TaskEditorViewModel.defaultDueDate(F.date(2026, 12, 31, 8), calendar))
    }

    // region Kotlin additions

    @Test
    fun modeCarriesTheGroup() {
        val task = TaskEditorMode.Create(F.lilas)
        assertEquals(F.lilas, task.groupId)
        assertEquals(TaskEditorMode.Create(F.lilas), task)
    }

    @Test
    fun membersHandedOverNeedNoRequest() = runTest {
        val harness = VMHarness(backgroundScope)
        val members = harness.services.groups.members(F.lilas)
        val calls = harness.faults.calls(Op.MEMBERS)
        val model = TaskEditorViewModel(harness.makeSession(), TaskEditorMode.Create(F.lilas), harness.scope, members)
        assertEquals(LoadState.Loaded, model.ui.loadState)
        model.load()
        assertEquals(calls, harness.faults.calls(Op.MEMBERS))
        assertEquals(3, model.ui.assigneeOptions.size)
    }

    // endregion
}

/** Port of the TaskDetailViewModelTests suite of ViewModels/TaskViewModelTests.swift. */
class TaskDetailViewModelTest {
    @Test
    fun loadsTheTaskWithNames() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = TaskDetailViewModel(harness.makeSession(), F.lilas, T.faireCourses, harness.scope)
        assertEquals("Tâche", model.ui.title)
        model.load()
        val state = model.ui
        assertEquals(LoadState.Loaded, state.loadState)
        assertEquals("Faire les courses", state.title)
        assertEquals("Lait, pâtes, lessive et papier toilette.", state.details)
        assertEquals(TaskStatus.IN_PROGRESS, state.status)
        assertEquals(TaskPriority.MEDIUM, state.priority)
        assertEquals("Demain à 18:00", state.dueText)
        assertFalse(state.isOverdue)
        assertEquals(listOf("Vous", "Lucas Bernard"), state.assigneeNames)
        assertEquals("Vous, Lucas Bernard", state.assigneesText)
        assertEquals("Lucas Bernard", state.creatorName)
        assertEquals("Créée par Lucas Bernard le mardi 22 septembre à 10:00", state.createdText)
        assertNull(state.completedText)
        assertEquals(MemberRole.ADMIN, state.myRole)
        assertTrue(state.canEdit && state.canChangeStatus && state.canDelete)
        assertEquals(listOf(TaskStatus.TODO, TaskStatus.IN_PROGRESS, TaskStatus.DONE), state.statusOptions)
        assertTrue(state.deleteConfirmationMessage.contains("« Faire les courses »"))
        assertEquals(TaskEditorMode.Edit(state.task!!), state.editorMode)
    }

    @Test
    fun myOwnTaskAndOverdue() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = TaskDetailViewModel(harness.makeSession(), F.lilas, T.payerLoyer, harness.scope)
        model.load()
        val state = model.ui
        assertTrue(state.isOverdue)
        assertEquals("Hier à 18:00", state.dueText)
        assertEquals("Vous", state.creatorName)
        assertEquals("Créée par vous le vendredi 18 septembre à 10:00", state.createdText)
        assertEquals(listOf("Inès Dubois"), state.assigneeNames)
    }

    @Test
    fun assigneeCanOnlyChangeTheStatus() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = TaskDetailViewModel(session, F.sport, T.reserverGymnase, harness.scope)
        model.load()
        assertEquals(MemberRole.MEMBER, model.ui.myRole)
        assertTrue(model.ui.canChangeStatus)
        assertFalse(model.ui.canEdit || model.ui.canDelete)
        assertNull(model.makeEditor())
        assertNull(model.ui.editorMode)

        assertFalse(model.delete())
        assertEquals(AppError.Forbidden.messageFR, model.errorMessage)
        assertEquals(0, harness.faults.calls(Op.DELETE_TASK))

        val myTasksRevision = session.feed.myTasksRevision.value
        assertTrue(model.setStatus(TaskStatus.DONE))
        assertEquals(TaskStatus.DONE, model.ui.status)
        assertTrue(model.ui.completedText!!.startsWith("Terminée aujourd’hui à "))
        assertEquals(myTasksRevision + 1, session.feed.myTasksRevision.value)
        // Same status again: nothing to do.
        assertFalse(model.setStatus(TaskStatus.DONE))
        assertEquals(1, harness.faults.calls(Op.SET_STATUS))
    }

    @Test
    fun otherMembersSeeButCannotAct() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = TaskDetailViewModel(harness.makeSession(), F.sport, T.creerAffiche, harness.scope)
        model.load()
        assertFalse(model.ui.canChangeStatus || model.ui.canEdit || model.ui.canDelete)
        assertFalse(model.setStatus(TaskStatus.DONE))
        assertEquals(0, harness.faults.calls(Op.SET_STATUS))
    }

    /**
     * `equipe://task/<Coloc'>/<task of Asso Sport>`: the rights would follow Camille's admin role in the wrong group
     * (review VM-3). The task is not shown there.
     */
    @Test
    fun linkNamingAnotherGroupIsGone() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val router = Router()
        router.activate()
        assertTrue(router.open("equipe://task/${F.lilas}/${T.creerAffiche}"))

        val model = TaskDetailViewModel(session, F.lilas, T.creerAffiche, harness.scope)
        model.load()
        assertTrue(model.ui.isGone)
        assertNull(model.ui.task)
        assertFalse(model.ui.canEdit)
        assertFalse(model.ui.canDelete)
        assertFalse(model.ui.canChangeStatus)
        assertNull(model.makeEditor())
        assertFalse(model.delete())
        assertEquals(0, harness.faults.calls(Op.DELETE_TASK))

        // The right link works.
        val right = TaskDetailViewModel(session, F.sport, T.creerAffiche, harness.scope)
        right.load()
        assertFalse(right.ui.isGone)
        assertFalse(right.ui.canEdit || right.ui.canDelete || right.ui.canChangeStatus)

        // A task handed over with another group is not shown before the load either.
        val affiche = session.services.tasks.task(T.creerAffiche)
        val handedOver = TaskDetailViewModel(session, F.lilas, T.creerAffiche, harness.scope, task = affiche)
        assertNull(handedOver.ui.task)
    }

    @Test
    fun deletes() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = TaskDetailViewModel(harness.makeSession(), F.lilas, T.reparerFuite, harness.scope)
        model.load()
        assertTrue(model.delete())
        assertTrue(model.ui.didDelete && model.ui.isGone)
        try {
            harness.services.tasks.task(T.reparerFuite)
            fail("expected NotFound")
        } catch (error: AppError) {
            assertEquals(AppError.NotFound, error)
        }
    }

    @Test
    fun deletedElsewhereIsGone() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = TaskDetailViewModel(session, F.lilas, T.faireCourses, harness.scope)
        model.load()
        harness.device(F.lucas).tasks.delete(T.faireCourses)
        session.feed.bump(F.lilas)
        model.load()
        assertTrue(model.ui.isGone)
        assertFalse(model.ui.didDelete)
        assertNull(model.error)
    }

    @Test
    fun reloadsOnGroupRevision() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = TaskDetailViewModel(session, F.lilas, T.faireCourses, harness.scope)
        model.load()
        model.load()
        assertEquals(1, harness.faults.calls(Op.TASK))
        harness.device(F.lucas).tasks.setStatus(T.faireCourses, TaskStatus.DONE)
        session.feed.bump(F.lilas)
        model.load()
        assertEquals(2, harness.faults.calls(Op.TASK))
        assertEquals(TaskStatus.DONE, model.ui.status)
    }

    @Test
    fun editorRoundTrip() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = TaskDetailViewModel(harness.makeSession(), F.lilas, T.sortirPoubelles, harness.scope)
        model.load()
        val editor = model.makeEditor()!!
        assertTrue(editor.ui.isEditing)
        assertEquals(LoadState.Loaded, editor.ui.loadState) // members handed over
        editor.title = "Sortir les poubelles (jaune)"
        val saved = editor.save()!!
        model.apply(saved)
        assertEquals("Sortir les poubelles (jaune)", model.ui.title)
    }

    @Test
    fun loadFailureThenRetry() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = TaskDetailViewModel(harness.makeSession(), F.lilas, T.faireCourses, harness.scope)
        harness.faults.fail(Op.TASK, AppError.Network)
        model.load()
        assertEquals(LoadState.Failed(AppError.Network.messageFR), model.ui.loadState)
        assertFalse(model.ui.canEdit)
        model.reload()
        assertEquals(LoadState.Loaded, model.ui.loadState)
    }
}

/** Port of the MyTasksViewModelTests suite of ViewModels/TaskViewModelTests.swift. */
class MyTasksViewModelTest {
    @Test
    fun sectionsAndNewBadges() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = MyTasksViewModel(harness.makeSession(), harness.scope)
        model.load()
        val state = model.ui
        assertEquals(LoadState.Loaded, state.loadState)
        assertEquals(listOf(DueBucket.TODAY, DueBucket.THIS_WEEK), state.sections.map { it.bucket })
        assertEquals(listOf("Aujourd’hui", "Cette semaine"), state.sections.map { it.title })
        assertEquals(listOf(T.sortirPoubelles), state.sections[0].rows.map { it.id })
        assertEquals(listOf(T.faireCourses, T.reserverGymnase), state.sections[1].rows.map { it.id })
        val rows = state.sections.flatMap { it.rows }
        assertEquals(listOf("Coloc' rue des Lilas", "Coloc' rue des Lilas", "Projet Asso Sport"), rows.map { it.groupName })
        assertEquals(listOf("Aujourd’hui à 20:00", "Demain à 18:00", "Dimanche à 18:00"), rows.map { it.dueText })
        assertTrue(rows.all { it.canChangeStatus && !it.canEdit && it.assigneesText == null })
        // Never looked: tasks assigned by someone else are new, my own task is not.
        assertEquals(listOf(false, true, true), rows.map { it.isNew })
        assertEquals(2, state.newCount)
        assertFalse(state.isEmpty)
    }

    @Test
    fun markAllSeenPersistsPerUser() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = MyTasksViewModel(session, harness.scope)
        model.load()
        model.markAllSeen()
        assertEquals(0, model.ui.newCount)
        assertNotNull(MyTasksViewModel.loadLastSeen(harness.store, F.camille.id))

        val again = MyTasksViewModel(session, harness.scope)
        again.load()
        assertEquals(0, again.ui.newCount)

        // A new assignment by Lucas after that is new.
        harness.clock.advance(60.seconds)
        val created = harness.device(F.lucas).tasks.create(
            F.lilas,
            TaskDraft(title = "Descendre le carton", assigneeIds = setOf(F.camille.id)),
        )
        session.feed.bumpMyTasks()
        again.load()
        assertEquals(1, again.ui.newCount)
        assertTrue(again.ui.isNew(again.ui.tasks.first { it.id == created.id }))
    }

    /**
     * « Nouveau » means assigned by someone else: assigning oneself a task created by another member is not new (review
     * VM-4), like `AssignmentNotifier`, which ignores self-assignments.
     */
    @Test
    fun selfAssignmentIsNotNew() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val myTasks = MyTasksViewModel(session, harness.scope)
        myTasks.load()
        myTasks.markAllSeen()
        harness.clock.advance(60.seconds)

        // Camille (admin of « Coloc' ») assigns herself « Réparer la fuite du lavabo » (created by Inès).
        val lavabo = session.services.tasks.task(T.reparerFuite)
        val editor = TaskEditorViewModel(session, TaskEditorMode.Edit(lavabo), harness.scope)
        editor.load()
        editor.toggleAssignee(F.camille.id)
        assertNotNull(editor.save())

        myTasks.load()
        val task = myTasks.ui.tasks.first { it.id == T.reparerFuite }
        assertEquals(F.camille.id, task.myAssignedBy)
        val row = myTasks.ui.sections.flatMap { it.rows }.first { it.id == T.reparerFuite }
        assertFalse(row.isNew)
        assertEquals(0, myTasks.ui.newCount)

        // Assigned by Lucas: new.
        val courses = myTasks.ui.tasks.first { it.id == T.faireCourses }
        assertEquals(F.lucas.id, courses.myAssignedBy)
        val byDeletedAccount = courses.copy(myAssignedBy = null, myAssignedAt = harness.clock.peek().plusSeconds(60))
        assertTrue("an assigner who deleted their account is someone else", myTasks.ui.isNew(byDeletedAccount))
    }

    @Test
    fun includeDoneShowsTheDoneSection() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = MyTasksViewModel(harness.makeSession(), harness.scope)
        model.load()
        model.includeDone = true
        assertTrue(model.needsRefresh)
        model.load()
        assertEquals(2, harness.faults.calls(Op.MY_TASKS))
        assertEquals(listOf(DueBucket.TODAY, DueBucket.THIS_WEEK, DueBucket.DONE), model.ui.sections.map { it.bucket })
        assertEquals(listOf(T.nettoyerCuisine), model.ui.sections.last().rows.map { it.id })
        assertEquals(false, model.ui.sections.last().rows.first().isNew)
    }

    @Test
    fun synchronizesRemindersAfterASuccessfulLoadOnly() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = MyTasksViewModel(harness.makeSession(), harness.scope)

        harness.faults.fail(Op.MY_TASKS, AppError.Network)
        model.load()
        assertEquals(LoadState.Failed(AppError.Network.messageFR), model.ui.loadState)
        assertTrue(harness.scheduler.dueIds.isEmpty())

        model.reload()
        val expected = harness.reminderIds(listOf(T.sortirPoubelles, T.faireCourses, T.reserverGymnase))
        assertEquals(expected, harness.scheduler.dueIds)

        // A failed reload keeps the content and every reminder.
        harness.faults.fail(Op.MY_TASKS, AppError.Network)
        model.reload()
        assertEquals(LoadState.Loaded, model.ui.loadState)
        assertEquals(AppError.Network.messageFR, model.errorMessage)
        assertEquals(expected, harness.scheduler.dueIds)
    }

    @Test
    fun statusChangeFromTheList() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = MyTasksViewModel(session, harness.scope)
        model.load()
        val courses = model.ui.tasks.first { it.id == T.faireCourses }
        val groupRevision = session.feed.groupRevision(F.lilas)
        assertTrue(model.setStatus(TaskStatus.DONE, courses))
        // Hidden until « Terminées » is shown, group name kept.
        assertFalse(model.ui.sections.flatMap { it.rows }.any { it.id == courses.id })
        assertEquals("Coloc' rue des Lilas", model.ui.tasks.first { it.id == courses.id }.groupName)
        assertNotNull(model.ui.tasks.first { it.id == courses.id }.myAssignedAt)
        assertEquals(groupRevision + 1, session.feed.groupRevision(F.lilas))

        // Refreshes on the « Mes tâches » revision.
        model.load()
        assertEquals(2, harness.faults.calls(Op.MY_TASKS))
        assertFalse(model.ui.tasks.any { it.id == courses.id })
    }

    @Test
    fun emptyState() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.EMPTY_GROUPS)
        val model = MyTasksViewModel(harness.makeSession(), harness.scope)
        model.load()
        assertTrue(model.ui.isEmpty)
        assertEquals(0, model.ui.newCount)
    }

    // region Kotlin additions

    /** One « Mes tâches » per session, shared by the tab badge and the screen. */
    @Test
    fun sessionSharesOneInstance() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val shared = session.myTasks
        assertTrue(shared === session.myTasks)
        shared.load()
        assertEquals(2, session.myTasks.ui.newCount)
        shared.markAllSeen()
        assertEquals(0, session.myTasks.ui.newCount)
    }

    // endregion
}
