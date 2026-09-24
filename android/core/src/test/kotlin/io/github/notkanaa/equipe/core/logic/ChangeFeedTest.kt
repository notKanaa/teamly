package io.github.notkanaa.equipe.core.logic

import app.cash.turbine.test
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.UUID
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F

/** Port of the ChangeFeedTests suite of Logic/RealtimeCoordinatorTests.swift (Observation → StateFlow). */
class ChangeFeedTest {
    @Test
    fun startsAtZero() {
        val feed = ChangeFeed()
        assertEquals(0, feed.membershipsRevision.value)
        assertEquals(0, feed.myTasksRevision.value)
        assertEquals(0, feed.allRevision.value)
        assertEquals(0, feed.groupRevision(F.groupA))
        assertEquals(emptyMap<UUID, Int>(), feed.groupRevisions.value)
    }

    @Test
    fun groupBumpsAreIndependent() {
        val feed = ChangeFeed()
        feed.bump(F.groupA)
        feed.bump(F.groupA)
        assertEquals(2, feed.groupRevision(F.groupA))
        assertEquals(0, feed.groupRevision(F.groupB))
        assertEquals(0, feed.membershipsRevision.value)
        assertEquals(0, feed.myTasksRevision.value)
        assertEquals(mapOf(F.groupA to 2), feed.groupRevisions.value)
    }

    @Test
    fun individualCounters() {
        val feed = ChangeFeed()
        feed.bumpMemberships()
        assertEquals(1, feed.membershipsRevision.value)
        assertEquals(0, feed.myTasksRevision.value)
        feed.bumpMyTasks()
        feed.bumpMyTasks()
        assertEquals(2, feed.myTasksRevision.value)
        assertEquals(0, feed.groupRevision(F.groupA))
    }

    @Test
    fun bumpAllChangesEveryRevisionIncludingUnknownGroups() {
        val feed = ChangeFeed()
        feed.bump(F.groupA)
        val beforeA = feed.groupRevision(F.groupA)
        val beforeB = feed.groupRevision(F.groupB)
        val beforeMemberships = feed.membershipsRevision.value
        val beforeMyTasks = feed.myTasksRevision.value
        feed.bumpAll()
        assertEquals(beforeA + 1, feed.groupRevision(F.groupA))
        assertEquals(beforeB + 1, feed.groupRevision(F.groupB))
        assertEquals(1, feed.groupRevision(UUID.randomUUID()))
        assertEquals(beforeMemberships + 1, feed.membershipsRevision.value)
        assertEquals(beforeMyTasks + 1, feed.myTasksRevision.value)
    }

    @Test
    fun revisionsAreObservable() = runTest {
        val feed = ChangeFeed()
        feed.groupRevisionFlow(F.groupA).test {
            assertEquals(0, awaitItem())
            feed.bumpMyTasks()
            feed.bump(F.groupB)
            feed.bumpAll()
            // Neither "Mes tâches" nor another group changes group A's revision: the next value comes from bumpAll.
            assertEquals(1, awaitItem())
            feed.bump(F.groupA)
            assertEquals(2, awaitItem())
            expectNoEvents()
        }
        // So far: my tasks bumped once + bumpAll, memberships by bumpAll only.
        feed.myTasksRevision.test {
            assertEquals(2, awaitItem())
            feed.bumpMyTasks()
            assertEquals(3, awaitItem())
            feed.bumpAll()
            assertEquals(4, awaitItem())
        }
        feed.membershipsRevision.test {
            assertEquals(2, awaitItem())
            feed.bumpMemberships()
            assertEquals(3, awaitItem())
        }
        feed.allRevision.test {
            assertEquals(2, awaitItem())
        }
    }

    /** Thread-safe: concurrent bumps are never lost. */
    @Test
    fun concurrentBumpsAreAllCounted() = runBlocking {
        val feed = ChangeFeed()
        (1..8).map {
            async(Dispatchers.Default) {
                repeat(500) {
                    feed.bump(F.groupA)
                    feed.bump(F.groupB)
                    feed.bumpMyTasks()
                }
            }
        }.awaitAll()
        assertEquals(4_000, feed.groupRevision(F.groupA))
        assertEquals(4_000, feed.groupRevision(F.groupB))
        assertEquals(4_000, feed.myTasksRevision.value)
    }
}
