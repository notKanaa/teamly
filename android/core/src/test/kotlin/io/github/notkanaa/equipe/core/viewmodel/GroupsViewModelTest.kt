package io.github.notkanaa.equipe.core.viewmodel

import app.cash.turbine.test
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.mocks.InMemoryBackend
import io.github.notkanaa.equipe.mocks.MockScenario
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.coroutines.cancellation.CancellationException
import io.github.notkanaa.equipe.core.viewmodel.VMFaults.Op
import io.github.notkanaa.equipe.core.viewmodel.VMFixtures as F

/** Port of the GroupsListViewModelTests suite of ViewModels/GroupsViewModelTests.swift. */
@OptIn(ExperimentalCoroutinesApi::class)
class GroupsListViewModelTest {
    @Test
    fun loadsTheGroupsOnce() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupsListViewModel(harness.makeSession(), harness.scope)
        assertEquals(LoadState.Idle, model.ui.loadState)
        model.load()
        assertEquals(LoadState.Loaded, model.ui.loadState)
        assertEquals(listOf(F.lilas, F.sport), model.ui.groups.map { it.id })
        assertEquals(listOf(MemberRole.ADMIN, MemberRole.MEMBER), model.ui.groups.map { it.myRole })
        assertFalse(model.ui.isEmpty)
        assertFalse(model.needsRefresh)

