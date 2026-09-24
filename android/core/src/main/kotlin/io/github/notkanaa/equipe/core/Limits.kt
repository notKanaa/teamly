package io.github.notkanaa.equipe.core

/** Input limits. Must match the SQL check constraints (docs/CONTRACTS.md §1). Lengths count code points. */
object Limits {
    val displayName: IntRange = 1..50
    val groupName: IntRange = 1..60
    val taskTitle: IntRange = 1..200
    const val taskDetailsMax: Int = 5000
    const val passwordMinLength: Int = 8
    const val maxAssignees: Int = 20

    /** Done tasks completed more than this many days ago are hidden unless explicitly requested. */
    const val oldDoneTaskDays: Int = 30
}
