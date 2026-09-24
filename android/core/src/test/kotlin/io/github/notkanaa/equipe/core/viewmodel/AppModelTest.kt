package io.github.notkanaa.equipe.core.viewmodel

import app.cash.turbine.test
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.logic.AssignmentNotifier
import io.github.notkanaa.equipe.core.uuidString
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.mocks.MockScenario
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds
import io.github.notkanaa.equipe.core.viewmodel.VMFaults.Op
import io.github.notkanaa.equipe.core.viewmodel.VMFixtures as F
import io.github.notkanaa.equipe.mocks.DemoData.TaskIds as T

/** Port of the AppModelTests suite of ViewModels/AppModelTests.swift. */
@OptIn(ExperimentalCoroutinesApi::class)
class AppModelTest {
    @Test
    fun restoresTheSessionAndStartsIt() = runTest {
        val harness = VMHarness(backgroundScope)
        val app = harness.makeApp()
        assertEquals(AppPhase.Launching, app.phase)
        assertNull(app.session)
        app.start()
        app.start()
        waitUntil("signed in") { app.session != null }
        val session = app.session!!
        assertEquals(F.camille.id, session.userId)
        assertEquals(F.camille.email, session.user.email)
        assertTrue(session.isRunning)
        assertTrue(app.router.isActive)
        assertEquals(AppPhase.SignedIn(session), app.phase)
        waitUntil("realtime subscribed") { harness.backend.realtimeSubscriberCount == 1 }
        session.startupJob?.join()
        // Startup synchronizes the reminders with « Mes tâches ».
        val expected = harness.reminderIds(listOf(T.sortirPoubelles, T.faireCourses, T.reserverGymnase))
        assertEquals(expected, harness.scheduler.dueIds)
        app.shutdown()
        assertEquals(AppPhase.SignedOut, app.phase)
        waitUntil("realtime stopped") { harness.backend.realtimeSubscriberCount == 0 }
    }

