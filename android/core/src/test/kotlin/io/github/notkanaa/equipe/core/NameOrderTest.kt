package io.github.notkanaa.equipe.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant
import java.util.UUID

/** NameOrder (docs/CONTRACTS.md §4.3): fr_FR case/diacritic folding, then exact order, then id. */
class NameOrderTest {
    private val t0: Instant = Instant.parse("2026-09-24T10:00:00Z")

    private fun group(id: String, name: String, lastActivity: Instant = t0) = GroupSummary(
        group = TeamGroup(UUID.fromString(id), name, createdBy = null, createdAt = t0, lastActivityAt = lastActivity),
        myRole = MemberRole.MEMBER,
    )

    private fun member(id: String, name: String, role: MemberRole = MemberRole.MEMBER) = Membership(
        groupId = UUID.fromString("a0000000-0000-4000-8000-000000000001"),
        user = UserProfile(UUID.fromString(id), name),
        role = role,
        joinedAt = t0,
    )

    @Test
    fun keyFoldsCaseAndDiacritics() {
        assertEquals("elodie", NameOrder.key("Élodie"))
        assertEquals(NameOrder.key("élodie"), NameOrder.key("élodie"))
        assertEquals("ines dubois", NameOrder.key("Inès DUBOIS"))
        assertEquals("strasse", NameOrder.key("Straße"))
        assertEquals("coloc' rue des lilas", NameOrder.key("Coloc' rue des Lilas"))
    }

    @Test
    fun precedesUsesTheFoldedOrderThenTheExactOrder() {
        assertEquals(true, NameOrder.precedes("Coloc' rue des Lilas", "Projet Asso Sport"))
        assertEquals(false, NameOrder.precedes("Projet Asso Sport", "Coloc' rue des Lilas"))
        // Folded first: "élodie" < "Emma" although 'é' > 'E' by code point.
        assertEquals(true, NameOrder.precedes("élodie", "Emma"))
        // Same folded key: exact order (Swift String order, by code point: 'Z' < 'z').
        assertEquals(true, NameOrder.precedes("Zoé", "zoe"))
        assertEquals(false, NameOrder.precedes("zoe", "Zoé"))
        // Identical, or canonically equivalent like Swift's String ==.
        assertNull(NameOrder.precedes("Camille", "Camille"))
        assertNull(NameOrder.precedes("é", "é"))
    }

    @Test
    fun groupsByActivityThenNameThenId() {
        val old = group("00000000-0000-4000-8000-000000000001", "Alpha", t0.minusSeconds(60))
        val recent = group("00000000-0000-4000-8000-000000000002", "Zeta", t0)
        val sameNameHighId = group("80000000-0000-4000-8000-000000000000", "Beta", t0.minusSeconds(30))
        val sameNameLowId = group("10000000-0000-4000-8000-000000000000", "Beta", t0.minusSeconds(30))
        val folded = group("00000000-0000-4000-8000-000000000003", "équipe", t0.minusSeconds(30))
        val sorted = NameOrder.sortedGroups(listOf(old, sameNameHighId, folded, recent, sameNameLowId))
        // "80…" is a negative most-significant long (UUID.compareTo would put it first); uuidString order puts it after "10…".
        assertEquals(listOf(recent, sameNameLowId, sameNameHighId, folded, old), sorted)
    }

    @Test
    fun membersAdminsFirstThenNameThenId() {
        val camille = member("11111111-1111-4111-8111-111111111111", "Camille Martin", MemberRole.ADMIN)
        val lucas = member("22222222-2222-4222-8222-222222222222", "Lucas Bernard")
        val ines = member("33333333-3333-4333-8333-333333333333", "Inès Dubois")
        val ines2 = member("c0000000-0000-4000-8000-000000000004", "Inès Dubois")
        val alex = member("f0000000-0000-4000-8000-000000000005", "alex Moreau")
        val sorted = NameOrder.sortedMembers(listOf(lucas, ines2, alex, camille, ines))
        assertEquals(listOf(camille, alex, ines, ines2, lucas), sorted)
    }

    @Test
    fun nameComparatorSortsDisplayNames() {
        val names = listOf("Lucas", "Émilie", "emma", "Camille", "Emilie")
        assertEquals(listOf("Camille", "Emilie", "Émilie", "emma", "Lucas"), names.sortedWith(NameOrder.nameComparator))
    }
}
