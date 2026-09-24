package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.UserProfile
import io.github.notkanaa.equipe.core.logic.TaskFilter
import io.github.notkanaa.equipe.core.logic.TaskStatusFilter
import io.github.notkanaa.equipe.mocks.MockScenario
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import io.github.notkanaa.equipe.core.viewmodel.VMFixtures as F

/** Port of the ErrorStateTests suite of ViewModels/RouterTests.swift (errors, load states, presentation helpers). */
class ErrorStateTest {
    @Test
    fun cancellationsAreNeverShown() {
        assertNull(ErrorState.from(CancellationException()))
        assertNull(ErrorState.from(AppError.wrap(CancellationException())))
        assertTrue(ErrorState.isCancellation(CancellationException()))
        assertFalse(ErrorState.isCancellation(AppError.Network))
    }

    @Test
    fun messagesComeFromAppError() {
        val state = ErrorState.from(AppError.LastAdmin)
        assertNotNull(state)
        assertEquals(AppError.LastAdmin.messageFR, state!!.message)
        assertEquals(AppError.LastAdmin, state.error)

        class Opaque : Exception()
        val wrapped = ErrorState.from(Opaque())
        assertTrue(wrapped!!.message.startsWith("Une erreur est survenue."))

        val custom = ErrorState("Texte", null)
        assertEquals("Texte", custom.message)
        assertNotEquals(custom, ErrorState("Texte", null))
    }

    @Test
    fun presentingProtocolHelpers() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val model = LoginViewModel(harness.services)
        assertFalse(model.isShowingError)
        model.present(AppError.Network)
        assertTrue(model.isShowingError)
        assertEquals(AppError.Network.messageFR, model.errorMessage)
        assertEquals(AppError.Network.messageFR, model.ui.errorMessage)
        assertNull(model.present(CancellationException()))
        assertEquals(AppError.Network.messageFR, model.errorMessage)

