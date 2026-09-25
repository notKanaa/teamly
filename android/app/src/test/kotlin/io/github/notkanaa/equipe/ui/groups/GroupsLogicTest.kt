package io.github.notkanaa.equipe.ui.groups

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.ui.components.people.PersonInitials
import io.github.notkanaa.equipe.ui.components.people.PersonPalette
import io.github.notkanaa.equipe.ui.members.MembersJoinedText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZonedDateTime
import java.util.UUID

/** Pure helpers of the « Groupes » tab and « Membres »: avatar colours and initials, « Membre depuis … », counts. */
class GroupsLogicTest {
    @Test
    fun paletteMatchesTheIosHash() {
        // Indices computed with the iOS djb2 (UInt64 wrapping) over uuidString: blue 0 … brown 8.
        assertEquals(7, PersonPalette.index(DemoData.camille.id)) // red
        assertEquals(1, PersonPalette.index(DemoData.lucas.id)) // indigo (negative signed hash)
        assertEquals(6, PersonPalette.index(DemoData.ines.id)) // green
        assertEquals(4, PersonPalette.index(DemoData.newcomer.id)) // orange
        assertEquals(3, PersonPalette.index(DemoData.lilasGroupId)) // pink (negative signed hash)
        assertEquals(4, PersonPalette.index(DemoData.sportGroupId)) // orange
        // Same id in lower case: same color (uuidString is upper case).
        assertEquals(
            PersonPalette.index(DemoData.lucas.id),
            PersonPalette.index(UUID.fromString(DemoData.lucas.id.toString().lowercase())),
        )
    }

    @Test
    fun paletteKeepsWhiteInitialsReadable() {
        for (color in PersonPalette.colors) {
            val ratio = 1.05f / (color.luminance() + 0.05f)
            assertTrue("$color gives $ratio:1", ratio >= 4.5f)
        }
        assertTrue(1.05f / (Color(0xFF416CD9).luminance() + 0.05f) >= 4.5f)
    }

    @Test
    fun initials() {
        assertEquals("CR", PersonInitials.make("Coloc' rue des Lilas"))
        assertEquals("CM", PersonInitials.make("Camille Martin"))
        assertEquals("ID", PersonInitials.make("inès dubois"))
        assertEquals("JP", PersonInitials.make("Jean-Pierre"))
        assertEquals("É", PersonInitials.make("  élodie  "))
        assertEquals("ÉL", PersonInitials.make("émile Lou")) // combining acute kept
        assertEquals("2A", PersonInitials.make("2026 Asso"))
        assertEquals("?", PersonInitials.make("?"))
        assertEquals("?", PersonInitials.make("   "))
        assertEquals("?", PersonInitials.make("👍🏽 !!"))
        assertEquals("SS", PersonInitials.make("ß"))
        assertEquals("AB", PersonInitials.make("(a) [b] c"))
    }

    @Test
    fun joinedText() {
        val calendar = AppCalendar.frenchGregorian(AppCalendar.PARIS)
        fun at(year: Int, month: Int, day: Int, hour: Int) =
            ZonedDateTime.of(year, month, day, hour, 0, 0, 0, AppCalendar.PARIS).toInstant()
        val now = at(2026, 9, 24, 10)
        assertEquals("Membre depuis aujourd’hui", MembersJoinedText.sentence(at(2026, 9, 24, 0), now, calendar))
        assertEquals("Membre depuis aujourd’hui", MembersJoinedText.sentence(at(2026, 9, 25, 9), now, calendar))
        assertEquals("Membre depuis hier", MembersJoinedText.sentence(at(2026, 9, 23, 23), now, calendar))
        assertEquals("Membre depuis le 14 septembre", MembersJoinedText.sentence(at(2026, 9, 14, 12), now, calendar))
        assertEquals("Membre depuis le 1er décembre 2025", MembersJoinedText.sentence(at(2025, 12, 1, 8), now, calendar))
    }

    @Test
    fun texts() {
        assertEquals("L Y L A tiret S 2 3 4", GroupsText.spelledOut("LYLA-S234"))
        assertEquals("0 tâche", GroupsText.taskCount(0))
        assertEquals("1 tâche", GroupsText.taskCount(1))
        assertEquals("5 tâches", GroupsText.taskCount(5))
        assertEquals("1 membre", GroupsText.memberCount(1))
        assertEquals("3 membres", GroupsText.memberCount(3))
        assertEquals(15, NameLength.of("  Club de lecture  "))
        assertEquals(62, NameLength.of("👍🏽".repeat(31)))
    }
}
