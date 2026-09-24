package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.NowProvider
import java.time.Instant
import kotlin.time.Duration
import kotlin.time.toJavaDuration

/**
 * Controllable clock for tests, previews and UI tests (port of Swift `MockClock`). Thread-safe.
 *
 * `autoAdvance` is added after every [now] read so that successive backend operations get strictly increasing
 * timestamps (like successive Postgres transactions), while staying fully deterministic.
 */
class MockClock(start: Instant, autoAdvance: Duration = Duration.ZERO) {
    private val lock = Any()
    private val step: java.time.Duration = autoAdvance.toJavaDuration()
    private var current: Instant = start

    /** Returns the current date, then advances by `autoAdvance`. */
    fun now(): Instant = synchronized(lock) {
        val value = current
        current = current.plus(step)
        value
    }

    /** The current date, without advancing. */
    fun peek(): Instant = synchronized(lock) { current }

    /** Moves the clock forward (backward with a negative [duration]). */
    fun advance(duration: Duration) {
        val delta = duration.toJavaDuration()
        synchronized(lock) { current = current.plus(delta) }
    }

    fun set(date: Instant) {
        synchronized(lock) { current = date }
    }

    /** A [NowProvider] reading this clock (each call advances by `autoAdvance`). */
    val provider: NowProvider get() = { now() }
}