        // Idempotent: the key changed (groups listed) but nothing new happened.
        model.load()
        model.load()
        assertEquals(1, harness.faults.calls(Op.MY_GROUPS))
    }

    @Test
    fun emptyState() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.EMPTY_GROUPS)
        val model = GroupsListViewModel(harness.makeSession(), harness.scope)
        model.load()
        assertTrue(model.ui.isEmpty)
        assertTrue(GroupsListViewModel.EMPTY_MESSAGE.contains("code d’invitation"))
    }

    @Test
    fun reloadsOnMembershipsAndGroupActivity() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = GroupsListViewModel(session, harness.scope)
        model.load()
        val key = model.refreshKey

        // Lucas renames a group on another device; the realtime signal bumps that group's revision.
        harness.device(F.lucas).groups.rename(F.sport, "Asso Sport")
        session.feed.bump(F.sport)
        assertNotEquals(key, model.refreshKey)
        assertTrue(model.needsRefresh)
        model.load()
        assertEquals(2, harness.faults.calls(Op.MY_GROUPS))
        assertTrue(model.ui.groups.any { it.group.name == "Asso Sport" })

        // A membership change (here a group created elsewhere) reloads too.
        harness.device(F.camille).groups.createGroup("Vacances")
        session.feed.bumpMemberships()
        model.load()
        assertEquals(3, model.ui.groups.size)
        assertEquals(3, harness.faults.calls(Op.MY_GROUPS))
        // The new group in the list changes the key but does not trigger another fetch.
        model.load()
        assertEquals(3, harness.faults.calls(Op.MY_GROUPS))
        assertFalse(model.needsRefresh)
    }

    @Test
    fun firstLoadFailureThenRetry() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupsListViewModel(harness.makeSession(), harness.scope)
        harness.faults.fail(Op.MY_GROUPS, AppError.Network)
        model.load()
        assertEquals(LoadState.Failed(AppError.Network.messageFR), model.ui.loadState)
        assertNull(model.error)
        model.reload()
        assertEquals(LoadState.Loaded, model.ui.loadState)
        assertEquals(2, model.ui.groups.size)
    }

    @Test
    fun laterFailureKeepsTheContent() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupsListViewModel(harness.makeSession(), harness.scope)
        model.load()
        harness.faults.fail(Op.MY_GROUPS, AppError.Network)
        model.reload()
        assertEquals(LoadState.Loaded, model.ui.loadState)
        assertEquals(2, model.ui.groups.size)
        assertEquals(AppError.Network.messageFR, model.errorMessage)
    }

    @Test
    fun cancellationIsIgnored() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupsListViewModel(harness.makeSession(), harness.scope)
        harness.faults.fail(Op.MY_GROUPS, CancellationException())
        model.load()
        assertEquals(LoadState.Idle, model.ui.loadState)
        assertNull(model.error)
        harness.faults.fail(Op.MY_GROUPS, AppError.wrap(CancellationException()))
        model.load()
        assertEquals(LoadState.Idle, model.ui.loadState)
        assertNull(model.error)
        model.load()
        assertEquals(LoadState.Loaded, model.ui.loadState)
    }

    @Test
    fun concurrentLoadsShareOneFetch() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupsListViewModel(harness.makeSession(), harness.scope)
        harness.faults.hold(Op.MY_GROUPS)
        val first = launch { model.load() }
        val second = launch { model.load() }
        waitUntil("fetch started") { harness.faults.waiting(Op.MY_GROUPS) == 1 }
        assertEquals(LoadState.Loading, model.ui.loadState)
        settle()
        harness.faults.release(Op.MY_GROUPS)
        first.join()
        second.join()
        assertEquals(1, harness.faults.calls(Op.MY_GROUPS))
        assertEquals(LoadState.Loaded, model.ui.loadState)
    }

    @Test
    fun reloadDuringAFetchRunsOnceMore() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupsListViewModel(harness.makeSession(), harness.scope)
        harness.faults.hold(Op.MY_GROUPS)
        val first = launch { model.load() }
        waitUntil("fetch started") { harness.faults.waiting(Op.MY_GROUPS) == 1 }
        val pull = launch { model.reload() }
        val pullAgain = launch { model.reload() }
        settle()
        harness.faults.release(Op.MY_GROUPS)
        first.join()
        pull.join()
        pullAgain.join()
        assertEquals(2, harness.faults.calls(Op.MY_GROUPS))
    }

    @Test
    fun cancellingTheCallerDoesNotCancelTheFetch() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupsListViewModel(harness.makeSession(), harness.scope)
        harness.faults.hold(Op.MY_GROUPS)
        val caller = launch { model.load() }
        waitUntil("fetch started") { harness.faults.waiting(Op.MY_GROUPS) == 1 }
        caller.cancel()
        settle()
        harness.faults.release(Op.MY_GROUPS)
        caller.join()
        waitUntil("fetch finished") { model.ui.loadState == LoadState.Loaded }
        assertNull(model.error)
        assertEquals(2, model.ui.groups.size)
    }

    // region Kotlin additions: observation

    @Test
    fun refreshKeysFollowTheFeedAndTheListedGroups() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = GroupsListViewModel(session, harness.scope)
        model.refreshKeys.test {
            assertEquals(RefreshKey(0), awaitItem())
            model.load()
            // Two groups listed, both at revision 0: same key, no emission.
            expectNoEvents()
            session.feed.bump(F.sport)
            assertEquals(RefreshKey(1), awaitItem())
            session.feed.bumpMemberships()
            assertEquals(RefreshKey(2), awaitItem())
            assertEquals(RefreshKey(2), model.refreshKey)
            cancelAndIgnoreRemainingEvents()
        }
        // bumpAll changes the memberships and every listed group: 2 + (1 + 0) + (1 + 1) = 5.
        session.feed.bumpAll()
        assertEquals(RefreshKey(5), model.refreshKey)
        assertTrue(model.needsRefresh)
    }

    @Test
    fun autoRefreshLoadsThenFollowsTheSignals() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = GroupsListViewModel(session, harness.scope)
        val observer = backgroundScope.launch { model.autoRefresh() }
        runCurrent()
        assertEquals(LoadState.Loaded, model.ui.loadState)
        assertEquals(1, harness.faults.calls(Op.MY_GROUPS))

        harness.device(F.lucas).groups.rename(F.sport, "Asso Sport")
        session.feed.bump(F.sport)
        runCurrent()
        assertEquals(2, harness.faults.calls(Op.MY_GROUPS))
        assertTrue(model.ui.groups.any { it.group.name == "Asso Sport" })

        // A signal while a fetch is held: the fetch goes on, one more run follows.
        harness.faults.hold(Op.MY_GROUPS)
        session.feed.bumpMemberships()
        waitUntil("fetch started") { harness.faults.waiting(Op.MY_GROUPS) == 1 }
        session.feed.bumpMemberships()
        settle()
        harness.faults.release(Op.MY_GROUPS)
        waitUntil("rerun done") { harness.faults.calls(Op.MY_GROUPS) == 4 && !model.needsRefresh }
        observer.cancel()
    }

    @Test
    fun stateEmitsLoadingThenLoaded() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = GroupsListViewModel(harness.makeSession(), harness.scope)
        harness.faults.hold(Op.MY_GROUPS)
        model.state.test {
            assertEquals(LoadState.Idle, awaitItem().loadState)
            val loader = launch { model.load() }
            assertEquals(LoadState.Loading, awaitItem().loadState)
            harness.faults.release(Op.MY_GROUPS)
            val loaded = awaitItem()
            assertEquals(LoadState.Loaded, loaded.loadState)
            assertEquals(2, loaded.groups.size)
            loader.join()
            cancelAndIgnoreRemainingEvents()
        }
    }

    // endregion
}

