import Foundation
import Observation

/// A member offered in the assignee picker.
public struct AssigneeOption: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// « Camille Martin (toi) » for the current user.
    public var name: String
    public var role: MemberRole
    public var isMe: Bool
    public var isSelected: Bool

    public init(id: UUID, name: String, role: MemberRole, isMe: Bool, isSelected: Bool) {
        self.id = id
        self.name = name
        self.role = role
        self.isMe = isMe
        self.isSelected = isSelected
    }
}

/// v2: « Répéter » in the task editor.
public enum RepeatFrequency: String, Sendable, Hashable, CaseIterable, Identifiable {
    case never
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }

    /// « Jamais », « Jour », « Semaine », « Mois ».
    public var label: String {
        switch self {
        case .never: "Jamais"
        case .daily: "Jour"
        case .weekly: "Semaine"
        case .monthly: "Mois"
        }
    }

    /// The rule's frequency; nil for « Jamais ».
    public var frequency: RecurrenceRule.Frequency? {
        switch self {
        case .never: nil
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        }
    }

    public init(_ frequency: RecurrenceRule.Frequency?) {
        switch frequency {
        case nil: self = .never
        case .daily?: self = .daily
        case .weekly?: self = .weekly
        case .monthly?: self = .monthly
        }
    }
}

/// v2: a weekday chip of a weekly repetition.
public struct WeekdayOption: Sendable, Hashable, Identifiable {
    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public var id: Int
    /// « L », « M », « M », « J », « V », « S », « D ».
    public var letter: String
    /// « Lundi » … « Dimanche » (accessibility).
    public var name: String
    public var isSelected: Bool

    public init(id: Int, letter: String, name: String, isSelected: Bool) {
        self.id = id
        self.letter = letter
        self.name = name
        self.isSelected = isSelected
    }
}

/// v2: a member in the rotation editor (« À tour de rôle »).
public struct RotationEditorEntry: Sendable, Hashable, Identifiable {
    public var person: PersonBadge
    /// In the rotation; the others are listed after it, to add.
    public var isIncluded: Bool
    /// 1-based place in the rotation; nil when not included.
    public var position: Int?
    /// « Commence », « C’est son tour », « C’est ton tour »; nil for the others.
    public var badge: String?

    public init(person: PersonBadge, isIncluded: Bool, position: Int?, badge: String?) {
        self.person = person
        self.isIncluded = isIncluded
        self.position = position
        self.badge = badge
    }

    public var id: UUID { person.id }
}

/// v2: an item of the initial checklist of a new task.
public struct ChecklistDraftItem: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String

    public init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
}

/// « Nouvelle tâche » / « Modifier la tâche » sheet: title, details, priority, optional due date and assignees
/// (members of the group, at most 20). Fields are validated before calling the service, each with its message.
/// On success `savedTask` is set: dismiss.
///
/// v2 (docs/CONTRACTS-V2.md §5, §6):
/// - « Répéter » (`repeatFrequency`: Jamais / Jour / Semaine / Mois, `repeatInterval`, `weekdayOptions` for a
///   weekly rule, `recurrenceSummary`). A repetition needs a due date: choosing a frequency turns the due date on,
///   `isDueDateRequired` says so, and turning it off shows `recurrenceError`. A new rule takes the calendar's time
///   zone; an existing rule keeps its own.
/// - « À tour de rôle » (`isRotationEnabled`, only while repeating): `rotationEntries` replace the assignee picker
///   (`showsAssigneePicker`), in order, reorderable; turning it on proposes every member, the current assignees
///   first.
/// - « Checklist »: the initial items, on creation only (`showsChecklist`).
/// - An edit starts from `TaskDraft(task:)`: every v2 field the editor does not change is sent back as it was, and
///   `hasChanges` compares with it.
///
/// View: `.task { await model.load() }` (loads the members for the picker).
@MainActor
@Observable
public final class TaskEditorViewModel: ErrorPresenting {
    public enum Mode: Sendable, Hashable {
        case create(groupId: UUID)
        case edit(TaskItem)
    }

