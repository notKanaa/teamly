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

    // Task editor.
    static let cancelButton = "tasks.cancel"
    static let priorityPicker = "tasks.priority"
    static let dueDateToggle = "tasks.dueDateToggle"
    static let dueDatePicker = "tasks.dueDatePicker"
    static let assigneesButton = "tasks.assignees"
    static let assigneeList = "tasks.assigneeList"

    /// A member row of the assignee picker, by display name.
    static func assigneeRow(_ name: String) -> String { "tasks.assignee.\(name)" }
}

extension AccessibilityID {
    enum MyTasks {
        static let list = "myTasks.list"
        static let optionsMenu = "myTasks.options"
        static let showDoneToggle = "myTasks.showDone"
        static let emptyState = "myTasks.empty"
        static let retryButton = "myTasks.retry"
    }
}
