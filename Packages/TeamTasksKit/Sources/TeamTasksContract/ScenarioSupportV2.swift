import Foundation
import TeamTasksCore

// Helpers of the v2 scenarios (docs/CONTRACTS-V2.md). Like the v1 ones, they only use the public service API and
// compare server timestamps with each other: the backend's clock is read from the rows it returns (`createdAt`,
// `completedAt`, `lastActivityAt`…), never from the device. Recurring tasks are due in 2041 unless a scenario needs
// another date, so that completing them is always « early » (the next due date does not depend on the backend's now).

extension Verify {
    /// A profile read by `myProfile()` right after the sign-up: no avatar, not onboarded (`onboardedAt` nil), with the
    /// creation date the server set.
    static func newProfile(
        _ profile: UserProfile,
        id: UUID,
        displayName: String,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws {
        let createdAt = try unwrap(profile.createdAt, "\(message()): createdAt", file: file, line: line)
        try equal(
            profile, UserProfile(id: id, displayName: displayName, createdAt: createdAt), message(), file: file, line: line
        )
    }
}

/// Canonical IANA zone names: the server (`pg_timezone_names`) and the client validation
/// (`InputValidation.isValidTimeZoneId`) both accept them.
enum Zone {
    static let paris = "Europe/Paris"
    static let utc = "UTC"
    static let tokyo = "Asia/Tokyo"
    static let newYork = "America/New_York"

    /// The French calendar of the app in Europe/Paris (weeks start on Monday).
    static let parisCalendar = Calendar.frenchGregorian(timeZone: TimeZone(identifier: paris) ?? .gmt)
}

/// Recurrence rules as a client builds them (`monthDay` is the server's).
enum Rule {
    static func daily(interval: Int = 1, tz: String = Zone.paris) -> RecurrenceRule {
        RecurrenceRule(frequency: .daily, interval: interval, timeZoneId: tz)
    }

    static func weekly(interval: Int = 1, weekdays: Set<Int>? = nil, tz: String = Zone.paris) -> RecurrenceRule {
        RecurrenceRule(frequency: .weekly, interval: interval, weekdays: weekdays, timeZoneId: tz)
    }

    static func monthly(interval: Int = 1, tz: String = Zone.paris) -> RecurrenceRule {
        RecurrenceRule(frequency: .monthly, interval: interval, timeZoneId: tz)
    }
}

/// A UTC instant written like the test vectors of docs/CONTRACTS-V2.md §6 (`2026-09-24T18:00:00Z`).
func utc(_ text: String, file: StaticString = #fileID, line: UInt = #line) throws -> Date {
    try Verify.unwrap(ISO8601DateFormatter().date(from: text), "instant \(text)", file: file, line: line)
}

/// The comparable part of an activity event (`id` and `createdAt` are checked separately).
struct EventShape: Equatable, CustomStringConvertible {
    let kind: ActivityEvent.Kind
    let actorId: UUID?
    let subjectId: UUID?
    let taskId: UUID?
    let taskTitle: String?
    let itemTitle: String?

    init(
        _ kind: ActivityEvent.Kind,
        actor: UUID? = nil,
        subject: UUID? = nil,
        task: UUID? = nil,
        title: String? = nil,
        item: String? = nil
    ) {
        self.kind = kind
        actorId = actor
        subjectId = subject
        taskId = task
        taskTitle = title
        itemTitle = item
    }

    init(_ event: ActivityEvent) {
        self.init(
            event.kind, actor: event.actorId, subject: event.subjectId, task: event.taskId, title: event.taskTitle,
            item: event.itemTitle
        )
    }

    var description: String {
        func short(_ id: UUID?) -> String { id.map { String($0.uuidString.prefix(8)) } ?? "nil" }
        var text = "\(kind.rawValue) actor=\(short(actorId)) subject=\(short(subjectId))"
        if let taskId { text += " task=\(short(taskId))" }
        if let taskTitle { text += " «\(taskTitle)»" }
        if let itemTitle { text += " «\(itemTitle)»" }
        return text
    }
}

func isAssignment(_ event: RealtimeEvent) -> Bool {
    if case .assigned = event { return true }
    return false
}

/// The `task_assignees` row behind an assignment event (the event also embeds the task's current title and due date).
struct AssignmentRow: Equatable, CustomStringConvertible {
    let taskId: UUID
    let assignedBy: UUID?
    let assignedAt: Date

    var description: String {
        "row(task=\(taskId.uuidString.prefix(8)), by=\(assignedBy.map { String($0.uuidString.prefix(8)) } ?? "nil"), at=\(assignedAt))"
    }
}

extension AssignmentEvent {
    var row: AssignmentRow {
        AssignmentRow(taskId: taskId, assignedBy: assignedBy, assignedAt: assignedAt)
    }
}

extension ContractUser {
    /// Creates a group with its appearance (v2 `createGroup`); `members` then join it, in order.
    func makeGroup(
        _ base: String = "Groupe", color: ColorKey?, emoji: String?, joinedBy members: [ContractUser] = []
    ) async throws -> GroupFixture {
        let name = Unique.name(base)
        let summary = try await Verify.step("\(displayName) creates group \(name) with an appearance") {
            try await groups.createGroup(name: name, color: color, emoji: emoji)
        }
        let code = try await Verify.step("\(displayName) reads the invite code") {
            try await groups.inviteCode(groupId: summary.id)
        }
        let fixture = GroupFixture(id: summary.id, name: name, code: code)
        for member in members {
            let result = try await member.join(fixture)
            try Verify.that(!result.alreadyMember, "\(member.displayName) should be a new member of \(name)")
        }
        return fixture
    }

    /// Creates a recurring task titled `"<base> <token>"`, optionally « à tour de rôle » and with a checklist.
    func makeRecurringTask(
        in groupId: UUID,
        _ base: String = "Série",
        rule: RecurrenceRule,
        dueAt: Date,
        rotation: [ContractUser] = [],
        assignees: [ContractUser] = [],
        checklist: [String] = []
    ) async throws -> TaskItem {
        let draft = TaskDraft(
            title: Unique.name(base), dueAt: dueAt, assigneeIds: Set(assignees.map(\.id)), recurrence: rule,
            rotation: rotation.map(\.id), checklist: checklist
        )
        return try await Verify.step("\(displayName) creates the recurring task \(draft.title)") {
            try await tasks.create(groupId: groupId, draft: draft)
        }
    }

    /// Completes `task` and returns the completed row (as `setStatus` returned it) and its next occurrence, read back
    /// with `task(id:)`.
    func completeAndReadNext(_ task: TaskItem) async throws -> (done: TaskItem, next: TaskItem) {
        let done = try await Verify.step("\(displayName) completes \(task.title)") {
            try await tasks.setStatus(taskId: task.id, status: .done)
        }
        let nextId = try Verify.unwrap(done.nextOccurrenceId, "the next occurrence of \(task.title)")
        let next = try await Verify.step("\(displayName) reads the next occurrence of \(task.title)") {
            try await tasks.task(id: nextId)
        }
        return (done, next)
    }

    /// This user's assignment event for `taskId` made by someone else (or by nobody), if any.
    func assignmentIfAny(of taskId: UUID) async throws -> AssignmentEvent? {
        try await tasks.assignments(since: Fixed.longAgo).first { $0.taskId == taskId }
    }

    /// The group's activity feed as this user reads it.
    func feed(of groupId: UUID) async throws -> [ActivityEvent] {
        try await Verify.step("\(displayName) reads the activity of \(groupId)") {
            try await groups.activity(groupId: groupId)
        }
    }
}
