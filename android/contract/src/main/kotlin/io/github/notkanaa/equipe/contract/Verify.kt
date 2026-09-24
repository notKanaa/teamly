package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.AppError
import kotlin.coroutines.cancellation.CancellationException

/**
 * A failed contract expectation. [location] is the scenario source line that raised it (`File.kt:line`, best effort
 * from the stack trace: the first frame outside the helpers of this package), like Swift's `#fileID:#line`.
 */
class ContractFailure(override val message: String) : Exception(message) {
    val location: String by lazy { callSite(stackTrace) }

    /** `message (location)`. */
    val description: String get() = "$message ($location)"

    override fun toString(): String = description

    private companion object {
        private val helperClasses = listOf(
            ContractFailure::class.java.name,
            Verify::class.java.name,
            StreamProbe::class.java.name,
            RealtimeProbe::class.java.name,
        )

        fun callSite(frames: Array<StackTraceElement>): String {
            val frame = frames.firstOrNull { frame ->
                frame.fileName != null && frame.lineNumber > 0 &&
                    frame.className.startsWith("io.github.notkanaa.equipe.") &&
                    helperClasses.none { frame.className == it || frame.className.startsWith("$it$") }
            }
            return if (frame == null) "?" else "${frame.fileName}:${frame.lineNumber}"
        }
    }
}

/** Tiny assertion helpers that throw descriptive [ContractFailure]s (no dependency on a test framework). */
object Verify {
    fun that(condition: Boolean, message: String) {
        if (!condition) throw ContractFailure(message)
    }

    fun <T> equal(actual: T, expected: T, message: String) {
        if (actual != expected) throw ContractFailure("$message: expected $expected, got $actual")
    }

    fun <T : Any> unwrap(value: T?, message: String): T = value ?: throw ContractFailure("$message: unexpected null")

    /** Expects [body] to throw exactly [expected]. */
    suspend fun fails(expected: AppError, message: String, body: suspend () -> Any?) {
        failsWithAnyOf(setOf(expected), message, body)
    }

    /** Expects [body] to throw one of [expected]. */
    suspend fun failsWithAnyOf(expected: Set<AppError>, message: String, body: suspend () -> Any?) {
        val wanted = expected.map { "$it" }.sorted().joinToString(" | ")
        val value = try {
            body()
        } catch (error: ContractFailure) {
            throw error
        } catch (error: CancellationException) {
            throw error
        } catch (error: AppError) {
            if (error !in expected) throw ContractFailure("$message: expected error $wanted, got $error")
            return
        } catch (error: Throwable) {
            throw ContractFailure("$message: expected error $wanted, got non-AppError $error")
        }
        throw ContractFailure("$message: expected error $wanted, got success $value")
    }

    /** Non-members see nothing: an empty result (RLS), never an error (lead decision). */
    suspend fun hidden(message: String, body: suspend () -> Collection<*>) {
        val result = try {
            body()
        } catch (error: ContractFailure) {
            throw error
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            throw ContractFailure("$message: expected an empty result, got error $error")
        }
        if (result.isNotEmpty()) throw ContractFailure("$message: expected nothing visible, got $result")
    }

    /** Runs a setup/action step and labels any unexpected error with [label]. */
    suspend fun <T> step(label: String, body: suspend () -> T): T = try {
        body()
    } catch (error: ContractFailure) {
        throw error
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        throw ContractFailure("$label failed: $error")
    }
}
