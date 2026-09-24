package io.github.notkanaa.equipe.core

import java.text.Normalizer

/**
 * Name order shared by every backend implementation (docs/CONTRACTS.md §4.3), so the mocks and the Supabase
 * adapters return `myGroups` and `members` in exactly the same order, on Android and on iOS.
 *
 * Port of TeamTasksCore/Logic/NameOrder.swift, which folds with Foundation (`caseInsensitive` +
 * `diacriticInsensitive`, fr_FR) and compares with Swift's `String` order. This is *not* a locale collation
 * (`java.text.Collator` would order punctuation and spaces differently): it folds, then compares code points.
 */
object NameOrder {
    private val nonSpacingMarks = Regex("\\p{Mn}+")

    /**
     * Case- and diacritic-insensitive key: full case folding (upper-case full mapping, then per-code-point
     * lower-casing: `ß` → `ss`, `Σ`/`ς` → `σ`), then the non-spacing marks of the canonical decomposition are
     * dropped (`é` → `e`, `İ` → `i`), then NFC.
     */
    fun key(name: String): String {
        val upper = name.uppercase()
        val folded = StringBuilder(upper.length)
        upper.codePoints().forEach { folded.appendCodePoint(Character.toLowerCase(it)) }
        val decomposed = Normalizer.normalize(folded, Normalizer.Form.NFD)
        return Normalizer.normalize(nonSpacingMarks.replace(decomposed, ""), Normalizer.Form.NFC)
    }

    /** Folded order first, then exact (Swift `String`) order; null when both names are identical. */
    fun precedes(lhs: String, rhs: String): Boolean? {
        val left = key(lhs)
        val right = key(rhs)
        if (left != right) return compareCodePoints(left, right) < 0
        val exact = compareLikeSwift(lhs, rhs)
        if (exact != 0) return exact < 0
        return null
    }

    /** [precedes] as a comparator (0 for identical names), e.g. for lists of display names. */
    val nameComparator: Comparator<String> = Comparator { lhs, rhs ->
        when (precedes(lhs, rhs)) {
            true -> -1
            false -> 1
            null -> 0
        }
    }

    /** `myGroups`: most recently active first, then name, then id ([uuidString]). */
    val groupComparator: Comparator<GroupSummary> = Comparator { lhs, rhs ->
        val activity = rhs.group.lastActivityAt.compareTo(lhs.group.lastActivityAt)
        if (activity != 0) return@Comparator activity
        val byName = nameComparator.compare(lhs.group.name, rhs.group.name)
        if (byName != 0) return@Comparator byName
        lhs.id.uuidString.compareTo(rhs.id.uuidString)
    }

    /** `members`: admins first, then display name, then user id ([uuidString]). */
    val memberComparator: Comparator<Membership> = Comparator { lhs, rhs ->
        if (lhs.role != rhs.role) return@Comparator if (lhs.role == MemberRole.ADMIN) -1 else 1
        val byName = nameComparator.compare(lhs.user.displayName, rhs.user.displayName)
        if (byName != 0) return@Comparator byName
        lhs.user.id.uuidString.compareTo(rhs.user.id.uuidString)
    }

    /** `myGroups`: most recently active first, then name, then id. */
    fun sortedGroups(groups: List<GroupSummary>): List<GroupSummary> = groups.sortedWith(groupComparator)

    /** `members`: admins first, then display name, then user id. */
    fun sortedMembers(members: List<Membership>): List<Membership> = members.sortedWith(memberComparator)
}