/** Port of the CreateGroupViewModelTests suite of ViewModels/GroupsViewModelTests.swift. */
class CreateGroupViewModelTest {
    @Test
    fun validatesTheName() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = CreateGroupViewModel(harness.makeSession())
        assertFalse(model.ui.canSubmit)
        model.name = "   "
        assertFalse(model.ui.canSubmit)
        model.name = "x".repeat(61)
        assertTrue(model.ui.canSubmit)
        assertNull(model.create())
        assertEquals("Le nom du groupe doit contenir entre 1 et 60 caractères.", model.ui.nameError)
        assertEquals(0, harness.faults.calls(Op.CREATE_GROUP))
        model.name = "Vacances 2027"
        assertNull(model.ui.nameError)
    }

    @Test
    fun createsTheGroupAsAdmin() = runTest {
        val harness = VMHarness(backgroundScope)
        val session = harness.makeSession()
        val model = CreateGroupViewModel(session)
        model.name = "  Vacances 2027 "
        val revision = session.feed.membershipsRevision.value
        val group = model.create()
        assertNotNull(group)
        assertEquals("Vacances 2027", group!!.group.name)
        assertEquals(MemberRole.ADMIN, group.myRole)
        assertEquals(group, model.ui.createdGroup)
        assertEquals(revision + 1, session.feed.membershipsRevision.value)
        assertEquals(3, harness.services.groups.myGroups().size)
    }

    @Test
    fun serverErrorsAreShown() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = CreateGroupViewModel(harness.makeSession())
        model.name = "Vacances"
        harness.faults.fail(Op.CREATE_GROUP, AppError.Network)
        assertNull(model.create())
        assertEquals(AppError.Network.messageFR, model.errorMessage)
        harness.faults.fail(Op.CREATE_GROUP, AppError.InvalidName)
        assertNull(model.create())
        assertEquals(AppError.InvalidName.messageFR, model.ui.nameError)
    }
}

/** Port of the JoinGroupViewModelTests suite of ViewModels/GroupsViewModelTests.swift. */
class JoinGroupViewModelTest {
    @Test
    fun formatsTheCodeLive() {
        val cases = listOf(
            "" to "",
            "abcd" to "ABCD",
            "abcde" to "ABCD-E",
            "lylas234" to "LYLA-S234",
            " ly-las 234 xyz" to "LYLA-S234",
            "LYLA-" to "LYLA",
            "straße" to "STRA-SSE",
            "é!?" to "",
        )
        for ((input, expected) in cases) {
            assertEquals(input, expected, JoinGroupViewModel.format(input))
        }
    }

    @Test
    fun codeFieldIsFormatted() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.EMPTY_GROUPS)
        val model = JoinGroupViewModel(harness.makeSession())
        model.code = "lylas23"
        assertEquals("LYLA-S23", model.code)
        assertFalse(model.ui.isCodeComplete)
        assertFalse(model.ui.canSubmit)
        model.code = "lylas2345"
        assertEquals("LYLA-S234", model.code)
        assertTrue(model.ui.isCodeComplete)
        assertTrue(model.ui.canSubmit)
    }

    @Test
    fun joinsAGroup() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.EMPTY_GROUPS)
        val session = harness.makeSession()
        val model = JoinGroupViewModel(session, code = "lylas234")
        val revision = session.feed.membershipsRevision.value
        val result = model.join()
        assertNotNull(result)
        assertEquals(F.lilas, result!!.groupId)
        assertFalse(result.alreadyMember)
        assertEquals("Vous avez rejoint « Coloc' rue des Lilas ».", model.ui.resultMessage)
        assertEquals(revision + 1, session.feed.membershipsRevision.value)
        assertEquals(listOf(F.lilas), harness.services.groups.myGroups().map { it.id })
    }

    @Test
    fun alreadyMemberIsASuccess() = runTest {
        val harness = VMHarness(backgroundScope)
        val model = JoinGroupViewModel(harness.makeSession(), code = "LYLA-S234")
        val result = model.join()
        assertNotNull(result)
        assertTrue(result!!.alreadyMember)
        assertEquals("Vous faites déjà partie de « Coloc' rue des Lilas ».", model.ui.resultMessage)
        assertNull(model.error)
    }

    @Test
    fun invalidCodes() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.EMPTY_GROUPS)
        val model = JoinGroupViewModel(harness.makeSession())

        model.code = "ABC"
        assertNull(model.join())
        assertEquals(JoinGroupViewModel.INCOMPLETE_CODE_MESSAGE, model.errorMessage)

        // 0 is not in the alphabet: refused locally.
        model.code = "ABCD-EFG0"
        assertNull(model.join())
        assertEquals("Code d’invitation invalide.", model.errorMessage)
        assertEquals(0, harness.faults.calls(Op.JOIN))

        // Well-formed but unknown: refused by the server.
        model.code = "ABCD-EFGH"
        assertNull(model.join())
        assertEquals("Code d’invitation invalide.", model.errorMessage)
        assertEquals(1, harness.faults.calls(Op.JOIN))
        assertNull(model.ui.result)
    }

    @Test
    fun rateLimited() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.EMPTY_GROUPS)
        val model = JoinGroupViewModel(harness.makeSession(), code = "ABCD-EFGH")
        repeat(InMemoryBackend.maxFailedJoinsPerHour) { model.join() }
        model.code = "LYLA-S234"
        assertNull(model.join())
        assertEquals("Trop de tentatives. Réessayez dans une heure.", model.errorMessage)
    }
}