    @Test
    fun signedOutThenSignIn() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }
        assertFalse(app.router.isActive)

        val login = app.makeLoginViewModel(email = F.camille.email)
        login.password = DemoData.password
        assertTrue(login.signIn())
        waitUntil("signed in") { app.session != null }
        assertEquals(F.camille.id, app.session?.userId)
        app.shutdown()
    }

    @Test
    fun signOutTearsTheSessionDown() = runTest {
        val harness = VMHarness(backgroundScope)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed in") { app.session != null }
        val session = app.session!!
        session.startupJob?.join()
        waitUntil("realtime subscribed") { harness.backend.realtimeSubscriberCount == 1 }
        assertEquals(3, harness.scheduler.dueIds.size)
        assertNotNull(harness.store.data(AssignmentNotifier.storageKey(F.camille.id)))
        app.router.showTask(F.lilas, T.faireCourses)

        val settings = SettingsViewModel(session, harness.scope)
        assertTrue(settings.signOut())
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }
        waitUntil("session stopped") { session.isStopped }
        waitUntil("reminders removed") { harness.scheduler.dueIds.isEmpty() }
        waitUntil("realtime stopped") { harness.backend.realtimeSubscriberCount == 0 }
        waitUntil("notifier reset") { harness.store.data(AssignmentNotifier.storageKey(F.camille.id)) == null }
        assertFalse(session.isRunning)
        assertFalse(app.router.isActive)
        assertTrue(app.router.groupsPath.isEmpty())
        // A stopped session schedules nothing any more.
        assertFalse(session.synchronizeReminders())
        session.start()
        assertFalse(session.isRunning)
        app.shutdown()
    }

    @Test
    fun accountDeletionEndsTheSession() = runTest {
        val harness = VMHarness(backgroundScope)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed in") { app.session != null }
        val session = app.session!!
        session.startupJob?.join()
        val settings = SettingsViewModel(session, harness.scope)
        settings.deleteConfirmation = SettingsViewModel.DELETE_CONFIRMATION_WORD
        assertTrue(settings.deleteAccount())
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }
        waitUntil("reminders removed") { harness.scheduler.dueIds.isEmpty() }
        app.shutdown()
    }

    @Test
    fun switchingUserReplacesTheSession() = runTest {
        val harness = VMHarness(backgroundScope)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed in") { app.session != null }
        val first = app.session!!
        first.startupJob?.join()

        harness.services.auth.signIn(F.lucas.email, DemoData.password)
        waitUntil("second session") { app.session != null && app.session !== first }
        val second = app.session!!
        assertEquals(F.lucas.id, second.userId)
        assertTrue(first.isStopped)
        assertTrue(second.isRunning)
        second.startupJob?.join()
        // Lucas's reminders: « Faire les courses » and « Créer l'affiche du tournoi ».
        val expected = harness.reminderIds(listOf(T.faireCourses, T.creerAffiche))
        assertEquals(expected, harness.scheduler.dueIds)
        app.shutdown()
    }

    @Test
    fun deepLinkReceivedWhileSignedOutOpensAfterSignIn() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }
        val url = DeepLink.Task(F.lilas, T.faireCourses).url
        assertTrue(app.open(url))
        assertEquals(DeepLink.Task(F.lilas, T.faireCourses), app.router.pendingDeepLink)
        assertTrue(app.router.groupsPath.isEmpty())

        harness.services.auth.signIn(F.camille.email, DemoData.password)
        waitUntil("signed in") { app.session != null }
        assertEquals(listOf(AppRoute.Group(F.lilas), AppRoute.Task(F.lilas, T.faireCourses)), app.router.groupsPath)
        assertNull(app.router.pendingDeepLink)
        assertFalse(app.open("https://example.com"))
        app.shutdown()
    }

    @Test
    fun foregroundReloadsEverythingAndResynchronizes() = runTest {
        val harness = VMHarness(backgroundScope)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed in") { app.session != null }
        val session = app.session!!
        session.startupJob?.join()
        harness.scheduler.clearPending()
        val allRevision = session.feed.allRevision.value

        app.handleForeground()
        assertTrue(session.feed.allRevision.value > allRevision)
        assertEquals(3, harness.scheduler.dueIds.size)

        app.handleSignificantTimeChange()
        assertTrue(session.feed.allRevision.value > allRevision + 1)
        app.shutdown()
    }

    @Test
    fun backgroundRefreshWorksWithoutTheRootView() = runTest {
        val harness = VMHarness(backgroundScope)
        val app = harness.makeApp()
        // No `start()` from the UI: started in the background.
        app.handleBackgroundRefresh()
        val session = app.session
        assertNotNull(session)
        assertEquals(F.camille.id, session!!.userId)
        session.startupJob?.join()
        assertEquals(3, harness.scheduler.dueIds.size)
        // The auth stream then confirms the same user: same session.
        settle()
        assertSame(session, app.session)
        app.shutdown()
    }

    @Test
    fun backgroundRefreshNeverClearsRemindersOnFailure() = runTest {
        val harness = VMHarness(backgroundScope)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed in") { app.session != null }
        val session = app.session!!
        session.startupJob?.join()
        val before = harness.scheduler.dueIds
        assertEquals(3, before.size)

        harness.faults.fail(Op.MY_TASKS, AppError.Network)
        harness.faults.fail(Op.ASSIGNMENTS, AppError.Network)
        app.handleBackgroundRefresh()
        assertEquals(before, harness.scheduler.dueIds)
        app.shutdown()
    }

    @Test
    fun backgroundRefreshWhileSignedOutDoesNothing() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val app = harness.makeApp()
        app.handleBackgroundRefresh()
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }
        assertNull(app.session)
        assertEquals(0, harness.faults.calls(Op.MY_TASKS))
        app.shutdown()
    }

    @Test
    fun realtimeAssignmentPostsANotification() = runTest {
        val harness = VMHarness(backgroundScope)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed in") { app.session != null }
        val session = app.session!!
        session.startupJob?.join()
        waitUntil("realtime subscribed") { harness.backend.realtimeSubscriberCount == 1 }
        // The first `Connected` bumps everything.
        waitUntil("connected") { session.feed.allRevision.value >= 1 }
        val myTasksRevision = session.feed.myTasksRevision.value

        val task = harness.device(F.lucas).tasks.create(
            F.lilas,
            TaskDraft(title = "Descendre le carton", assigneeIds = setOf(F.camille.id)),
        )
        val id = AssignmentNotifier.individualIdentifier(task.id)
        waitUntil("notification") { harness.scheduler.delivered.any { it.id == id } }
        val notification = harness.scheduler.delivered.first { it.id == id }
        assertEquals("Nouvelle tâche", notification.title)
        assertEquals("Descendre le carton — Coloc' rue des Lilas", notification.body)
        assertEquals(mapOf("taskId" to task.id.uuidString, "groupId" to F.lilas.uuidString), notification.userInfo)
        waitUntil("my tasks bumped") { session.feed.myTasksRevision.value > myTasksRevision }
        waitUntil("group bumped") { session.feed.groupRevision(F.lilas) > session.feed.allRevision.value }

        // Tapping it routes to the task.
        app.router.open(DeepLink.fromNotification(notification.userInfo))
        assertEquals(listOf(AppRoute.Group(F.lilas), AppRoute.Task(F.lilas, task.id)), app.router.groupsPath)
        app.shutdown()
    }

    // region Kotlin additions

    @Test
    fun phasesAreObservable() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val app = harness.makeApp()
        app.state.test {
            assertEquals(AppPhase.Launching, awaitItem().phase)
            app.start()
            assertEquals(AppPhase.SignedOut, awaitItem().phase)
            harness.services.auth.signIn(F.camille.email, DemoData.password)
            val signedIn = awaitItem()
            assertTrue(signedIn.phase is AppPhase.SignedIn)
            assertSame(app.session, signedIn.session)
            app.shutdown()
            assertEquals(AppPhase.SignedOut, awaitItem().phase)
            cancelAndIgnoreRemainingEvents()
        }
    }

    /** The session's scope dies with it: nothing of a stopped session keeps running. */
    @Test
    fun stoppedSessionCancelsItsScope() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        session.start()
        waitUntil("subscribed") { harness.backend.realtimeSubscriberCount == 1 }
        val myTasks = session.myTasks
        session.stop()
        assertFalse(session.realtime.isRunning)
        // A load in the cancelled scope does nothing (and does not hang).
        myTasks.load()
        assertEquals(LoadState.Idle, myTasks.ui.loadState)
        waitUntil("unsubscribed") { harness.backend.realtimeSubscriberCount == 0 }
    }

    // endregion
}

