// Accessibility identifiers of the « Groupes » tab: groups list, create / join sheets, group detail, invite code
// and members. Compiled into the app and the UI test target (no TeamTasksCore types here).
//
// Also used by these screens (declared in AccessibilityID.swift):
// - `Groups.list` (groups list), `Groups.createButton` / `Groups.joinButton` (toolbar), `Groups.nameField`,
//   `Groups.codeField`, `Groups.saveButton` (confirm button of BOTH the create and the join sheets),
//   `Groups.membersButton` (« Membres » row of the group screen), `Groups.inviteButton` (« Inviter avec un code »
//   row of the group screen, admins), `Groups.inviteCode` (the big code of the invite code sheet);
// - `Tasks.list` (task list of the group screen), `Tasks.addButton` (« + » of the group screen),
//   `Tasks.filterPicker` (filter chips bar of the group screen), `Tasks.row(title)` (a task cell of the group
//   screen, same as « Mes tâches »).
extension AccessibilityID.Groups {
    // MARK: Groups list

    static let rowPrefix = "groups.row."
    /// A group cell of the list, by group name.
    static func row(_ name: String) -> String { rowPrefix + name }
    static let emptyState = "groups.empty"
    static let emptyCreateButton = "groups.empty.create"
    static let emptyJoinButton = "groups.empty.join"
    /// First-load spinner (groups list, group screen, members, invite code sheet).
    static let loading = "groups.loading"
    /// « Réessayer » after a failed first load.
    static let retryButton = "groups.retry"

    // MARK: Create / join sheets

    static let cancelButton = "groups.cancel"
    static let nameError = "groups.nameError"
    /// « Vous avez rejoint « X ». » shown after a successful join.
    static let joinResult = "groups.joinResult"
    /// « Ouvrir le groupe » after a successful join.
    static let openGroupButton = "groups.openGroup"

    // MARK: Group screen

    static let detailMenu = "groups.detail.menu"
    static let sortPicker = "groups.detail.sort"
    static let includeOldDoneToggle = "groups.detail.includeOldDone"
    static let resetFilterButton = "groups.detail.resetFilter"
    static let menuMembersButton = "groups.detail.menu.members"
    static let menuInviteButton = "groups.detail.menu.invite"
    static let renameButton = "groups.detail.rename"
    static let renameField = "groups.detail.renameField"
    static let renameConfirmButton = "groups.detail.renameConfirm"
    static let deleteButton = "groups.detail.delete"
    static let deleteConfirmButton = "groups.detail.deleteConfirm"
    static let filterChipPrefix = "groups.filter."
    /// Filter chip: `all`, `todo`, `inProgress`, `done`, `notDone` (status chips), `assignedToMe`, `overdue`.
    static func filterChip(_ key: String) -> String { filterChipPrefix + key }
    static let emptyTasks = "groups.detail.empty"
    static let createFirstTaskButton = "groups.detail.createFirstTask"
    // The status button of a task cell is `Tasks.statusButton`, as in « Mes tâches » (same row view).
    static let deleteTaskConfirmButton = "groups.detail.deleteTaskConfirm"

    // MARK: Invite code sheet (the code itself is `inviteCode`)

    static let shareCodeButton = "groups.invite.share"
    static let regenerateCodeButton = "groups.invite.regenerate"
    static let regenerateConfirmButton = "groups.invite.regenerateConfirm"
    static let doneButton = "groups.done"
}

extension AccessibilityID {
    /// « Membres » screen.
    enum Members {
        static let list = "members.list"
        static let rowPrefix = "members.row."
        /// A member cell, by display name (without « (vous) »).
        static func row(_ name: String) -> String { rowPrefix + name }
        static let actionsPrefix = "members.actions."
        /// The « … » menu of a member cell (admins): change role, remove. By display name.
        static func actionsButton(_ name: String) -> String { actionsPrefix + name }
        static let roleButton = "members.role"
        static let removeButton = "members.remove"
        static let removeConfirmButton = "members.removeConfirm"
        static let selfDemoteConfirmButton = "members.selfDemoteConfirm"
        /// Invite code shown in the list (admins).
        static let inviteCode = "members.inviteCode"
        static let shareCodeButton = "members.shareCode"
        static let regenerateCodeButton = "members.regenerateCode"
        static let regenerateConfirmButton = "members.regenerateConfirm"
        static let leaveButton = "members.leave"
        static let leaveConfirmButton = "members.leaveConfirm"
    }
}
