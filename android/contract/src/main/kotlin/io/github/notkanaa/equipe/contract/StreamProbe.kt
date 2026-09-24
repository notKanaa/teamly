package io.github.notkanaa.equipe.contract

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.CoroutineContext
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * Collects a [Flow] in the background and records its elements, so a scenario can wait (with a bound) for an element
 * matching a predicate. Port of Swift `StreamProbe`. Call [stop] when done (there is no deinit on the JVM).
 *
 * Collection starts immediately (undispatched, up to its first suspension), so a cold flow that subscribes when
 * collected is subscribed when the constructor returns; it then continues on [context] (the default dispatcher).
 * Waits use the wall clock, even when called from a test dispatcher with virtual time.
 */
class StreamProbe<T>(flow: Flow<T>, context: CoroutineContext = Dispatchers.Default) {
    private val scope = CoroutineScope(SupervisorJob() + context)
    private val received = MutableStateFlow<List<T>>(emptyList())

    init {
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            flow.collect { element -> received.update { it + element } }
        }
    }

    /** Stops collecting (cancels the subscription). */
    fun stop() {
        scope.cancel()
    }

    /** Everything received so far. */
    val events: List<T> get() = received.value

    /** Position to pass as `after` to only consider elements received from now on. */
    fun mark(): Int = received.value.size

    /**
     * Waits until an element at index ≥ [after] matches [predicate]; throws [ContractFailure] on timeout.
     * The default bound suits real servers (Realtime can take a moment); in-memory backends answer at once.
     */
    suspend fun waitFor(
        description: String,
        after: Int = 0,
        timeout: Duration = 10.seconds,
        predicate: (T) -> Boolean,
    ): IndexedValue<T> {
        val match = withContext(Dispatchers.Default) {
            withTimeoutOrNull(timeout) {
                received.first { firstMatch(it, after, predicate) != null }.let { firstMatch(it, after, predicate) }
            }
        }
        return match ?: throw ContractFailure(
            "timed out after $timeout waiting for $description; received: ${received.value}",
        )
    }

    private fun firstMatch(elements: List<T>, after: Int, predicate: (T) -> Boolean): IndexedValue<T>? {
        for (index in after.coerceAtLeast(0) until elements.size) {
            if (predicate(elements[index])) return IndexedValue(index, elements[index])
        }
        return null
    }
}