        // Screens bind dialogs with `isShowingError` (or call dismissError()).
        model.isShowingError = false
        assertNull(model.error)
        model.present("Oups")
        model.dismissError()
        assertNull(model.errorMessage)
    }

    @Test
    fun loadStateHelpers() {
        assertTrue(LoadState.Loading.isLoading)
        assertTrue(LoadState.Loaded.isLoaded)
        assertEquals("x", LoadState.Failed("x").failureMessage)
        assertNull(LoadState.Idle.failureMessage)
    }

    @Test
    fun presentationLabels() {
        assertEquals(listOf("À faire", "En cours", "Terminée"), TaskStatus.entries.map { it.label })
        assertEquals(TaskStatus.IN_PROGRESS, TaskStatus.TODO.next)
        assertEquals(TaskStatus.TODO, TaskStatus.DONE.next)
        assertEquals(listOf("Haute", "Moyenne", "Basse"), TaskPriority.pickerOrder.map { it.label })
        assertEquals("Admin", MemberRole.ADMIN.label)
        assertEquals("Membre", MemberRole.MEMBER.label)
        // Icons: SF Symbols of the iOS app, Material names for Android.
        assertEquals(listOf("circle", "circle.lefthalf.filled", "checkmark.circle.fill"), TaskStatus.entries.map { it.systemImage })
        assertEquals(listOf("RadioButtonUnchecked", "Contrast", "CheckCircle"), TaskStatus.entries.map { it.iconName })
        assertEquals(listOf("arrow.down", "minus", "exclamationmark"), TaskPriority.entries.map { it.systemImage })
        assertEquals(listOf("ArrowDownward", "Remove", "PriorityHigh"), TaskPriority.entries.map { it.iconName })
        assertEquals(listOf("person.3", "checklist", "gearshape"), AppTab.entries.map { it.systemImage })
    }

    @Test
    fun memberDirectoryNames() {
        val me = UUID.randomUUID()
        val lucas = UUID.randomUUID()
        val ines = UUID.randomUUID()
        val group = UUID.randomUUID()
        val date = F.now
        val directory = MemberDirectory(
            members = listOf(
                Membership(group, UserProfile(me, "Camille Martin"), MemberRole.ADMIN, date),
                Membership(group, UserProfile(lucas, "Lucas Bernard"), MemberRole.MEMBER, date),
                Membership(group, UserProfile(ines, "Inès Dubois"), MemberRole.MEMBER, date),
            ),
            currentUserId = me,
        )
        assertEquals(MemberRole.ADMIN, directory.myRole)
        assertEquals(listOf("Vous", "Inès Dubois", "Lucas Bernard"), directory.names(listOf(lucas, me, ines)))
        assertEquals("Non assignée", directory.assigneesText(emptyList()))
        assertEquals("Lucas Bernard", directory.assigneesText(listOf(lucas)))
        assertEquals("Ancien membre", directory.name(UUID.randomUUID()))
        assertEquals("Ancien membre", directory.name(null))
    }

    @Test
    fun filterChips() {
        var filter = TaskFilter.ALL
        assertEquals(
            listOf("Toutes", "À faire", "En cours", "Terminées", "Assignées à moi", "En retard"),
            TaskFilterChip.chips(filter).map { it.label },
        )
        assertEquals(
            listOf<TaskFilterChip.Kind>(TaskFilterChip.Kind.Status(TaskStatusFilter.ALL)),
            TaskFilterChip.chips(filter).filter { it.isSelected }.map { it.kind },
        )

        filter = TaskFilterChip.toggling(TaskFilterChip.Kind.Status(TaskStatusFilter.TODO), filter)
        assertEquals(TaskStatusFilter.TODO, filter.status)
        filter = TaskFilterChip.toggling(TaskFilterChip.Kind.Status(TaskStatusFilter.TODO), filter)
        assertEquals(TaskStatusFilter.ALL, filter.status)
        filter = TaskFilterChip.toggling(TaskFilterChip.Kind.Status(TaskStatusFilter.ALL), filter)
        assertEquals(TaskStatusFilter.ALL, filter.status)
        filter = TaskFilterChip.toggling(TaskFilterChip.Kind.AssignedToMe, filter)
        filter = TaskFilterChip.toggling(TaskFilterChip.Kind.Overdue, filter)
        assertTrue(filter.onlyAssignedToMe && filter.onlyOverdue)
        assertEquals(
            listOf(
                TaskFilterChip.Kind.Status(TaskStatusFilter.ALL),
                TaskFilterChip.Kind.AssignedToMe,
                TaskFilterChip.Kind.Overdue,
            ),
            TaskFilterChip.chips(filter).filter { it.isSelected }.map { it.kind },
        )
    }

    @Test
    fun dateTexts() {
        val now = F.now
        val calendar = F.calendar
        assertEquals("Aujourd’hui à 20:00", DateText.relative(F.date(2026, 9, 24, 20), now, calendar))
        assertEquals("Demain à 18:00", DateText.relative(F.date(2026, 9, 25, 18), now, calendar))
        assertEquals("hier à 09:30", DateText.relativeLowercase(F.date(2026, 9, 23, 9, 30), now, calendar))
        assertEquals("Lundi à 18:00", DateText.relative(F.date(2026, 9, 28, 18), now, calendar))
        assertEquals("Jeudi 1er octobre à 18:00", DateText.relative(F.date(2026, 10, 1, 18), now, calendar))
        assertEquals("Dimanche 20 septembre à 18:00", DateText.relative(F.date(2026, 9, 20, 18), now, calendar))
        assertEquals("hier à 09:30", DateText.relativeInSentence(F.date(2026, 9, 23, 9, 30), now, calendar))
        assertEquals("le lundi 14 septembre à 10:00", DateText.relativeInSentence(F.date(2026, 9, 14, 10), now, calendar))
    }
}
