import Foundation
import Testing
@testable import TeamTasksCore

// docs/CONTRACTS-V2.md: palette, models, errors, permissions and onboarding of the v2 core.

@Suite struct ColorKeyTests {
    @Test func paletteKeysAreTheStoredTexts() {
        #expect(ColorKey.allCases.map(\.rawValue) == ["indigo", "violet", "blue", "teal", "green", "amber", "orange", "coral", "pink"])
        #expect(ColorKey.automaticOrder == [.blue, .indigo, .violet, .pink, .orange, .teal, .green, .coral, .amber])
        #expect(Set(ColorKey.automaticOrder) == Set(ColorKey.allCases))
    }

    /// Reference values computed independently (djb2 over the uppercase uuid string, UInt64 wrapping, % 9).
    static let references: [(String, ColorKey)] = [
        ("11111111-1111-4111-8111-111111111111", ColorKey.coral), // v1 hue: red
        ("22222222-2222-4222-8222-222222222222", ColorKey.indigo),
        ("33333333-3333-4333-8333-333333333333", ColorKey.green),
        ("a0000000-0000-4000-8000-000000000001", ColorKey.pink), // lowercase input: the hash reads the uppercase form
        ("A0000000-0000-4000-8000-000000000002", ColorKey.orange),
        ("00000000-0000-0000-0000-000000000000", ColorKey.green),
        ("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", ColorKey.teal),
    ]

    @Test(arguments: ColorKeyTests.references)
    func automaticColorIsTheDjb2Hash(_ uuid: String, _ expected: ColorKey) throws {
        let id = try #require(UUID(uuidString: uuid))
        #expect(ColorKey.automatic(for: id) == expected)
    }

    @Test func resolvedColors() throws {
        let id = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        #expect(ColorKey.resolved(nil, for: id) == .coral)
        #expect(ColorKey.resolved(.teal, for: id) == .teal)
        #expect(UserProfile(id: id, displayName: "Camille").resolvedColor == .coral)
        #expect(UserProfile(id: id, displayName: "Camille", avatarColor: .pink).resolvedColor == .pink)
        let date = Date(timeIntervalSince1970: 0)
        #expect(TeamGroup(id: id, name: "G", createdBy: nil, createdAt: date, lastActivityAt: date).resolvedColor == .coral)
        #expect(TeamGroup(id: id, name: "G", createdBy: nil, createdAt: date, lastActivityAt: date, color: .blue).resolvedColor == .blue)
    }
}

@Suite struct V2ModelTests {
    typealias F = LogicFixtures

    /// The v1 initializers still compile and leave every v2 field empty.
    @Test func v1InitializersHaveEmptyV2Fields() {
        let date = F.date(2026, 9, 24)
        let profile = UserProfile(id: F.me, displayName: "Camille")
        #expect(profile.avatarColor == nil && profile.avatarEmoji == nil && profile.onboardedAt == nil && profile.createdAt == nil)
        let group = TeamGroup(id: F.groupA, name: "G", createdBy: F.me, createdAt: date, lastActivityAt: date)
        #expect(group.color == nil && group.emoji == nil)
        let task = TaskItem(id: F.uuid(1), groupId: F.groupA, title: "T", createdBy: F.me, createdAt: date, updatedAt: date)
        #expect(task.recurrence == nil && task.rotation.isEmpty && task.turnUserId == nil && task.seriesId == nil)
        #expect(task.nextOccurrenceId == nil && task.completedBy == nil && task.checklist.isEmpty)
        #expect(task.groupColor == nil && task.groupEmoji == nil)
        #expect(!task.isRecurring && !task.hasRotation)
        let draft = TaskDraft(title: "T")
        #expect(draft.recurrence == nil && draft.rotation.isEmpty && draft.checklist.isEmpty)
        let event = AssignmentEvent(
            taskId: F.uuid(1), groupId: F.groupA, taskTitle: "T", groupName: "G", assignedBy: nil, assignedAt: date, dueAt: nil
        )
        #expect(!event.taskHasRotation && !event.isRotationTurn)
    }

