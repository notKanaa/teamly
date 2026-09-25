// Accessibility identifiers of the « Groupes » tab: groups list, create / join sheets, group detail (tasks, activity,
// appearance), invite code and members. Compiled into the app and the UI test target (no TeamTasksCore types here).
//
// Also used by these screens (declared in AccessibilityID.swift):
// - `Groups.list` (groups list), `Groups.createButton` (« Créer un groupe » of the « + » menu of the list),
//   `Groups.joinButton` (the dashed « Rejoindre un groupe » card of the list), `Groups.nameField`,
//   `Groups.codeField`, `Groups.saveButton` (confirm button of BOTH the create and the join sheets),
//   `Groups.membersButton` (the members of the group hero: opens « Membres »), `Groups.inviteButton` (« Inviter » of
//   the group hero, admins), `Groups.inviteCode` (the big code of the invite code sheet);
// - `Tasks.list` (scroll view of the group screen), `Tasks.addButton` (the floating « + » of the group screen),
//   `Tasks.filterPicker` (filter chips bar of the group screen), `Tasks.row(title)` (a task card of the group
//   screen, same as « Mes tâches »).
extension AccessibilityID.Groups {
    // MARK: Groups list

    static let rowPrefix = "groups.row."
    /// A group card of the list, by group name.
    static func row(_ name: String) -> String { rowPrefix + name }
    static let emptyState = "groups.empty"
    static let emptyCreateButton = "groups.empty.create"
    static let emptyJoinButton = "groups.empty.join"
    /// First-load spinner (groups list, group screen, activity, members, invite code sheet).
    static let loading = "groups.loading"
    /// « Réessayer » after a failed first load.
    static let retryButton = "groups.retry"
    /// « + » of the groups list: a menu with « Créer un groupe » (`createButton`) and « Rejoindre un groupe »
    /// (`menuJoinButton`).
    static let addMenu = "groups.addMenu"
    static let menuJoinButton = "groups.menu.join"
    /// « 3 groupes · 11 tâches à faire », under the title of the list.
    static let headerSummary = "groups.header"

    // MARK: Create / join sheets

    static let cancelButton = "groups.cancel"
    static let nameError = "groups.nameError"
    /// « Tu as rejoint « X ». » shown after a successful join.
    static let joinResult = "groups.joinResult"
    /// « Ouvrir le groupe » after a successful join.
    static let openGroupButton = "groups.openGroup"

    // MARK: Group screen

    /// The round back button of the group hero (the navigation bar is hidden).
    static let backButton = "groups.detail.back"
    /// The group's name in the hero; its value describes the group's look (« 🏠, corail »).
    static let detailTitle = "groups.detail.title"
    /// « Tâches » / « Activité », by `GroupDetailViewModel.Tab.rawValue`: `tasks`, `activity`.
    static func tab(_ rawValue: String) -> String { "groups.tab.\(rawValue)" }
    /// « À qui le tour ? »: the horizontal cards, and one card by task title.
    static let turnCards = "groups.detail.turnCards"
    static func turnCard(_ title: String) -> String { "groups.turn.\(title)" }
    /// « … » of the hero, and its items.
    static let detailMenu = "groups.detail.menu"
    static let sortPicker = "groups.detail.sort"
    static let includeOldDoneToggle = "groups.detail.includeOldDone"
    static let resetFilterButton = "groups.detail.resetFilter"
    static let menuMembersButton = "groups.detail.menu.members"
    static let menuInviteButton = "groups.detail.menu.invite"
    /// « Apparence » (admins): opens the color and emoji sheet.
    static let appearanceButton = "groups.detail.appearance"
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
    // The status button of a task card is `Tasks.statusButton`, as in « Mes tâches » (same card).
    static let deleteTaskConfirmButton = "groups.detail.deleteTaskConfirm"

    // MARK: « Apparence » sheet (admins)

    /// The live preview of the group; its value describes the chosen look (« 🎉, violet »).
    static let appearancePreview = "groups.appearance.preview"
    static let appearanceSaveButton = "groups.appearance.save"
    static let appearanceCancelButton = "groups.appearance.cancel"

    // MARK: « Activité » tab

    /// The week's recap card, its podium and its streak line.
    static let activityRecap = "groups.activity.recap"
    static let activityPodium = "groups.activity.podium"
    static let activityStreak = "groups.activity.streak"
    /// The feed (the day sections), or its empty state.
    static let activityFeed = "groups.activity.feed"
    static let activityEmpty = "groups.activity.empty"

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
        /// A member cell, by display name (without « (toi) »).
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
