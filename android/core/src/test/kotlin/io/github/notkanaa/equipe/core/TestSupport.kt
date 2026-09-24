package io.github.notkanaa.equipe.core

import org.junit.Assert.assertEquals
import org.junit.Assert.fail

/** Asserts that [block] throws exactly [expected] (Swift Testing's `#expect(throws: AppError.x)`). */
fun assertThrowsAppError(expected: AppError, message: String = "", block: () -> Unit) {
    try {
        block()
    } catch (error: AppError) {
        assertEquals(message, expected, error)
        return
    }
    fail("$message: expected $expected to be thrown")
}