    /// A full edit starts from the task: recurrence and rotation are copied, the checklist is edited item by item.
    @Test func draftOfATaskCopiesTheRecurrenceAndTheRotation() {
        let date = F.date(2026, 9, 24)
        let rule = RecurrenceRule(frequency: .monthly, timeZoneId: "Europe/Paris", monthDay: 31)
        let task = TaskItem(
            id: F.uuid(1), groupId: F.groupA, title: "Poubelles", details: "Jaunes", priority: .high, dueAt: date,
            createdBy: F.me, createdAt: date, updatedAt: date, assigneeIds: [F.other],
            recurrence: rule, rotation: [F.other, F.me], turnUserId: F.other, seriesId: F.uuid(1),
            checklist: [ChecklistItem(id: F.uuid(9), title: "Sacs", position: 1)]
        )
        #expect(task.isRecurring && task.hasRotation)
        let draft = TaskDraft(task: task)
        #expect(draft == TaskDraft(
            title: "Poubelles", details: "Jaunes", priority: .high, dueAt: date, assigneeIds: [F.other],
            recurrence: rule, rotation: [F.other, F.me], checklist: []
        ))
    }

    @Test func checklistDisplayOrderIsPositionThenId() {
        let a = ChecklistItem(id: F.uuid(2), title: "A", position: 3)
        let b = ChecklistItem(id: F.uuid(1), title: "B", position: 1)
        let c = ChecklistItem(id: F.uuid(3), title: "C", position: 3, isDone: true, doneAt: F.date(2026, 9, 24), doneBy: F.me)
        #expect(ChecklistItem.sorted([c, a, b]).map(\.title) == ["B", "A", "C"])
    }

    @Test func activityKindsAreTheStoredTexts() throws {
        #expect(ActivityEvent.Kind.allCases.map(\.rawValue) == [
            "task_created", "task_completed", "turn_started", "checklist_item_done", "member_joined", "member_left",
        ])
        // A kind added by a later version is unknown: list reads leave its rows out.
        #expect(ActivityEvent.Kind(rawValue: "task_renamed") == nil)
        let decoded = try JSONDecoder().decode([ActivityEvent.Kind].self, from: Data(#"["turn_started"]"#.utf8))
        #expect(decoded == [.turnStarted])
    }

    @Test func rotationTurnsAreServerAssignmentsOnRotatingTasks() {
        let date = F.date(2026, 9, 24)
        func event(by assigner: UUID?, rotation: Bool) -> AssignmentEvent {
            AssignmentEvent(taskId: F.uuid(1), groupId: F.groupA, taskTitle: "T", groupName: "G", assignedBy: assigner,
                            assignedAt: date, dueAt: nil, taskHasRotation: rotation)
        }
        #expect(event(by: nil, rotation: true).isRotationTurn)
        #expect(!event(by: F.other, rotation: true).isRotationTurn) // first turn, given by the editor
        #expect(!event(by: nil, rotation: false).isRotationTurn)
    }
}

@Suite struct V2ErrorTests {
    @Test func v2MessageCodes() {
        let expected: [String: AppError] = [
            "invalid_color": .invalidAppearance,
            "invalid_emoji": .invalidAppearance,
            "invalid_recurrence": .invalidRecurrence,
            "recurrence_requires_due_date": .recurrenceNeedsDueDate,
            "invalid_rotation": .invalidRotation,
            "invalid_item_title": .invalidChecklistItem,
            "too_many_items": .tooManyChecklistItems,
            "item_not_found": .notFound,
        ]
        for (code, error) in expected {
            #expect(BackendErrorMapper.map(code: "P0001", message: code, httpStatus: 400) == error, "\(code)")
        }
        // `set_checklist_item_done` with a NULL `p_done`.
        #expect(BackendErrorMapper.map(code: "23502", message: "invalid_input", httpStatus: 400) == .invalidInput)
    }

    @Test func v2FrenchMessages() {
        #expect(AppError.invalidAppearance.messageFR == "Couleur ou emoji invalide.")
        #expect(AppError.invalidRecurrence.messageFR == "Répétition invalide.")
        #expect(AppError.recurrenceNeedsDueDate.messageFR == "Choisis une échéance pour répéter la tâche.")
        #expect(AppError.invalidRotation.messageFR == "Le tour de rôle demande de 2 à 20 membres du groupe.")
        #expect(AppError.invalidChecklistItem.messageFR == "Un élément doit contenir entre 1 et 200 caractères.")
        #expect(AppError.tooManyChecklistItems.messageFR == "30 éléments au maximum.")
    }

