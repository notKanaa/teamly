package io.github.notkanaa.equipe.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException

/** AppError messages (port of the AppError parts of Logic/WordingTests.swift) and `wrap`. */
class AppErrorTest {
    @Test
    fun everyCaseHasAFrenchMessage() {
        assertEquals(26, AppError.simpleCases.size)
        assertEquals(26, AppError.simpleCases.toSet().size)
        for (error in AppError.simpleCases) {
            assertTrue("$error", error.messageFR.isNotEmpty())
            assertEquals(error.messageFR, error.message)
        }
        assertEquals("Une erreur est survenue. (boom)", AppError.Unknown("boom").messageFR)
    }

    /** French typography: the apostrophe is ’ (U+2019), never the ASCII one (review UX-05). */
    @Test
    fun messagesUseTheTypographicApostrophe() {
        val ascii = AppError.simpleCases.map { it.messageFR }.filter { it.contains('\'') }
        assertTrue("ASCII apostrophes in user-facing strings: $ascii", ascii.isEmpty())
    }

    /** A no-break space before « ? ! : ; » and inside « » (review UX-14). */
    @Test
    fun messagesUseNoBreakSpaces() {
        val problems = AppError.simpleCases.flatMap { error ->
            typographyProblems(error.messageFR).map { "$it in « ${error.messageFR} »" }
        }
        assertTrue("$problems", problems.isEmpty())
        assertEquals("Vous êtes le seul admin : nommez d’abord un autre admin.", AppError.LastAdmin.messageFR)
        assertEquals(
            "Utilisez « Quitter le groupe » pour vous retirer vous-même.",
            AppError.CannotRemoveSelf.messageFR,
        )
    }

    @Test
    fun wrapKeepsAppErrorsAndWrapsTheRest() {
        assertSame(AppError.Network, AppError.wrap(AppError.Network))
        assertEquals(AppError.Unknown("x"), AppError.wrap(AppError.Unknown("x")))
        assertEquals(AppError.Unknown("annulé"), AppError.wrap(CancellationException("stop")))
        assertEquals(AppError.Unknown("java.io.IOException: offline"), AppError.wrap(IOException("offline")))
    }

    @Test
    fun singletonsCarryNoStateBetweenThrows() {
        val error: AppError = AppError.Forbidden
        error.addSuppressed(IllegalStateException("x"))
        assertEquals(0, error.suppressed.size)
        assertEquals(0, error.stackTrace.size)
        assertFalse(error == AppError.NotFound)
    }

    private fun typographyProblems(text: String): List<String> {
        val problems = mutableListOf<String>()
        fun isNoBreakSpace(character: Char?): Boolean = character == ' ' || character == ' '
        text.forEachIndexed { index, character ->
            val previous = text.getOrNull(index - 1)
            val next = text.getOrNull(index + 1)
            if (character in "?!:;" && previous == ' ') problems.add("plain space before « $character »")
            if (character == '«' && !isNoBreakSpace(next)) problems.add("no no-break space after «")
            if (character == '»' && !isNoBreakSpace(previous)) problems.add("no no-break space before »")
        }
        return problems
    }
}