    public static let maxAssignees = Limits.maxAssignees
    public static let maxTitleLength = Limits.taskTitle.upperBound
    public static let maxDetailsLength = Limits.taskDetailsMax
    public static let invalidDueDateMessage = "Date d’échéance invalide."
    public static let goneMessage = "Cette tâche a été supprimée."
    /// After `assignee_not_member`: the people who left the group were removed from the selection.
    public static let departedAssigneesMessage =
        "Une personne assignée a quitté le groupe\u{00A0}: elle a été retirée. Enregistre à nouveau."
    /// v2: under « Répéter ».
    public static let recurrenceHint = "Dès que la tâche est faite, la suivante est créée."
    /// v2: next to the due date while the task repeats.
    public static let dueDateRequiredText = "Une tâche qui se répète a toujours une échéance."
    /// v2: « À tour de rôle ».
    public static let rotationTitle = "À tour de rôle"
    public static let rotationSubtitle = "Une personne à la fois, dans cet ordre."
    public static let rotationStartsBadge = "Commence"
    public static let rotationTurnBadge = "C’est son tour"
    public static let rotationMyTurnBadge = "C’est ton tour"
    /// v2: after `invalid_rotation`: the people who left the group were removed from the rotation.
    public static let departedRotationMessage =
        "Une personne du tour de rôle a quitté le groupe\u{00A0}: elle a été retirée. Enregistre à nouveau."
    /// v2: « Checklist ».
    public static let checklistTitle = "Checklist"
    public static let addChecklistItemTitle = "Ajouter un élément"
    /// v2: letters of the weekday chips, Monday first.
    public static let weekdayLetters = ["L", "M", "M", "J", "V", "S", "D"]

    public let mode: Mode
    public let groupId: UUID

    public var title: String {
        get { titleValue }
        set {
            titleValue = newValue
            if titleError != nil { titleError = Self.titleMessage(newValue) }
        }
    }

    public var details: String {
        get { detailsValue }
        set {
            detailsValue = newValue
            if detailsError != nil { detailsError = Self.detailsMessage(newValue) }
        }
    }

    public var priority: TaskPriority
    /// « Échéance » toggle. Turning it on keeps the last chosen date (tomorrow 18:00 by default). v2: turning it off
    /// while the task repeats shows `recurrenceError`.
    public var hasDueDate: Bool {
        get { hasDueDateValue }
        set {
            hasDueDateValue = newValue
            if !newValue { dueDateError = nil }
            recurrenceError = !newValue && isRecurring ? AppError.recurrenceNeedsDueDate.messageFR : nil
        }
    }

    /// Date picker value (used when `hasDueDate`).
    public var dueDate: Date {
        get { dueDateValue }
        set {
            dueDateValue = newValue
            dueDateError = nil
        }
    }

    public private(set) var assigneeIds: Set<UUID>
    /// Members of the group (assignee picker), admins first then by name.
    public private(set) var members: [Membership] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var titleError: String?
    public private(set) var detailsError: String?
    public private(set) var dueDateError: String?
    public private(set) var assigneesError: String?
    /// v2: the repetition's message (a refused rule, a missing due date).
    public private(set) var recurrenceError: String?
    /// v2: the rotation's message (fewer than 2 or more than 20 people, someone who left).
    public private(set) var rotationError: String?
    /// v2: the initial checklist's message (a refused title, more than 30 items).
    public private(set) var checklistError: String?
    /// v2: the initial checklist (creation only).
    public private(set) var checklistItems: [ChecklistDraftItem] = []
    public private(set) var isSaving = false
    public private(set) var savedTask: TaskItem?
    /// Edit mode: the task was deleted meanwhile.
    public private(set) var isGone = false
    public var error: ErrorState?

