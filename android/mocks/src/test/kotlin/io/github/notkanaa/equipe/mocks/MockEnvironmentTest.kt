package io.github.notkanaa.equipe.mocks

import app.cash.turbine.test
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AuthState
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskDraft
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import kotlin.time.Duration.Companion.milliseconds

/** Port of MockEnvironmentTests.swift. */
class MockEnvironmentTest {
    private val now: Instant = TestDates.parisDate(2026, 9, 23, 10)

    @Test
    fun signedOutHasDemoDataAndNoSession() = runTest {
        val now = now
        val environment = MockEnvironment.make(MockScenario.SIGNED_OUT, now = { now })
        assertEquals(MockScenario.SIGNED_OUT, environment.scenario)
        assertNull(environment.signedInUser)
        val services = environment.services
        assertNull(services.auth.currentUser())
        services.auth.authStates().test {
            assertEquals(AuthState.SignedOut, awaitItem())
            assertThrowsAppError(AppError.NotAuthenticated) { services.groups.myGroups() }

            services.auth.signIn(DemoData.camille.email, DemoData.password)
            assertEquals(AuthState.SignedIn(AuthUser(DemoData.camille.id, DemoData.camille.email)), awaitItem())
            assertEquals(2, services.groups.myGroups().size)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun populatedIsSignedInAsCamille() = runTest {
        val environment = MockEnvironment.make(MockScenario.POPULATED)
        assertEquals(DemoData.camille, environment.signedInUser)
        val services = environment.services
        assertEquals(DemoData.camille.id, services.auth.currentUser()?.id)
        services.auth.authStates().test {
            assertEquals(DemoData.camille.id, awaitItem().user?.id)
            cancelAndIgnoreRemainingEvents()
        }
        val groups = services.groups.myGroups()
        assertEquals(listOf(DemoData.lilasGroupId, DemoData.sportGroupId), groups.map { it.id })
        assertEquals("Camille Martin", services.profiles.myProfile().displayName)
    }

    @Test
    fun emptyGroupsIsSignedInWithoutGroups() = runTest {
        val environment = MockEnvironment.make(MockScenario.EMPTY_GROUPS)
        assertEquals(DemoData.newcomer, environment.signedInUser)
        val services = environment.services
        assertEquals(DemoData.newcomer.id, services.auth.currentUser()?.id)
        assertTrue(services.groups.myGroups().isEmpty())
        assertTrue(services.tasks.myTasks(includeDone = true).isEmpty())

        val code = InviteCode.parse("lylas-234")!!
        val joined = services.groups.join(code)
        assertEquals(JoinResult(DemoData.lilasGroupId, DemoData.lilasGroupName, alreadyMember = false), joined)
        assertEquals(listOf(MemberRole.MEMBER), services.groups.myGroups().map { it.myRole })
    }

    @Test
    fun environmentsAreIndependent() = runTest {
        val first = MockEnvironment.make(MockScenario.POPULATED)
        val second = MockEnvironment.make(MockScenario.POPULATED)
        first.services.groups.createGroup("Nouveau groupe")
        assertEquals(3, first.services.groups.myGroups().size)
        assertEquals(2, second.services.groups.myGroups().size)
    }

    @Test
    fun otherDevicesShareTheBackend() = runTest {
        val environment = MockEnvironment.make(MockScenario.POPULATED)
        val lucas = environment.backend.services(DemoData.lucas.id)
        val task = lucas.tasks.create(
            DemoData.sportGroupId,
            TaskDraft(title = "Acheter des ballons", assigneeIds = setOf(DemoData.camille.id)),
        )
        val mine = environment.services.tasks.myTasks(includeDone = false)
        assertTrue(mine.any { it.id == task.id && it.groupName == DemoData.sportGroupName })
    }

    @Test
    fun parsesLaunchArguments() {
        val cases = listOf(
            listOf("App", "-uiTestMockBackend", "-mockScenario", "populated") to MockScenario.POPULATED,
            listOf("App", "-mockScenario", "emptyGroups") to MockScenario.EMPTY_GROUPS,
            listOf("App", "-mockScenario", "signedOut") to MockScenario.SIGNED_OUT,
        )
        for ((arguments, expected) in cases) {
            assertEquals("$arguments", expected, MockEnvironment.scenario(fromLaunchArguments = arguments))
        }
        assertEquals(MockScenario.entries, MockScenario.entries.map { MockScenario.fromRawValue(it.rawValue) })
    }

    @Test
    fun ignoresMissingOrUnknownScenario() {
        assertNull(MockEnvironment.scenario(fromLaunchArguments = listOf("App")))
        assertNull(MockEnvironment.scenario(fromLaunchArguments = listOf("App", "-mockScenario")))
        assertNull(MockEnvironment.scenario(fromLaunchArguments = listOf("App", "-mockScenario", "inconnu")))
    }

    /** Real time: the artificial latency is a coroutine `delay`. */
    @Test
    fun artificialLatencyStillAnswers() = runBlocking {
        val environment = MockEnvironment.make(MockScenario.POPULATED, latency = 5.milliseconds)
        val start = System.nanoTime()
        val groups = environment.services.groups.myGroups()
        assertEquals(2, groups.size)
        assertTrue((System.nanoTime() - start) >= 4_000_000L) // lower bound only: never flaky
    }
}
