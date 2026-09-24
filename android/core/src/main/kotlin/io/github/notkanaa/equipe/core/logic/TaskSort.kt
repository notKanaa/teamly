package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.NameOrder
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.compareCodePoints
import io.github.notkanaa.equipe.core.compareLikeSwift
import io.github.notkanaa.equipe.core.uuidString
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.text.Normalizer
import java.time.Instant

// Port of TeamTasksCore/Logic/TaskSort.swift.

/**
 * Sort orders of a task list. Every order is total over distinct tasks and independent of the input order
 * (PostgREST reads have no ORDER BY): the last criteria are the creation date (oldest first, newest first for
 * [RECENTLY_CREATED]) and the id ([uuidString]). Only two copies of the same task keep their input order (stable sort).
 * [rawValue] is the Swift raw value, also the JSON value.
 */
@Serializable
enum class TaskSort(val rawValue: String, val label: String) {
    /** Due date ascending (tasks without due date last), then priority (high first), then title, then creation date
     * ascending, then id. */
    @SerialName("dueDate")
    DUE_DATE("dueDate", "Échéance"),

    /** Priority (high first), then due date ascending (none last), then title, then creation date ascending, then id. */
    @SerialName("priority")
    PRIORITY("priority", "Priorité"),

    /** Most recently created first, then title, then id. */
    @SerialName("recentlyCreated")
    RECENTLY_CREATED("recentlyCreated", "Plus récentes"),
    ;

    val id: String get() = rawValue

    /** Returns the tasks sorted in this order (stable; each title key is computed once). */
    fun sorted(tasks: List<TaskItem>): List<TaskItem> =
        tasks.map { KeyedTask(it, titleKey(it.title)) }
            .sortedWith { lhs, rhs -> compare(lhs.task, lhs.titleKey, rhs.task, rhs.titleKey) }
            .map { it.task }

    /**
     * Strict ordering predicate (false for tasks that compare equal). Prefer [sorted], which is stable and computes each
     * title key once.
     */
    fun areInIncreasingOrder(lhs: TaskItem, rhs: TaskItem): Boolean =
        compare(lhs, titleKey(lhs.title), rhs, titleKey(rhs.title)) < 0

    /** This order as a comparator (0 only for tasks equal on every criterion, e.g. two copies of the same task). */
    val comparator: Comparator<TaskItem>
        get() = Comparator { lhs, rhs -> compare(lhs, titleKey(lhs.title), rhs, titleKey(rhs.title)) }

    private class KeyedTask(val task: TaskItem, val titleKey: String)

    /** Negative when [lhs] comes first, positive when [rhs] comes first, 0 when equal on every criterion. */
    private fun compare(lhs: TaskItem, lhsTitle: String, rhs: TaskItem, rhsTitle: String): Int {
        var result: Int
        when (this) {
            DUE_DATE, PRIORITY -> {
                val byDue = compareDue(lhs.dueAt, rhs.dueAt)
                val byPriority = rhs.priority.rank.compareTo(lhs.priority.rank)
                result = if (this == DUE_DATE) byDue else byPriority
                if (result != 0) return result
                result = if (this == DUE_DATE) byPriority else byDue
                if (result != 0) return result
                result = compareTitles(lhs, lhsTitle, rhs, rhsTitle)
                if (result != 0) return result
                result = lhs.createdAt.compareTo(rhs.createdAt)
                if (result != 0) return result
            }
            RECENTLY_CREATED -> {
                result = rhs.createdAt.compareTo(lhs.createdAt)
                if (result != 0) return result
                result = compareTitles(lhs, lhsTitle, rhs, rhsTitle)
                if (result != 0) return result
            }
        }
        return lhs.id.uuidString.compareTo(rhs.id.uuidString)
    }

    /** Folded title key (already NFC), then exact title (Swift `String` order). */
    private fun compareTitles(lhs: TaskItem, lhsTitle: String, rhs: TaskItem, rhsTitle: String): Int {
        val byKey = compareCodePoints(lhsTitle, rhsTitle)
        if (byKey != 0) return byKey
        return compareLikeSwift(lhs.title, rhs.title)
    }

    companion object {
        /** The sort whose raw value is [rawValue], or null. */
        fun fromRawValue(rawValue: String): TaskSort? = entries.firstOrNull { it.rawValue == rawValue }

        /**
         * Case-, accent- and width-insensitive key so that "éclairage" sorts between "eau" and "fenêtre".
         * Ligatures are spelled out as in French alphabetical order ("œufs" between "nettoyer" and "payer").
         */
        internal fun titleKey(title: String): String =
            NameOrder.key(foldWidth(title))
                .replace("œ", "oe")
                .replace("Œ", "oe")
                .replace("æ", "ae")
                .replace("Æ", "ae")
                .replace("ß", "ss")

        /**
         * Width folding (Foundation's `widthInsensitive`): the characters whose compatibility decomposition is
         * `<wide>` or `<narrow>` (ideographic space, Halfwidth and Fullwidth Forms) become their ordinary form.
         */
        private fun foldWidth(text: String): String {
            if (text.none(::hasWidthVariant)) return text
            val folded = StringBuilder(text.length)
            for (character in text) {
                if (hasWidthVariant(character)) {
                    folded.append(Normalizer.normalize(character.toString(), Normalizer.Form.NFKC))
                } else {
                    folded.append(character)
                }
            }
            return folded.toString()
        }

        /** U+3000 (ideographic space) and U+FF01 to U+FFEE (Halfwidth and Fullwidth Forms). */
        private fun hasWidthVariant(character: Char): Boolean =
            character.code == 0x3000 || character.code in 0xFF01..0xFFEE

        /** Ascending due date, null last. */
        internal fun compareDue(lhs: Instant?, rhs: Instant?): Int = when {
            lhs == null && rhs == null -> 0
            lhs == null -> 1
            rhs == null -> -1
            else -> lhs.compareTo(rhs)
        }
    }
}