    public let session: SessionModel
    /// The draft the editor started from (edit: `TaskDraft(task:)`): what is sent for everything not changed here.
    private var original: TaskDraft
    private var titleValue: String
    private var detailsValue: String
    private var hasDueDateValue: Bool
    private var dueDateValue: Date
    private var repeatFrequencyValue: RepeatFrequency
    private var repeatIntervalValue: Int
    /// The explicit weekdays of a weekly rule; nil = the due date's weekday.
    private var weekdaysSelection: Set<Int>?
    private var isRotationEnabledValue: Bool
    /// The rotation sent: the task's own list until the user changes it (it may list people who left, which the
    /// server keeps as they are); a changed list only holds members.
    private var rotationValue: [UUID]
    private var newChecklistItemTitleValue = ""
    private let runner = LoadRunner()

    /// New task in `groupId`. Pass `members` when already loaded (the picker then needs no request).
    public convenience init(session: SessionModel, groupId: UUID, members: [Membership]? = nil) {
        self.init(session: session, mode: .create(groupId: groupId), members: members)
    }

    /// Full edit of `task` (admin or creator).
    public convenience init(session: SessionModel, task: TaskItem, members: [Membership]? = nil) {
        self.init(session: session, mode: .edit(task), members: members)
    }

    public init(session: SessionModel, mode: Mode, members: [Membership]? = nil) {
        self.session = session
        self.mode = mode
        let draft: TaskDraft
        switch mode {
        case let .create(groupId):
            self.groupId = groupId
            draft = TaskDraft()
        case let .edit(task):
            groupId = task.groupId
            draft = TaskDraft(task: task)
        }
        original = draft
        titleValue = draft.title
        detailsValue = draft.details
        priority = draft.priority
        assigneeIds = draft.assigneeIds
        hasDueDateValue = draft.dueAt != nil
        dueDateValue = draft.dueAt ?? Self.defaultDueDate(now: session.platform.now(), calendar: session.platform.calendar)
        repeatFrequencyValue = RepeatFrequency(draft.recurrence?.frequency)
        repeatIntervalValue = draft.recurrence?.interval ?? 1
        weekdaysSelection = draft.recurrence?.weekdays
        isRotationEnabledValue = !draft.rotation.isEmpty
        rotationValue = draft.rotation
        if let members {
            self.members = NameOrder.sortedMembers(members)
            loadState = .loaded
        }
    }

    // MARK: - Loading (members)

    /// Loads the group's members for the picker (once).
    public func load() async {
        guard loadState != .loaded else { return }
        await runner.run(rerunIfRunning: false) { [weak self] in await self?.fetchMembers() }
    }

