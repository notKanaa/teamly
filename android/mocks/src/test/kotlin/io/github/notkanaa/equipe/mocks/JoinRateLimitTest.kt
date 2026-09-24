package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.InviteCode
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * `join_group_by_code`: once the caller has 10 failed attempts in the last hour (`attempted_at >= now() - 1 h`), every
 * further attempt → `RateLimited` (too slow to test on a real server, so it is only covered here). Failed attempts are
 * logged even though `InvalidCode` is thrown. Port of JoinRateLimitTests.swift.
 */
class JoinRateLimitTest {
    private val clock = MockClock(TestDates.start)
    private val lilas = InviteCode.parse(DemoData.lilasInviteCode)!!
    private val unknown = InviteCode.parse("ZZZZ2222")!!

    private fun newcomer(backend: InMemoryBackend): AppServices {
        val user = backend.createAccount("nouveau@example.com", "motdepasse123", "Nouveau")
        return backend.services(user.id)
    }

    @Test
    fun eleventhAttemptAfterTenFailuresIsRateLimited() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val services = newcomer(backend)
        repeat(InMemoryBackend.maxFailedJoinsPerHour) {
            assertThrowsAppError(AppError.InvalidCode) { services.groups.join(unknown) }
        }
        // Even a valid code is refused, and refused attempts are not logged.
        assertThrowsAppError(AppError.RateLimited) { services.groups.join(lilas) }
        assertThrowsAppError(AppError.RateLimited) { services.groups.join(unknown) }
        assertTrue(services.groups.myGroups().isEmpty())

        clock.advance(InMemoryBackend.joinRateLimitWindow - 1.seconds)
        assertThrowsAppError(AppError.RateLimited) { services.groups.join(lilas) }
        // SQL counts `attempted_at >= now() - interval '1 hour'`: failures exactly one hour old still count.
        clock.advance(1.seconds)
        assertThrowsAppError(AppError.RateLimited) { services.groups.join(lilas) }
        clock.advance(1.milliseconds)
        val joined = services.groups.join(lilas)
        assertEquals(DemoData.lilasGroupId, joined.groupId)
        assertFalse(joined.alreadyMember)
    }

    @Test
    fun onlyFailuresCount() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val services = newcomer(backend)
        repeat(9) {
            assertThrowsAppError(AppError.InvalidCode) { services.groups.join(unknown) }
        }
        assertFalse(services.groups.join(lilas).alreadyMember)
        assertTrue(services.groups.join(lilas).alreadyMember)
        assertTrue(services.groups.join(lilas).alreadyMember)
        assertThrowsAppError(AppError.InvalidCode) { services.groups.join(unknown) } // 10th failure
        assertThrowsAppError(AppError.RateLimited) { services.groups.join(lilas) }
    }

    @Test
    fun limitIsPerUser() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val services = newcomer(backend)
        repeat(InMemoryBackend.maxFailedJoinsPerHour) {
            assertThrowsAppError(AppError.InvalidCode) { services.groups.join(unknown) }
        }
        assertThrowsAppError(AppError.RateLimited) { services.groups.join(lilas) }
        val ines = backend.services(DemoData.ines.id)
        val sport = InviteCode.parse(DemoData.sportInviteCode)!!
        assertEquals(DemoData.sportGroupId, ines.groups.join(sport).groupId)
    }

    @Test
    fun regeneratedCodeInvalidatesTheOldOne() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val camille = backend.services(DemoData.camille.id)
        val fresh = camille.groups.regenerateInviteCode(DemoData.lilasGroupId)
        assertNotEquals(lilas, fresh)
        val services = newcomer(backend)
        assertThrowsAppError(AppError.InvalidCode) { services.groups.join(lilas) }
        assertEquals(DemoData.lilasGroupId, services.groups.join(fresh).groupId)
    }
}
