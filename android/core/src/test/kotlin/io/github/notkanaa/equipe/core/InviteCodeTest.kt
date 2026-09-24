package io.github.notkanaa.equipe.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Port of ContractTests.swift › InviteCodeTests. */
class InviteCodeTest {
    @Test
    fun acceptsAndNormalizes() {
        for (input in listOf("ABCDEFGH", "abcd-efgh", " AbCd EfGh ", "abcd_efgh")) {
            val parsed = InviteCode.parse(input)
            assertNotNull(input, parsed)
            val code = parsed!!
            assertEquals(input, "ABCDEFGH", code.value)
            assertEquals(input, "ABCD-EFGH", code.formatted)
            assertEquals(input, "ABCD-EFGH", code.toString())
        }
    }

    @Test
    fun rejectsInvalid() {
        for (input in listOf("", "ABCDEFG", "ABCDEFGHJ", "ABCDEFG0", "ABCDEFGO", "ABCDEFG1", "ABCDEFGI", "ÀBCDEFGH")) {
            assertNull(input, InviteCode.parse(input))
        }
    }

    /** CODE-1: SQL drops non-`[A-Z0-9]` code points one by one (`L` + U+0301 keeps the `L`), so must `normalize`. */
    @Test
    fun normalizationDropsCodePointsLikeSQL() {
        assertEquals("LYLAS234", InviteCode.normalize("ĹYLAS234"))
        assertEquals("LYLAS234", InviteCode.parse("ĺylas-234")?.value)
        assertEquals("STRASSE", InviteCode.normalize("straße")) // full case mapping, like SQL upper()
    }

    @Test
    fun alphabetHas32UnambiguousCharacters() {
        assertEquals(32, InviteCode.alphabet.size)
        for (ambiguous in "01IO") {
            assertFalse("$ambiguous", ambiguous in InviteCode.alphabet)
        }
    }

    @Test
    fun equalityIsOnTheNormalizedValue() {
        assertEquals(InviteCode.parse("lylas-234"), InviteCode.parse("LYLAS234"))
        assertEquals(InviteCode.parse("lylas-234").hashCode(), InviteCode.parse("LYLAS234").hashCode())
    }
}