    public func reload() async {
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetchMembers() }
    }

    /// Loads the members and drops from the selection the people who are no longer members: the server refuses
    /// them (`assignee_not_member`) and the picker has no row to unselect them.
    private func fetchMembers() async {
        if loadState != .loaded { loadState = .loading }
        do {
            members = NameOrder.sortedMembers(try await session.services.groups.members(groupId: groupId))
            loadState = .loaded
            let memberIds = Set(members.map(\.user.id))
            assigneeIds.formIntersection(memberIds)
            // Their assignments are gone on the server too: dropping them is not a change of the user.
            original.assigneeIds.formIntersection(memberIds)
            // A rotation switched on before the members were known.
            if isRotationEnabledValue, rotationValue.isEmpty {
                rotationValue = defaultRotation()
            }
        } catch {
            guard let state = ErrorState(from: error) else {
                if loadState == .loading { loadState = .idle }
                return
            }
            if loadState == .loaded {
                self.error = state
            } else {
                loadState = .failed(state.message)
            }
        }
    }

    // MARK: - Display

    public var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    public var navigationTitle: String { isEditing ? "Modifier la tâche" : "Nouvelle tâche" }
    public var saveButtonTitle: String { isEditing ? "Enregistrer" : "Créer" }

    /// The draft sent to the service. It starts from `TaskDraft(task:)` when editing, so nothing the editor does not
    /// show is lost (docs/CONTRACTS-V2.md §0).
    public var draft: TaskDraft {
        var draft = original
        draft.title = titleValue
        draft.details = detailsValue
        draft.priority = priority
        draft.dueAt = hasDueDateValue ? dueDateValue : nil
        draft.assigneeIds = assigneeIds
        draft.recurrence = draftRule
        draft.rotation = draftRotation
        draft.checklist = isEditing ? [] : checklistItems.map(\.title)
        return draft
    }

    /// Something differs from the initial values (ask before discarding).
    public var hasChanges: Bool { draft != originalComparable }

    private var originalComparable: TaskDraft {
        var value = original
        // A create form with the toggle off has no due date whatever the picker shows.
        if !isEditing { value.dueAt = nil }
        return value
    }

    /// The current user's role in the group (from the members), nil when not a member.
    public var myRole: MemberRole? {
        members.first { $0.user.id == session.userId }?.role
    }

    /// Edit mode: whether the user may edit this task (admin or creator). Always true for a new task of a member.
    public var canEdit: Bool {
        switch mode {
        case .create:
            return loadState != .loaded || TaskPermissions.canCreate(role: myRole)
        case let .edit(task):
            return loadState != .loaded || TaskPermissions.canEdit(task, userId: session.userId, role: myRole)
        }
    }

    public var canSave: Bool { !InputValidation.trimmed(titleValue).isEmpty && !isSaving && canEdit }

    public var assigneeOptions: [AssigneeOption] {
        members.map { member in
            let isMe = member.user.id == session.userId
            return AssigneeOption(
                id: member.user.id,
                name: isMe ? "\(member.user.displayName) (toi)" : member.user.displayName,
                role: member.role,
                isMe: isMe,
                isSelected: assigneeIds.contains(member.user.id)
            )
        }
    }

    /// 20 people are already assigned: others cannot be added.
    public var assigneeLimitReached: Bool { assigneeIds.count >= Self.maxAssignees }

    /// « Toi, Lucas Bernard » / « Non assignée ».
    public var assigneesSummary: String {
        MemberDirectory(members: members, currentUserId: session.userId).assigneesText(Array(assigneeIds))
    }

    public func isAssigned(_ userId: UUID) -> Bool { assigneeIds.contains(userId) }

    /// Adds or removes an assignee. Adding beyond 20 is refused with `assigneesError`.
    public func toggleAssignee(_ userId: UUID) {
        if assigneeIds.contains(userId) {
            assigneeIds.remove(userId)
            if assigneeIds.count <= Self.maxAssignees { assigneesError = nil }
        } else if assigneeLimitReached {
            assigneesError = AppError.tooManyAssignees.messageFR
        } else {
            assigneeIds.insert(userId)
            assigneesError = nil
        }
    }

    // MARK: - Repetition (v2)

    public var repeatFrequencyOptions: [RepeatFrequency] { RepeatFrequency.allCases }

    /// « Jamais », « Jour », « Semaine », « Mois ». Choosing a frequency turns the due date on (a repetition needs
    /// one); « Jamais » also hides the rotation.
    public var repeatFrequency: RepeatFrequency {
        get { repeatFrequencyValue }
        set {
            repeatFrequencyValue = newValue
            recurrenceError = nil
            rotationError = nil
            if newValue != .never, !hasDueDateValue {
                hasDueDateValue = true
                dueDateError = nil
            }
        }
    }

    /// The task repeats.
    public var isRecurring: Bool { repeatFrequencyValue != .never }

    /// While the task repeats, the due date cannot be removed (`dueDateRequiredText`).
    public var isDueDateRequired: Bool { isRecurring }

    /// Every `repeatInterval` days, weeks or months, kept in `repeatIntervalRange`.
    public var repeatInterval: Int {
        get { repeatIntervalValue }
        set {
            repeatIntervalValue = min(max(newValue, repeatIntervalRange.lowerBound), repeatIntervalRange.upperBound)
            recurrenceError = nil
        }
    }

    public var repeatIntervalRange: ClosedRange<Int> { 1...Limits.repeatIntervalMax }

    /// The chips of a weekly rule, Monday first: the chosen days, or else the due date's weekday.
    public var weekdayOptions: [WeekdayOption] {
        let selected = selectedWeekdays
        return (1...7).map { day in
            WeekdayOption(
                id: day,
                letter: Self.weekdayLetters[day - 1],
                name: FrenchDateFormatter.capitalizingFirstLetter(RecurrenceText.weekdayNames[day - 1]),
                isSelected: selected.contains(day)
            )
        }
    }

    /// Adds or removes a day of a weekly rule (one day at least stays). Back to the due date's weekday alone, the
    /// rule follows the due date again (unless the task's rule listed its days).
    public func toggleWeekday(_ weekday: Int) {
        guard (1...7).contains(weekday) else { return }
        var days = selectedWeekdays
        if days.contains(weekday) {
            guard days.count > 1 else { return }
            days.remove(weekday)
        } else {
            days.insert(weekday)
        }
        if original.recurrence?.weekdays == nil, let implicit = implicitWeekday, days == [implicit] {
            weekdaysSelection = nil
        } else {
            weekdaysSelection = days
        }
        recurrenceError = nil
    }

    /// « Chaque semaine, le samedi », « Tous les 2 jours » (`RecurrenceText.description`); nil for « Jamais ».
    public var recurrenceSummary: String? {
        draftRule.map { RecurrenceText.description($0, dueAt: hasDueDateValue ? dueDateValue : nil) }
    }

    /// The draft's rule, nil for « Jamais ». It starts from the task's rule, whose time zone is kept; a new rule
    /// takes the calendar's time zone. The server's month day is kept while the rule stays monthly on the same local
    /// due date (it recomputes it otherwise, docs/CONTRACTS-V2.md §5).
    private var draftRule: RecurrenceRule? {
        guard let frequency = repeatFrequencyValue.frequency else { return nil }
        let base = original.recurrence
        var rule = base ?? RecurrenceRule(frequency: frequency, timeZoneId: session.platform.calendar.timeZone.identifier)
        rule.frequency = frequency
        rule.interval = repeatIntervalValue
        rule.weekdays = frequency == .weekly ? weekdaysSelection : nil
        let zone = RecurrenceText.timeZone(of: rule)
        let dueAt = hasDueDateValue ? dueDateValue : nil
        let sameLocalDate = dueAt.map { LocalDateTime($0, in: zone).day } == original.dueAt.map { LocalDateTime($0, in: zone).day }
        if frequency != .monthly || base?.frequency != .monthly || !sameLocalDate {
            rule.monthDay = nil
        }
        return rule
    }

    /// The due date's weekday in the rule's time zone, nil without due date.
    private var implicitWeekday: Int? {
        guard hasDueDateValue else { return nil }
        let zoneId = original.recurrence?.timeZoneId ?? session.platform.calendar.timeZone.identifier
        return RecurrenceText.localWeekday(of: dueDateValue, rule: RecurrenceRule(frequency: .weekly, timeZoneId: zoneId))
    }

    private var selectedWeekdays: Set<Int> {
        weekdaysSelection ?? implicitWeekday.map { [$0] } ?? []
    }

    // MARK: - Rotation (v2)

    /// « À tour de rôle ». Turning it on proposes every member (at most 20): the current assignees first, then the
    /// others by name. Only used while the task repeats (`canUseRotation`).
    public var isRotationEnabled: Bool {
        get { isRotationEnabledValue }
        set {
            isRotationEnabledValue = newValue
            rotationError = nil
            if newValue, rotationValue.isEmpty {
                rotationValue = defaultRotation()
            }
        }
    }

    /// The rotation switch is offered while the task repeats.
    public var canUseRotation: Bool { isRecurring }

    /// The rotation is on: `rotationEntries` replace the assignee picker.
    public var showsRotation: Bool { isRecurring && isRotationEnabledValue }

    public var showsAssigneePicker: Bool { !showsRotation }

    /// The members in the rotation, in turn order (`position`, `badge`), then the others (to add). Someone who left
    /// the group is not listed.
    public var rotationEntries: [RotationEditorEntry] {
        let directory = MemberDirectory(members: members, currentUserId: session.userId)
        let shortNames = directory.shortNames
        let included = includedRotation
        let holder = rotationHolder(of: included)
        var entries = included.enumerated().map { index, userId in
            RotationEditorEntry(
                person: directory.badge(of: userId, shortNames: shortNames),
                isIncluded: true,
                position: index + 1,
                badge: userId == holder?.id ? rotationBadge(isCurrentTurn: holder?.isCurrentTurn ?? false, userId: userId) : nil
            )
        }
        let includedIds = Set(included)
        entries += membersByName.filter { !includedIds.contains($0.user.id) }.map { member in
            RotationEditorEntry(
                person: directory.badge(of: member.user.id, shortNames: shortNames),
                isIncluded: false,
                position: nil,
                badge: nil
            )
        }
        return entries
    }

    /// Reorders the rotation: offsets among the included entries (SwiftUI `onMove`).
    public func moveRotation(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !members.isEmpty else { return }
        setRotation(Self.moving(includedRotation, fromOffsets: source, toOffset: destination))
    }

    /// Moves someone one place earlier (`offset` −1) or later (+1), for the accessibility actions.
    public func moveRotationMember(_ userId: UUID, by offset: Int) {
        var included = includedRotation
        guard let index = included.firstIndex(of: userId), included.indices.contains(index + offset) else { return }
        included.swapAt(index, index + offset)
        setRotation(included)
    }

    /// Adds a member at the end of the rotation, or takes them out (20 people at most).
    public func toggleRotationMember(_ userId: UUID) {
        guard !members.isEmpty else { return }
        var included = includedRotation
        if let index = included.firstIndex(of: userId) {
            included.remove(at: index)
        } else {
            guard members.contains(where: { $0.user.id == userId }) else { return }
            guard included.count < Limits.rotationMax else {
                rotationError = AppError.invalidRotation.messageFR
                return
            }
            included.append(userId)
        }
        setRotation(included)
    }

    /// The draft's rotation: empty unless it is on while the task repeats.
    private var draftRotation: [UUID] {
        showsRotation ? rotationValue : []
    }

    /// The members of the rotation, in order (without the people who left).
    private var includedRotation: [UUID] {
        let memberIds = Set(members.map(\.user.id))
        return rotationValue.filter { memberIds.contains($0) }
    }

    private func setRotation(_ userIds: [UUID]) {
        rotationValue = userIds
        rotationError = nil
    }

    /// The current assignees first, then the other members, each by name; at most `Limits.rotationMax`.
    private func defaultRotation() -> [UUID] {
        let byName = membersByName.map(\.user.id)
        let assigned = byName.filter { assigneeIds.contains($0) }
        let others = byName.filter { !assigneeIds.contains($0) }
        return Array((assigned + others).prefix(Limits.rotationMax))
    }

    private var membersByName: [Membership] {
        members.sorted { lhs, rhs in
            NameOrder.precedes(lhs.user.displayName, rhs.user.displayName) ?? (lhs.user.id.uuidString < rhs.user.id.uuidString)
        }
    }

    /// Who holds the turn after saving: the task's turn holder while still listed, else the first listed
    /// (docs/CONTRACTS-V2.md §5).
    private func rotationHolder(of included: [UUID]) -> (id: UUID, isCurrentTurn: Bool)? {
        if case let .edit(task) = mode, let turn = task.turnUserId, included.contains(turn) {
            return (turn, true)
        }
        return included.first.map { ($0, false) }
    }

    private func rotationBadge(isCurrentTurn: Bool, userId: UUID) -> String {
        guard isCurrentTurn else { return Self.rotationStartsBadge }
        return userId == session.userId ? Self.rotationMyTurnBadge : Self.rotationTurnBadge
    }

    // MARK: - Checklist (v2, creation only)

    /// The initial checklist is offered when creating a task (an existing task's checklist is edited on its screen).
    public var showsChecklist: Bool { !isEditing }

    /// The « Ajouter un élément » field (typing clears `checklistError`).
    public var newChecklistItemTitle: String {
        get { newChecklistItemTitleValue }
        set {
            newChecklistItemTitleValue = newValue
            if checklistError != nil { checklistError = nil }
        }
    }

    public var canAddChecklistItem: Bool {
        showsChecklist && !InputValidation.trimmed(newChecklistItemTitleValue).isEmpty
            && checklistItems.count < Limits.checklistItemsMax
    }

    /// Adds `newChecklistItemTitle` (trimmed) at the end, then clears the field; a refused title or a full list sets
    /// `checklistError`.
    @discardableResult
    public func addChecklistItem() -> Bool {
        guard showsChecklist else { return false }
        let title: String
        do {
            title = try InputValidation.checklistItemTitle(newChecklistItemTitleValue)
        } catch {
            checklistError = AppError.invalidChecklistItem.messageFR
            return false
        }
        guard checklistItems.count < Limits.checklistItemsMax else {
            checklistError = AppError.tooManyChecklistItems.messageFR
            return false
        }
        checklistItems.append(ChecklistDraftItem(title: title))
        newChecklistItemTitleValue = ""
        checklistError = nil
        return true
    }

    /// Changes an item's title (checked on save).
    public func renameChecklistItem(_ itemId: UUID, to title: String) {
        guard let index = checklistItems.firstIndex(where: { $0.id == itemId }) else { return }
        checklistItems[index].title = title
        checklistError = nil
    }

    public func removeChecklistItem(_ itemId: UUID) {
        checklistItems.removeAll { $0.id == itemId }
        checklistError = nil
    }

    /// Reorders the items (SwiftUI `onMove`).
    public func moveChecklistItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        checklistItems = Self.moving(checklistItems, fromOffsets: source, toOffset: destination)
    }

    // MARK: - Save

    /// Checks every field (same order as the server) and sets their messages. Returns true when valid.
    @discardableResult
    public func validate() -> Bool {
        titleError = Self.titleMessage(titleValue)
        detailsError = Self.detailsMessage(detailsValue)
        dueDateError = nil
        if hasDueDateValue, (try? InputValidation.dueDate(dueDateValue)) == nil {
            dueDateError = Self.invalidDueDateMessage
        }
        let rule = draftRule
        let dueAt = hasDueDateValue ? dueDateValue : nil
        recurrenceError = Self.message { _ = try InputValidation.recurrence(rule, dueAt: dueAt) }
        rotationError = rotationMessage(rule: rule)
        assigneesError = draftRotation.isEmpty && assigneeIds.count > Self.maxAssignees
            ? AppError.tooManyAssignees.messageFR : nil
        let titles = checklistItems.map(\.title)
        checklistError = isEditing ? nil : Self.message { _ = try InputValidation.checklist(titles) }
        return [titleError, detailsError, dueDateError, recurrenceError, rotationError, assigneesError, checklistError]
            .allSatisfy { $0 == nil }
    }

    /// The rotation's message: the switch on with fewer than 2 people, or a new list refused by
    /// `InputValidation.rotation`; the task's own list is sent back without checks.
    private func rotationMessage(rule: RecurrenceRule?) -> String? {
        let rotation = draftRotation
        if showsRotation, rotation.count < Limits.rotationMin { return AppError.invalidRotation.messageFR }
        if isEditing, rotation == original.rotation { return nil }
        return Self.message { _ = try InputValidation.rotation(rotation, recurrence: rule) }
    }

    /// Creates or updates the task. Returns it on success (`savedTask`), nil otherwise.
    @discardableResult
    public func save() async -> TaskItem? {
        guard !isSaving else { return nil }
        error = nil
        guard canEdit else {
            present(AppError.forbidden)
            return nil
        }
        guard validate() else { return nil }
        isSaving = true
        defer { isSaving = false }
        let draft = self.draft
        do {
            let task: TaskItem
            switch mode {
            case let .create(groupId):
                task = try await session.services.tasks.create(groupId: groupId, draft: draft)
            case let .edit(existing):
                task = try await session.services.tasks.update(taskId: existing.id, draft: draft)
            }
            savedTask = task
            session.feed.bump(groupId: groupId)
            session.feed.bumpMyTasks()
            return task
        } catch {
            guard let appError = ErrorState(from: error)?.error else { return nil }
            switch appError {
            case .invalidTitle:
                titleError = appError.messageFR
            case .invalidDetails:
                detailsError = appError.messageFR
            case .tooManyAssignees, .assigneeNotMember:
                assigneesError = appError.messageFR
                if appError == .assigneeNotMember {
                    let selected = assigneeIds
                    await reload()
                    if assigneeIds != selected {
                        // The people who left were dropped: saving again works.
                        assigneesError = Self.departedAssigneesMessage
                    }
                }
            case .invalidRecurrence, .recurrenceNeedsDueDate:
                recurrenceError = appError.messageFR
            case .invalidRotation:
                rotationError = appError.messageFR
                let sent = rotationValue
                await reload()
                let memberIds = Set(members.map(\.user.id))
                if showsRotation, sent.contains(where: { !memberIds.contains($0) }) {
                    // The people who left are dropped: saving again works.
                    rotationValue = sent.filter { memberIds.contains($0) }
                    rotationError = Self.departedRotationMessage
                }
            case .invalidChecklistItem, .tooManyChecklistItems:
                checklistError = appError.messageFR
            case .notFound where isEditing:
                isGone = true
                present(message: Self.goneMessage, error: .notFound)
            default:
                present(appError)
            }
            return nil
        }
    }

    // MARK: - Rules

    public static func titleMessage(_ title: String) -> String? {
        (try? InputValidation.taskTitle(title)) == nil ? AppError.invalidTitle.messageFR : nil
    }

    public static func detailsMessage(_ details: String) -> String? {
        do {
            _ = try InputValidation.taskDetails(details)
            return nil
        } catch {
            return AppError.invalidDetails.messageFR
        }
    }

    /// Tomorrow at 18:00 in `calendar`'s time zone.
    public static func defaultDueDate(now: Date, calendar: Calendar) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// nil when `check` passes, else the French message of its error.
    private static func message(_ check: () throws -> Void) -> String? {
        do {
            try check()
            return nil
        } catch {
            return AppError.wrap(error).messageFR
        }
    }

    /// `items` after moving the elements at `source` before the element at `destination` (SwiftUI `onMove`
    /// semantics).
    static func moving<Element>(_ items: [Element], fromOffsets source: IndexSet, toOffset destination: Int) -> [Element] {
        let offsets = source.filter { items.indices.contains($0) }
        guard !offsets.isEmpty else { return items }
        let moved = offsets.map { items[$0] }
        var remaining: [Element] = []
        for (index, item) in items.enumerated() where !offsets.contains(index) {
            remaining.append(item)
        }
        let insertion = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moved, at: min(max(insertion, 0), remaining.count))
        return remaining
    }
}
