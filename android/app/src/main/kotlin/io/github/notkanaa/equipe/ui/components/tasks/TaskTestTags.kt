package io.github.notkanaa.equipe.ui.components.tasks

import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus

/**
 * Test tags of the task screens: the iOS accessibility identifiers (`App/Sources/Shared/AccessibilityID.swift` and
 * `AccessibilityID+Tasks.swift`), so that UI tests address the same elements on both platforms.
 */
object TaskTestTags {
    /** Task list of the group screen. */
    const val LIST: String = "tasks.list"

    /** « + » of the group screen. */
    const val ADD_BUTTON: String = "tasks.add"

    /** Filter chips bar of the group screen. */
    const val FILTER_PICKER: String = "tasks.filter"

    /** Round status button of a task row (group screen and « Mes tâches »). */
    const val STATUS_BUTTON: String = "tasks.status"

    // Task screen.
    const val DETAIL_TITLE: String = "tasks.detail.title"
    const val EDIT_BUTTON: String = "tasks.edit"
    const val DELETE_BUTTON: String = "tasks.delete"
    const val DELETE_CONFIRM_BUTTON: String = "tasks.deleteConfirm"

    // Task editor.
    const val TITLE_FIELD: String = "tasks.titleField"
    const val DETAILS_FIELD: String = "tasks.detailsField"
    const val SAVE_BUTTON: String = "tasks.save"
    const val CANCEL_BUTTON: String = "tasks.cancel"
    const val PRIORITY_PICKER: String = "tasks.priority"
    const val DUE_DATE_TOGGLE: String = "tasks.dueDateToggle"
    const val DUE_DATE_PICKER: String = "tasks.dueDatePicker"
    const val ASSIGNEES_BUTTON: String = "tasks.assignees"
    const val ASSIGNEE_LIST: String = "tasks.assigneeList"

    /** Android addition: the time button next to [DUE_DATE_PICKER] (iOS has one combined date and time picker). */
    const val DUE_TIME_PICKER: String = "tasks.dueTimePicker"

    /** One option of the task screen's status selector: `tasks.status.todo`, `tasks.status.in_progress`, `tasks.status.done`. */
    fun statusOption(status: TaskStatus): String = "tasks.status.${status.rawValue}"

    /** A task row, by title (group screen and « Mes tâches »). */
    fun row(title: String): String = "tasks.row.$title"

    /** A member row of the assignee picker, by its displayed name (« Camille Martin (vous) » for the current user). */
    fun assigneeRow(name: String): String = "tasks.assignee.$name"

    /** Android addition: one segment of [PRIORITY_PICKER] (`tasks.priority.high`, `…medium`, `…low`). */
    fun priorityOption(priority: TaskPriority): String = "tasks.priority.${priority.rawValue}"
}
