// Accessibility identifiers of the task screens (detail, editor, assignee picker) and of « Mes tâches ».
// Compiled into the app and the UI test target: plain strings only, no imports.

extension AccessibilityID.Tasks {
    // Task detail.
    static let detailTitle = "tasks.detail.title"
    static let editButton = "tasks.edit"
    static let deleteButton = "tasks.delete"
    static let deleteConfirmButton = "tasks.deleteConfirm"

    /// One option of the detail's status selector (`TaskStatus.rawValue`: todo, in_progress, done).
    static func statusOption(_ rawValue: String) -> String { "tasks.status.\(rawValue)" }

    /// A task row (NavigationLink) in a task list, by task title.
    static func row(_ title: String) -> String { "tasks.row.\(title)" }

    // Task detail, v2: the info card and the checklist.
    /// « Se répète » (its label holds the rule and the next dates).
    static let recurrenceInfo = "tasks.detail.recurrence"
    /// « À tour de rôle » (its label holds the turn order, `TaskDetailViewModel.rotationText`).
    static let rotationInfo = "tasks.detail.rotation"
    /// « Assignées » (its label holds the names).
    static let assigneesInfo = "tasks.detail.assignees"
    /// « 2 sur 5 » next to « Checklist ».
    static let checklistProgress = "tasks.checklist.progress"
    /// The « Ajouter un élément » field of the checklist (task screen and editor).
    static let checklistAddField = "tasks.checklist.addField"
    /// The « Ajouter » button next to that field.
    static let checklistAddButton = "tasks.checklist.addButton"

    /// A checklist item of the task screen (a button, selected when checked), by title.
    static func checklistItem(_ title: String) -> String { "tasks.checklist.item.\(title)" }

    // Task editor.
    static let cancelButton = "tasks.cancel"
    static let priorityPicker = "tasks.priority"
    static let dueDateToggle = "tasks.dueDateToggle"
    static let dueDatePicker = "tasks.dueDatePicker"
    static let assigneesButton = "tasks.assignees"
    static let assigneeList = "tasks.assigneeList"

    /// A member row of the assignee picker, by display name.
    static func assigneeRow(_ name: String) -> String { "tasks.assignee.\(name)" }

    // Task editor, v2: repetition, rotation, priority.
    /// A segment of « Répéter » (`RepeatFrequency.rawValue`: never, daily, weekly, monthly).
    static func repeatOption(_ rawValue: String) -> String { "tasks.repeat.\(rawValue)" }
    static let repeatIntervalStepper = "tasks.repeat.interval"
    /// The hint under « Répéter » (the rule, the next dates).
    static let repeatHint = "tasks.repeat.hint"
    /// A weekday circle of a weekly repetition (ISO weekday: 1 = Monday … 7 = Sunday).
    static func weekday(_ isoWeekday: Int) -> String { "tasks.repeat.weekday.\(isoWeekday)" }
    /// The « À tour de rôle » switch.
    static let rotationToggle = "tasks.rotation.toggle"
    /// A member of the rotation editor, by display name: selected when in the rotation, with the value « Position 2 »
    /// (« Position 1, Commence » for the first).
    static func rotationMember(_ name: String) -> String { "tasks.rotation.member.\(name)" }
    /// « Monter » / « Descendre » of a member of the rotation, by display name.
    static func rotationMoveUp(_ name: String) -> String { "tasks.rotation.up.\(name)" }
    static func rotationMoveDown(_ name: String) -> String { "tasks.rotation.down.\(name)" }
    /// A segment of the priority (`TaskPriority.rawValue`: low, medium, high).
    static func priorityOption(_ rawValue: String) -> String { "tasks.priority.\(rawValue)" }
}

extension AccessibilityID {
    enum MyTasks {
        static let list = "myTasks.list"
        static let optionsMenu = "myTasks.options"
        static let showDoneToggle = "myTasks.showDone"
        static let emptyState = "myTasks.empty"
        static let retryButton = "myTasks.retry"
        /// v2: the « Ta journée » card (its value says what is done, overdue and new).
        static let daySummary = "myTasks.day"
        /// v2: « 2 tâches terminées aujourd’hui », which shows or hides them.
        static let doneTodayButton = "myTasks.doneToday"
    }
}
