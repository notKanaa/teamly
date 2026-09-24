package io.github.notkanaa.equipe.core.viewmodel

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.coroutines.cancellation.CancellationException

/**
 * Kotlin-specific checks of [LoadRunner] and [BackgroundWork] (the Swift suites exercise them through the view models
 * only): coalescing, at most one extra run, independence from the callers' cancellation, spurious cancellations.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class LoadRunnerTest {
    @Test
    fun concurrentCallsCoalesceIntoAtMostOneExtraRun() = runTest {
        val runner = LoadRunner(backgroundScope)
        var runs = 0
        val gate = CompletableDeferred<Unit>()
        val operation: suspend () -> Unit = {
            runs += 1
            if (runs == 1) gate.await()
        }
        val first = launch { runner.run(rerunIfRunning = false, operation) }
        runCurrent()
        assertTrue(runner.isRunning)
        val joiners = List(3) { launch { runner.run(rerunIfRunning = true, operation) } }
        val plain = launch { runner.run(rerunIfRunning = false, operation) }
        runCurrent()
        gate.complete(Unit)
        (joiners + first + plain).forEach { it.join() }
        assertEquals(2, runs)
        assertFalse(runner.isRunning)

        // Idle again: a new call starts a new run.
        runner.run(rerunIfRunning = false, operation)
        assertEquals(3, runs)
    }

    @Test
    fun cancellingEveryCallerKeepsTheRunGoing() = runTest {
        val runner = LoadRunner(backgroundScope)
        val gate = CompletableDeferred<Unit>()
        var finished = false
        val callers = List(2) {
            launch {
                runner.run(rerunIfRunning = false) {
                    gate.await()
                    finished = true
                }
            }
        }
        runCurrent()
        callers.forEach { it.cancel() }
        runCurrent()
        assertTrue(runner.isRunning)
        gate.complete(Unit)
        runner.wait()
        assertTrue(finished)
        assertFalse(runner.isRunning)
    }

    @Test
    fun spuriousCancellationEndsTheRunLikeAReturn() = runTest {
        val runner = LoadRunner(backgroundScope)
        var runs = 0
        runner.run(rerunIfRunning = false) {
            runs += 1
            throw CancellationException("annulé par le service")
        }
        assertEquals(1, runs)
        assertFalse(runner.isRunning)
        runner.run(rerunIfRunning = false) { runs += 1 }
        assertEquals(2, runs)
    }

    @Test
    fun cancelledScopeRunsNothingAndStaysUsable() = runTest {
        val scope = CoroutineScope(backgroundScope.coroutineContext + Job(backgroundScope.coroutineContext[Job]))
        val runner = LoadRunner(scope)
        scope.cancel()
        var runs = 0
        runner.run(rerunIfRunning = true) { runs += 1 }
        assertEquals(0, runs)
        assertFalse(runner.isRunning)
    }

    @Test
    fun backgroundWorkCanBeAwaitedAndCancelled() = runTest {
        val work = BackgroundWork(backgroundScope)
        var done = 0
        work.start { done += 1 }
        work.start { done += 1 }
        work.waitForAll()
        assertEquals(2, done)

        val gate = CompletableDeferred<Unit>()
        work.start {
            gate.await()
            done += 1
        }
        runCurrent()
        work.cancelAll()
        gate.complete(Unit)
        work.waitForAll()
        runCurrent()
        assertEquals(2, done)
    }
}
