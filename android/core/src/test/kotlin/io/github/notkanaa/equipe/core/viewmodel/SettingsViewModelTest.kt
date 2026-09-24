package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.logic.ReminderLeadTime
import io.github.notkanaa.equipe.core.logic.ReminderPlanner
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import io.github.notkanaa.equipe.core.viewmodel.VMFaults.Op
import io.github.notkanaa.equipe.core.viewmodel.VMFixtures as F
import io.github.notkanaa.equipe.mocks.DemoData.TaskIds as T

/** Port of the SettingsViewModelTests suite of ViewModels/SettingsViewModelTests.swift. */
@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {
    @Test
    fun loadsProfilePushAndPermission() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = SettingsViewModel(harness.makeSession(), harness.scope)
        model.load()
        val state = model.ui
        assertEquals(LoadState.Loaded, state.loadState)
        assertEquals("Camille Martin", state.profile?.displayName)
        assertEquals("Camille Martin", state.displayName)
        assertEquals("camille@example.com", state.email)
        assertFalse(state.canSaveDisplayName)
        assertNull(state.pushTopic)
        assertFalse(state.isPushEnabled)
        assertEquals(NotificationAuthorization.AUTHORIZED, state.notificationStatus)
        assertEquals("Activées", state.notificationStatusText)
        assertNull(state.notificationHint)
        assertEquals(ReminderLeadTime.ONE_HOUR, state.leadTime)
        assertEquals(5, state.leadTimeOptions.size)
        model.load()
        assertEquals(1, harness.faults.calls(Op.MY_PROFILE))
    }

    @Test
    fun editsTheDisplayName() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = SettingsViewModel(session, harness.scope)
        model.load()

        model.displayName = "   "
        assertFalse(model.ui.canSaveDisplayName)
        assertFalse(model.saveDisplayName())
        assertEquals(AppError.InvalidDisplayName.messageFR, model.ui.displayNameError)
        assertEquals(0, harness.faults.calls(Op.UPDATE_DISPLAY_NAME))

        model.displayName = " Camille M. "
        assertNull(model.ui.displayNameError)
        assertTrue(model.ui.canSaveDisplayName)
        val allRevision = session.feed.allRevision.value
        assertTrue(model.saveDisplayName())
        assertEquals("Camille M.", model.ui.profile?.displayName)
        assertEquals("Camille M.", model.displayName)
        assertEquals(allRevision + 1, session.feed.allRevision.value)
        assertTrue(harness.device(F.lucas).groups.members(F.lilas).any { it.user.displayName == "Camille M." })

        // A reload keeps a name being edited.
        model.displayName = "Brouillon"
        model.reload()
        assertEquals("Brouillon", model.displayName)
    }

    @Test
    fun leadTimeIsPersistedAndReschedulesReminders() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = SettingsViewModel(session, harness.scope)
        model.load()
        assertTrue(session.synchronizeReminders())
        val poubellesDue = harness.services.tasks.task(T.sortirPoubelles).dueAt!!
        val poubellesId = ReminderPlanner.identifier(T.sortirPoubelles, poubellesDue)
        assertEquals(poubellesDue.minusSeconds(3600), harness.scheduler.pending[poubellesId]?.fireDate)

        assertTrue(model.setLeadTime(ReminderLeadTime.FIFTEEN_MINUTES))
        assertEquals(ReminderLeadTime.FIFTEEN_MINUTES, model.leadTime)
        assertEquals(ReminderLeadTime.FIFTEEN_MINUTES, ReminderLeadTime.load(harness.store))
        assertEquals(poubellesDue.minusSeconds(900), harness.scheduler.pending[poubellesId]?.fireDate)

        // The picker binding persists and resynchronizes in the background.
        model.leadTime = ReminderLeadTime.OFF
        model.waitForBackgroundWork()
        assertEquals(ReminderLeadTime.OFF, ReminderLeadTime.load(harness.store))
        assertTrue(harness.scheduler.dueIds.isEmpty())

        // A failed list keeps the current schedule.
        model.leadTime = ReminderLeadTime.ONE_HOUR
        model.waitForBackgroundWork()
        assertEquals(3, harness.scheduler.dueIds.size)
        harness.faults.fail(Op.MY_TASKS, AppError.Network)
        assertFalse(model.setLeadTime(ReminderLeadTime.AT_DUE_TIME))
        assertEquals(3, harness.scheduler.dueIds.size)
        assertEquals(poubellesDue.minusSeconds(3600), harness.scheduler.pending[poubellesId]?.fireDate)
    }

    @Test
    fun pushTopicLifecycle() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = SettingsViewModel(harness.makeSession(), harness.scope)
        model.load()
        assertEquals(3, SettingsViewModel.PUSH_INSTRUCTION_STEPS.size)
        assertTrue(SettingsViewModel.PUSH_INSTRUCTION_STEPS[0].contains("ntfy"))
        assertEquals(
            "Une notification vous prévient quand une tâche vous est assignée, même quand Équipe est fermée.",
            SettingsViewModel.PUSH_INSTRUCTION_STEPS[2],
        )

        assertTrue(model.setPushEnabled(true))
        val topic = model.ui.pushTopic!!
        assertTrue(topic.startsWith("equipe-"))
        assertTrue(model.ui.isPushEnabled)
        assertEquals("https://ntfy.sh/$topic", model.ui.pushTopicUrl)
        assertEquals("ntfy://ntfy.sh/$topic", model.ui.ntfyAppUrl)
        assertEquals(topic, harness.services.push.currentTopic())

        assertTrue(model.enablePush())
        assertEquals(topic, model.ui.pushTopic)

        assertTrue(model.setPushEnabled(false))
        assertNull(model.ui.pushTopic)
        assertNull(model.ui.pushTopicUrl)
        assertNull(harness.services.push.currentTopic())

        harness.faults.fail(Op.ENABLE_PUSH, AppError.Network)
        assertFalse(model.enablePush())
        assertEquals(AppError.Network.messageFR, model.errorMessage)
        assertFalse(model.ui.isPushEnabled)
    }

    @Test
    fun notificationPermission() = runTest {
        val harness = VMHarness(backgroundScope, authorization = NotificationAuthorization.NOT_DETERMINED)
        val model = SettingsViewModel(harness.makeSession(), harness.scope)
        model.load()
        assertEquals(NotificationAuthorization.NOT_DETERMINED, model.ui.notificationStatus)
        assertTrue(model.ui.canRequestNotifications)
        assertEquals("Pas encore demandées", model.ui.notificationStatusText)
        assertNotNull(model.ui.notificationHint)

        assertTrue(model.requestNotifications())
        assertEquals(NotificationAuthorization.AUTHORIZED, model.ui.notificationStatus)
        assertFalse(model.ui.canRequestNotifications)
        // Granted: the reminders are scheduled right away.
        val expected = harness.reminderIds(listOf(T.sortirPoubelles, T.faireCourses, T.reserverGymnase))
        assertEquals(expected, harness.scheduler.dueIds)

        // Asking again does not prompt again.
        assertTrue(model.requestNotifications())
        assertEquals(1, harness.scheduler.requestCount)
    }

    @Test
    fun refusedNotifications() = runTest {
        val harness = VMHarness(backgroundScope, authorization = NotificationAuthorization.NOT_DETERMINED)
        harness.scheduler.grantOnRequest = false
        val model = SettingsViewModel(harness.makeSession(), harness.scope)
        assertFalse(model.requestNotifications())
        assertEquals(NotificationAuthorization.DENIED, model.ui.notificationStatus)
        assertEquals("Refusées", model.ui.notificationStatusText)
        // Android wording: the permission lives in the phone's « Paramètres » (iOS: « l’app Réglages de l’iPhone »).
        assertTrue(model.ui.notificationHint!!.contains("Paramètres"))
        assertTrue(harness.scheduler.dueIds.isEmpty())

        harness.scheduler.authorization = NotificationAuthorization.AUTHORIZED
        model.refreshNotificationStatus()
        assertEquals(NotificationAuthorization.AUTHORIZED, model.ui.notificationStatus)
    }

    @Test
    fun accountDeletionNeedsTheExactWord() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = SettingsViewModel(session, harness.scope)
        MyTasksViewModel.saveLastSeen(harness.store, F.camille.id, F.now)
        assertFalse(model.ui.canDeleteAccount)
        model.deleteConfirmation = "supprimer"
        assertFalse(model.ui.canDeleteAccount)
        assertFalse(model.deleteAccount())
        assertEquals("Tapez « SUPPRIMER » pour confirmer.", model.errorMessage)
        model.deleteConfirmation = " SUPPRIMER"
        assertFalse(model.ui.canDeleteAccount)
        assertEquals(0, harness.faults.calls(Op.DELETE_ACCOUNT))

        model.deleteConfirmation = "SUPPRIMER"
        assertTrue(model.ui.canDeleteAccount)
        assertTrue(SettingsViewModel.DELETE_ACCOUNT_WARNING.contains("« SUPPRIMER »"))
        assertTrue(SettingsViewModel.DELETE_ACCOUNT_WARNING.contains("deviendra admin si vous étiez le seul admin."))
        assertTrue(model.deleteAccount())
        assertNull(harness.services.auth.currentUser())
        assertNull(harness.backend.userId(F.camille.email))
        assertNull(harness.store.data(MyTasksViewModel.lastSeenKey(F.camille.id)))
        assertTrue(model.deleteConfirmation.isEmpty())
    }

    @Test
    fun deletionFailureIsShown() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = SettingsViewModel(harness.makeSession(), harness.scope)
        model.deleteConfirmation = "SUPPRIMER"
        harness.faults.fail(Op.DELETE_ACCOUNT, AppError.Network)
        assertFalse(model.deleteAccount())
        assertEquals(AppError.Network.messageFR, model.errorMessage)
        assertNotNull(harness.services.auth.currentUser())
    }

    /**
     * `delete_my_account` ran but its answer was lost: « Réessayer » finds the account gone, which is the requested end
     * state. The app signs out and the reminders of the deleted account are removed (review VM-2).
     */
    @Test
    fun retryAfterALostAnswerCompletesTheDeletion() = runTest {
        val harness = VMHarness(backgroundScope)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed in") { app.session != null }
        val session = app.session!!
        session.startupJob?.join()
        assertEquals(3, harness.scheduler.dueIds.size)
        val settings = SettingsViewModel(session, harness.scope)
        settings.deleteConfirmation = SettingsViewModel.DELETE_CONFIRMATION_WORD
        MyTasksViewModel.saveLastSeen(harness.store, F.camille.id, F.now)

        // Server side the account is deleted; client side the answer never arrives.
        harness.device(F.camille).auth.deleteAccount()
        harness.faults.fail(Op.DELETE_ACCOUNT, AppError.Network)
        assertFalse(settings.deleteAccount())
        assertEquals(AppError.Network.messageFR, settings.errorMessage)

        assertTrue("retry error: ${settings.errorMessage ?: "-"}", settings.deleteAccount())
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }
        waitUntil("reminders removed") { harness.scheduler.dueIds.isEmpty() }
        assertNull(harness.store.data(MyTasksViewModel.lastSeenKey(F.camille.id)))
        assertNull(harness.services.auth.currentUser())
        app.shutdown()
    }

    @Test
    fun signsOut() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = SettingsViewModel(harness.makeSession(), harness.scope)
        assertTrue(model.signOut())
        assertNull(harness.services.auth.currentUser())
        assertFalse(model.ui.isSigningOut)
    }

    @Test
    fun loadFailure() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = SettingsViewModel(harness.makeSession(), harness.scope)
        harness.faults.fail(Op.CURRENT_TOPIC, AppError.Network)
        model.load()
        assertEquals(LoadState.Failed(AppError.Network.messageFR), model.ui.loadState)
        model.load()
        assertEquals(LoadState.Loaded, model.ui.loadState)
    }

    @Test
    fun reloadsWhenMembershipsSignalArrives() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = SettingsViewModel(session, harness.scope)
        model.load()
        session.feed.bumpMemberships()
        assertTrue(model.needsRefresh)
        model.load()
        assertEquals(2, harness.faults.calls(Op.MY_PROFILE))
    }
}
