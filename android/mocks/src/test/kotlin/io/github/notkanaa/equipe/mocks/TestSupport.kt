package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.contract.ContractHarness
import io.github.notkanaa.equipe.contract.ContractUser
import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.SignUpOutcome
import io.github.notkanaa.equipe.core.uuidString
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import java.io.File
import java.time.Instant
import java.time.ZonedDateTime
import java.util.UUID
import kotlin.time.Duration.Companion.milliseconds

/** Asserts that [block] throws exactly [expected] (Swift Testing's `await #expect(throws: AppError.x)`). */
suspend fun assertThrowsAppError(expected: AppError, message: String = "", block: suspend () -> Unit) {
    try {
        block()
    } catch (error: AppError) {
        assertEquals(message, expected, error)
        return
    }
    fail("$message: expected $expected to be thrown")
}

/** Shared dates of the mock tests. */
object TestDates {
    /** 2026-09-23T08:00:00Z (10:00 in Paris), the start of the injected clocks. */
    val start: Instant = Instant.ofEpochSecond(1_790_150_400L)

    /** A wall-clock time in Europe/Paris. */
    fun parisDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0): Instant =
        ZonedDateTime.of(year, month, day, hour, minute, 0, 0, AppCalendar.PARIS).toInstant()
}

/** A file of the repository (e.g. `supabase/seed.sql`), found from the working directory (the module) upwards. */
fun repositoryFile(relativePath: String): File {
    var directory: File? = File(System.getProperty("user.dir")).absoluteFile
    while (directory != null) {
        val candidate = File(directory, relativePath)
        if (candidate.isFile) return candidate
        directory = directory.parentFile
    }
    throw AssertionError("$relativePath not found above ${System.getProperty("user.dir")}")
}

/**
 * Runs the backend-agnostic scenarios against a fresh in-memory backend (port of the Swift `MockHarness`).
 * The clock advances 1 ms per read so successive operations get strictly increasing timestamps, like successive
 * Postgres transactions, while staying deterministic.
 */
class MockHarness : ContractHarness {
    val backend: InMemoryBackend = InMemoryBackend(now = MockClock(TestDates.start, autoAdvance = 1.milliseconds).provider)

    override suspend fun makeUser(displayName: String): ContractUser {
        val email = "contrat-${UUID.randomUUID().uuidString.take(12).lowercase()}@example.com"
        val password = "motdepasse123"
        val services = backend.services(null)
        val outcome = services.auth.signUp(email, password, displayName)
        val user = services.auth.currentUser()
        if (outcome != SignUpOutcome.SIGNED_IN || user == null) throw AppError.NotAuthenticated
        return ContractUser(user, displayName, email, password, services)
    }
}

/** Returns the same account for every `makeUser` call: "another" user joining a group is already a member. */
class SameUserHarness : ContractHarness {
    private val user: ContractUser

    init {
        val backend = InMemoryBackend()
        val email = "partage@example.com"
        val account = backend.createAccount(email, "motdepasse123", "Partagé")
        user = ContractUser(account, "Partagé", email, "motdepasse123", backend.services(account.id))
    }

    override suspend fun makeUser(displayName: String): ContractUser = user
}