    @Test func limits() {
        #expect(Limits.checklistItemsMax == 30)
        #expect(Limits.checklistItemTitleMax == 200)
        #expect(Limits.rotationMin == 2)
        #expect(Limits.rotationMax == 20)
        #expect(Limits.repeatIntervalMax == 52)
        #expect(Limits.emojiCodePointsMax == 16)
        #expect(Limits.activityFeedMax == 50)
        #expect(Limits.activityRetentionDays == 90)
    }
}

@Suite struct V2PermissionsTests {
    let admin = UUID()
    let creator = UUID()
    let assignee = UUID()
    let other = UUID()

    var task: TaskItem {
        TaskItem(
            id: UUID(), groupId: UUID(), title: "Poubelles",
            createdBy: creator, createdAt: .now, updatedAt: .now, assigneeIds: [assignee]
        )
    }

    /// docs/CONTRACTS-V2.md §4.
    @Test func matrix() {
        // (user, role) -> (recurrence / rotation, checklist)
        let cases: [(UUID, MemberRole?, Bool, Bool)] = [
            (admin, .admin, true, true),
            (creator, .member, true, true),
            (assignee, .member, false, true),
            (other, .member, false, false),
            (creator, nil, false, false),
            (assignee, nil, false, false),
        ]
        for (user, role, recurrence, checklist) in cases {
            #expect(TaskPermissions.canEditRecurrence(task, userId: user, role: role) == recurrence)
            #expect(TaskPermissions.canManageChecklist(task, userId: user, role: role) == checklist)
        }
        #expect(GroupPermissions.canSetAppearance(role: .admin))
        #expect(!GroupPermissions.canSetAppearance(role: .member))
        #expect(!GroupPermissions.canSetAppearance(role: nil))
        #expect(GroupPermissions.canSeeActivity(role: .member))
        #expect(GroupPermissions.canSeeActivity(role: .admin))
        #expect(!GroupPermissions.canSeeActivity(role: nil))
    }
}

@Suite struct OnboardingPolicyTests {
    typealias F = LogicFixtures

    static let now = F.date(2026, 9, 24, 10)

    private func profile(createdAt: Date?, onboardedAt: Date? = nil) -> UserProfile {
        UserProfile(id: F.me, displayName: "Camille", onboardedAt: onboardedAt, createdAt: createdAt)
    }

    @Test func shownToNewAccountsOnly() {
        let now = Self.now
        #expect(OnboardingPolicy.shouldShow(profile: profile(createdAt: now), now: now))
        #expect(OnboardingPolicy.shouldShow(profile: profile(createdAt: now.addingTimeInterval(-7 * 86_400 + 1)), now: now))
        #expect(!OnboardingPolicy.shouldShow(profile: profile(createdAt: now.addingTimeInterval(-7 * 86_400)), now: now))
        #expect(!OnboardingPolicy.shouldShow(profile: profile(createdAt: now.addingTimeInterval(-30 * 86_400)), now: now))
        // Completed or skipped, or an unknown creation date.
        #expect(!OnboardingPolicy.shouldShow(profile: profile(createdAt: now, onboardedAt: now), now: now))
        #expect(!OnboardingPolicy.shouldShow(profile: profile(createdAt: nil), now: now))
    }

    @Test func stepsSkipWhatIsAlreadyDone() {
        #expect(OnboardingPolicy.steps(hasGroups: false, notifications: .notDetermined)
            == [.welcome, .avatar, .firstGroup, .notifications])
        #expect(OnboardingPolicy.steps(hasGroups: true, notifications: .notDetermined) == [.welcome, .avatar, .notifications])
        #expect(OnboardingPolicy.steps(hasGroups: false, notifications: .authorized) == [.welcome, .avatar, .firstGroup])
        #expect(OnboardingPolicy.steps(hasGroups: true, notifications: .denied) == [.welcome, .avatar])
    }
}