/** Port of the SessionModelTests suite of ViewModels/AppModelTests.swift. */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionModelTest {
    @Test
    fun startsOnceAndSubscribesToTheUsersGroups() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        assertFalse(session.isRunning)
        session.start()
        session.start()
        assertTrue(session.isRunning)
        waitUntil("subscribed") { session.realtime.subscribedGroupIds.size == 2 }
        assertEquals(setOf(F.lilas, F.sport), session.realtime.subscribedGroupIds.toSet())
        assertEquals(1, harness.backend.realtimeSubscriberCount)
        session.startupJob?.join()
        session.stop()
        session.stop()
        assertTrue(session.isStopped)
        assertTrue(session.realtime.subscribedGroupIds.isEmpty())
        waitUntil("unsubscribed") { harness.backend.realtimeSubscriberCount == 0 }
    }

    @Test
    fun groupActivityBumpsTheFeed() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        session.start()
        waitUntil("connected") { session.feed.allRevision.value >= 1 }
        val before = session.feed.groupRevision(F.sport)
        harness.device(F.lucas).tasks.setStatus(T.creerAffiche, TaskStatus.DONE)
        waitUntil("sport bumped") { session.feed.groupRevision(F.sport) > before }
        session.stop()
    }

    /**
     * Cold start offline (the first `myGroups()` fails): the groups are subscribed as soon as the channel connects, and
     * group activity reaches the feed (review VM-1 / ADP-1).
     */
    @Test
    fun failedFirstGroupFetchIsRecovered() = runTest {
        val harness = VMHarness(backgroundScope)
        harness.faults.fail(Op.MY_GROUPS, AppError.Network)
        val session = harness.makeSession()
        session.start()
        waitUntil("subscribed to both groups") { session.realtime.subscribedGroupIds == listOf(F.lilas, F.sport) }
        assertFalse(session.realtime.groupIdsAreStale)
        session.startupJob?.join()

        val before = session.feed.groupRevision(F.sport)
        harness.device(F.lucas).tasks.setStatus(T.creerAffiche, TaskStatus.DONE)
        waitUntil("sport bumped") { session.feed.groupRevision(F.sport) > before }
        session.stop()
    }

    @Test
    fun foregroundFetchesTheRealtimeGroupIdsAgain() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        session.start()
        waitUntil("subscribed") { session.realtime.subscribedGroupIds.size == 2 }
        session.startupJob?.join()
        val calls = harness.faults.calls(Op.MY_GROUPS)
        session.handleForeground()
        waitUntil("group ids fetched again") { harness.faults.calls(Op.MY_GROUPS) > calls }
        session.stop()
    }

    @Test
    fun catchUpNotifiesAssignmentsMadeWhileAway() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        // First catch-up: history is not notified, only the cursor is set.
        session.catchUpAssignments()
        assertTrue(harness.scheduler.delivered.isEmpty())

        harness.clock.advance(300.seconds)
        val task = harness.device(F.lucas).tasks.create(
            F.sport,
            TaskDraft(title = "Acheter les ballons", assigneeIds = setOf(F.camille.id)),
        )
        harness.clock.advance(300.seconds)
        session.catchUpAssignments()
        assertEquals(listOf(AssignmentNotifier.individualIdentifier(task.id)), harness.scheduler.delivered.map { it.id })
        assertEquals("Acheter les ballons — Projet Asso Sport", harness.scheduler.delivered.first().body)

        // Nothing new: nothing posted again.
        session.catchUpAssignments()
        assertEquals(1, harness.scheduler.delivered.size)
    }

    @Test
    fun remindersFollowOnlySuccessfulLists() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        assertTrue(session.synchronizeReminders())
        assertEquals(3, harness.scheduler.dueIds.size)

        harness.faults.fail(Op.MY_TASKS, AppError.Network)
        assertFalse(session.synchronizeReminders())
        assertEquals(3, harness.scheduler.dueIds.size)

        session.synchronizeReminders(emptyList())
        assertTrue(harness.scheduler.dueIds.isEmpty())
    }

    @Test
    fun notificationAuthorizationRequest() = runTest {
        val harness = VMHarness(backgroundScope, authorization = NotificationAuthorization.NOT_DETERMINED)
        val session = harness.makeSession()
        assertEquals(NotificationAuthorization.AUTHORIZED, session.requestNotificationAuthorizationIfNeeded())
        assertEquals(1, harness.scheduler.requestCount)
        assertEquals(3, harness.scheduler.dueIds.size)

        val denied = VMHarness(backgroundScope, authorization = NotificationAuthorization.DENIED)
        val other = denied.makeSession()
        assertEquals(NotificationAuthorization.DENIED, other.requestNotificationAuthorizationIfNeeded())
        assertEquals(0, denied.scheduler.requestCount)
    }

    @Test
    fun notAuthorizedMeansNoReminders() = runTest {
        val harness = VMHarness(backgroundScope, authorization = NotificationAuthorization.DENIED)
        val session = harness.makeSession()
        assertTrue(session.synchronizeReminders())
        assertTrue(harness.scheduler.dueIds.isEmpty())
    }

    @Test
    fun foregroundIsIgnoredUntilStarted() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        session.handleForeground()
        assertEquals(0, session.feed.allRevision.value)
        assertEquals(0, harness.faults.calls(Op.MY_TASKS))
        session.handleBackgroundRefresh()
        assertEquals(1, harness.faults.calls(Op.MY_TASKS))
    }
}
