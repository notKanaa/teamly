package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.AppError
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds

/** The assertion helpers of the scenarios: exact errors, descriptive failures, bounded waits. */
class VerifyTest {
    private suspend fun failure(body: suspend () -> Unit): ContractFailure {
        try {
            body()
        } catch (error: ContractFailure) {
            return error
        }
        fail("expected a ContractFailure")
        throw AssertionError()
    }

    @Test
    fun failsAcceptsOnlyTheExpectedAppError() = runBlocking {
        Verify.fails(AppError.Forbidden, "forbidden") { throw AppError.Forbidden }
        Verify.failsWithAnyOf(setOf(AppError.NotFound, AppError.Forbidden), "either") { throw AppError.NotFound }

        val success = failure { Verify.fails(AppError.Forbidden, "success") { 42 } }
        assertEquals("success: expected error Forbidden, got success 42", success.message)
        val wrong = failure { Verify.fails(AppError.Forbidden, "wrong") { throw AppError.NotFound } }
        assertEquals("wrong: expected error Forbidden, got NotFound", wrong.message)
        val other = failure { Verify.fails(AppError.Forbidden, "other") { throw IllegalStateException("boom") } }
        assertTrue(other.message, other.message.startsWith("other: expected error Forbidden, got non-AppError"))
    }

    @Test
    fun hiddenExpectsAnEmptyResultAndNoError() = runBlocking {
        Verify.hidden("empty") { emptyList<Int>() }
        val visible = failure { Verify.hidden("visible") { listOf(1) } }
        assertEquals("visible: expected nothing visible, got [1]", visible.message)
        val error = failure { Verify.hidden("error") { throw AppError.Forbidden } }
        assertEquals("error: expected an empty result, got error Forbidden", error.message)
    }

    @Test
    fun stepLabelsUnexpectedErrorsAndKeepsContractFailures() = runBlocking {
        assertEquals(3, Verify.step("value") { 3 })
        val labelled = failure { Verify.step("create") { throw AppError.InvalidTitle } }
        assertEquals("create failed: InvalidTitle", labelled.message)
        val nested = failure { Verify.step("outer") { Verify.that(false, "inner") } }
        assertEquals("inner", nested.message)
    }

    @Test
    fun equalAndUnwrapDescribeTheMismatch() {
        Verify.equal(listOf(1, 2), listOf(1, 2), "same")
        try {
            Verify.equal(1, 2, "numbers")
            fail("expected a ContractFailure")
        } catch (error: ContractFailure) {
            assertEquals("numbers: expected 2, got 1", error.message)
            // The location is the caller's line (like Swift's #fileID:#line), not a helper's.
            assertTrue(error.description, error.location.startsWith("VerifyTest.kt:"))
            assertEquals("${error.message} (${error.location})", error.description)
        }
        assertEquals("x", Verify.unwrap("x", "value"))
        try {
            Verify.unwrap(null as String?, "value")
            fail("expected a ContractFailure")
        } catch (error: ContractFailure) {
            assertEquals("value: unexpected null", error.message)
        }
    }

    @Test
    fun streamProbeRecordsAndWaitsWithABound() = runBlocking {
        val probe = StreamProbe(flowOf(1, 2, 3))
        try {
            assertEquals(IndexedValue(1, 2), probe.waitFor("two") { it == 2 })
            assertEquals(listOf(1, 2, 3), probe.events)
            assertEquals(3, probe.mark())
            val timeout = failure { probe.waitFor("two again", after = 2, timeout = 50.milliseconds) { it == 2 } }
            assertTrue(timeout.message, timeout.message.startsWith("timed out after 50ms waiting for two again"))
        } finally {
            probe.stop()
        }
    }

    @Test
    fun streamProbeSubscribesBeforeTheConstructorReturns() = runBlocking {
        val flow = MutableSharedFlow<String>()
        val probe = StreamProbe(flow)
        try {
            // A hot flow without replay: only a subscriber that exists now receives the element.
            assertEquals(1, flow.subscriptionCount.value)
            flow.emit("event")
            assertEquals(IndexedValue(0, "event"), probe.waitFor("the event") { true })
        } finally {
            probe.stop()
        }
    }
}
