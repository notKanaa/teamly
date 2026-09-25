import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

// v2 task screens: the checklist, the repetition and the rotation on the task screen and in the editor, and
// « Mes tâches ».

@MainActor
@Suite struct TaskDetailV2Tests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks
    typealias Items = DemoData.Showcase.ChecklistIDs

    @Test func repetitionAndRotation() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.sortirPoubelles)
        await model.load()
        #expect(model.recurrenceText == "Chaque semaine, le jeudi")
        #expect(model.upcomingDueTexts == ["Jeudi 1er octobre à 20:00", "Jeudi 8 octobre à 20:00", "Jeudi 15 octobre à 20:00"])
        #expect(model.upcomingDueDates.count == TaskDetailViewModel.upcomingCount)
        #expect(model.rotationEntries.map(\.person.shortName) == ["Camille", "Lucas", "Inès"])
        #expect(model.rotationEntries.map(\.isCurrentTurn) == [true, false, false])
        #expect(model.rotationText == "C’est ton tour, puis Lucas, puis Inès.")
        #expect(model.assignees.map(\.shortName) == ["Camille"])
        #expect(model.checklist.isEmpty)
        #expect(model.checklistProgress == nil)
        #expect(model.canManageChecklist)
        #expect(model.groupAppearance == nil)

        // Lucas's turn, seen by Camille.
        #expect(await model.setStatus(.done))
        #expect(model.upcomingDueDates.isEmpty)
        let next = try #require(model.task?.nextOccurrenceId)
        let nextModel = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: next)
        await nextModel.load()
        #expect(nextModel.rotationText == "C’est au tour de Lucas, puis Inès, puis toi.")
        #expect(nextModel.rotationEntries.first?.isCurrentTurn == true)

        let plain = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.payerLoyer)
        await plain.load()
        #expect(plain.recurrenceText == nil)
        #expect(plain.upcomingDueDates.isEmpty)
        #expect(plain.rotationEntries.isEmpty)
        #expect(plain.rotationText == nil)
    }

    /// Handed over by « Mes tâches », the task keeps its group's badge across reloads.
    @Test func groupBadgeFromMyTasks() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let mine = try #require(try await harness.services.tasks.myTasks(includeDone: false).first { $0.id == T.faireCourses })
        let model = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.faireCourses, task: mine)
        await model.load()
        #expect(model.groupName == "Coloc' rue des Lilas")
        #expect(model.groupAppearance == AvatarAppearance(color: .coral, emoji: "\u{1F3E0}", initials: "CR"))
    }

    @Test func checklistOperations() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.faireCourses)
        await model.load()
        #expect(model.checklist.map(\.title) == ["Lait", "Pâtes", "Lessive", "Papier toilette"])
        #expect(model.checklistProgress?.text == "2 sur 4")
        #expect(model.canManageChecklist)

        // Checked at once, then saved.
        harness.faults.hold(.setChecklistItemDone)
        let check = Task { await model.toggleChecklistItem(Items.lessive) }
        await VMWait.until("request sent") { harness.faults.waiting(.setChecklistItemDone) == 1 }
        #expect(model.checklist.first { $0.id == Items.lessive }?.isDone == true)
        #expect(model.checklistProgress?.text == "3 sur 4")
        #expect(model.busyChecklistItemIds == [Items.lessive])
        let revision = session.feed.groupRevision(F.lilas)
        harness.faults.release(.setChecklistItemDone)
        #expect(await check.value)
        #expect(model.busyChecklistItemIds.isEmpty)
        #expect(model.checklist.first { $0.id == Items.lessive }?.doneBy == F.camille.id)
        #expect(session.feed.groupRevision(F.lilas) > revision)
        let stored = try await harness.services.tasks.task(id: T.faireCourses)
        #expect(stored.checklist.first { $0.id == Items.lessive }?.isDone == true)

        // Refused: rolled back, with the reason.
        harness.faults.fail(.setChecklistItemDone, with: AppError.network)
        harness.faults.hold(.setChecklistItemDone)
        let uncheck = Task { await model.toggleChecklistItem(Items.lait) }
        await VMWait.until("request sent") { harness.faults.waiting(.setChecklistItemDone) == 1 }
        #expect(model.checklist.first { $0.id == Items.lait }?.isDone == false)
        harness.faults.release(.setChecklistItemDone)
        #expect(await !uncheck.value)
        #expect(model.checklist.first { $0.id == Items.lait }?.isDone == true)
        #expect(model.errorMessage == AppError.network.messageFR)
        #expect(await model.setChecklistItem(Items.lait, done: true) == false) // already checked: nothing to do
        model.dismissError()

        // Add, rename, delete.
        model.newChecklistItemTitle = "  Café  "
        #expect(model.canAddChecklistItem)
        #expect(await model.addChecklistItem())
        #expect(model.newChecklistItemTitle.isEmpty)
        let cafe = try #require(model.checklist.last)
        #expect(cafe.title == "Café")
        #expect(cafe.position == 5)
        #expect(await model.renameChecklistItem(cafe.id, to: " Café moulu "))
        #expect(model.checklist.last?.title == "Café moulu")
        #expect(await model.renameChecklistItem(cafe.id, to: "Café moulu"))
        #expect(harness.faults.calls(.renameChecklistItem) == 1)
        #expect(await !model.renameChecklistItem(cafe.id, to: "   "))
        #expect(model.checklistError == AppError.invalidChecklistItem.messageFR)
        #expect(await model.deleteChecklistItem(cafe.id))
        #expect(!model.checklist.contains { $0.id == cafe.id })
        #expect(try await harness.services.tasks.task(id: T.faireCourses).checklist.count == 4)

        // A blank title is refused before any request; typing clears the message.
        model.newChecklistItemTitle = "   "
        #expect(!model.canAddChecklistItem)
        #expect(await !model.addChecklistItem())
        #expect(model.checklistError == AppError.invalidChecklistItem.messageFR)
        model.newChecklistItemTitle = "Beurre"
        #expect(model.checklistError == nil)
        #expect(harness.faults.calls(.addChecklistItem) == 1)
    }

    /// A reload while a check is in progress shows the item as the user set it.
    @Test func aReloadDuringACheckKeepsTheUsersChoice() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.faireCourses)
        await model.load()
        harness.faults.hold(.setChecklistItemDone)
        let check = Task { await model.toggleChecklistItem(Items.papierToilette) }
        await VMWait.until("request sent") { harness.faults.waiting(.setChecklistItemDone) == 1 }
        session.feed.bump(groupId: F.lilas)
        await model.load()
        #expect(harness.faults.calls(.task) == 2)
        #expect(model.checklist.first { $0.id == Items.papierToilette }?.isDone == true)
        harness.faults.release(.setChecklistItemDone)
        #expect(await check.value)
    }

    @Test func itemsDeletedElsewhereAndRights() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.faireCourses)
        await model.load()
        try await harness.device(F.lucas).tasks.deleteChecklistItem(itemId: Items.lessive)
        #expect(await !model.toggleChecklistItem(Items.lessive))
        #expect(!model.checklist.contains { $0.id == Items.lessive })
        #expect(model.errorMessage == AppError.notFound.messageFR)
        model.dismissError()
        // Deleting an item already deleted elsewhere is what was asked for.
        try await harness.device(F.lucas).tasks.deleteChecklistItem(itemId: Items.pates)
        #expect(await model.deleteChecklistItem(Items.pates))
        #expect(model.error == nil)
        #expect(model.checklist.map(\.title) == ["Lait", "Papier toilette"])

        // « Créer l'affiche » (Lucas's, assigned to Lucas): Camille, a member, sees it but cannot touch the checklist.
        let affiche = TaskDetailViewModel(session: session, groupId: F.sport, taskId: T.creerAffiche)
        await affiche.load()
        #expect(!affiche.canManageChecklist)
        affiche.newChecklistItemTitle = "Imprimer"
        #expect(!affiche.canAddChecklistItem)
        #expect(await !affiche.addChecklistItem())
        #expect(affiche.errorMessage == AppError.forbidden.messageFR)
        #expect(harness.faults.calls(.addChecklistItem) == 0)
    }
}

@MainActor
@Suite struct TaskEditorV2Tests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    /// Brief note 1: the edit starts from `TaskDraft(task:)`: an untouched editor has no change, and a title change
    /// keeps the recurrence and the rotation.
    @Test func editingARotatingTaskKeepsItsV2Fields() async throws {
        let harness = VMHarness(.showcase)
        let original = try await harness.services.tasks.task(id: T.sortirPoubelles)
        let editor = TaskEditorViewModel(session: harness.makeSession(), task: original)
        await editor.load()
        #expect(!editor.hasChanges)
        #expect(editor.draft == TaskDraft(task: original))
        #expect(editor.repeatFrequency == .weekly)
        #expect(editor.repeatInterval == 1)
        #expect(editor.isRecurring && editor.canUseRotation && editor.isRotationEnabled)
        #expect(editor.showsRotation && !editor.showsAssigneePicker)
        #expect(editor.isDueDateRequired)
        #expect(editor.recurrenceSummary == "Chaque semaine, le jeudi")
        #expect(editor.weekdayOptions.filter(\.isSelected).map(\.id) == [4])
        #expect(editor.rotationEntries.map(\.person.shortName) == ["Inès", "Camille", "Lucas"])
        #expect(editor.rotationEntries.map(\.badge) == [nil, "C’est ton tour", nil])
        #expect(editor.rotationEntries.map(\.position) == [1, 2, 3])
        #expect(!editor.showsChecklist)

        editor.title = "Sortir toutes les poubelles"
        #expect(editor.hasChanges)
        let saved = try #require(await editor.save())
        #expect(saved.title == "Sortir toutes les poubelles")
        #expect(saved.recurrence == original.recurrence)
        #expect(saved.rotation == original.rotation)
        #expect(saved.turnUserId == F.camille.id)
        #expect(saved.assigneeIds == [F.camille.id])
    }

    /// A monthly task keeps the server's month day while its local due date does not change.
    @Test func editingAMonthlyTask() async throws {
        let harness = VMHarness()
        let created = try await harness.services.tasks.create(
            groupId: F.lilas,
            draft: TaskDraft(
                title: "Loyer", dueAt: F.date(2026, 10, 31, 9),
                recurrence: RecurrenceRule(frequency: .monthly, timeZoneId: "Europe/Paris")
            )
        )
        #expect(created.recurrence?.monthDay == 31)
        let editor = TaskEditorViewModel(session: harness.makeSession(), task: created)
        #expect(!editor.hasChanges)
        #expect(editor.recurrenceSummary == "Chaque mois, le 31 ou le dernier jour du mois")
        editor.repeatInterval = 2
        #expect(editor.draft.recurrence?.monthDay == 31)
        #expect(editor.recurrenceSummary == "Tous les 2 mois, le 31 ou le dernier jour du mois")
        editor.repeatInterval = 1
        #expect(!editor.hasChanges)
        editor.dueDate = F.date(2026, 10, 30, 9)
        #expect(editor.draft.recurrence?.monthDay == nil)
        #expect(editor.recurrenceSummary == "Chaque mois, le 30 ou le dernier jour du mois")
        editor.repeatInterval = 99
        #expect(editor.repeatInterval == 52)
        editor.repeatInterval = 0
        #expect(editor.repeatInterval == 1)
        #expect(editor.repeatIntervalRange == 1...52)
    }

    /// A new repeating task: the frequency turns the due date on and the rule takes the calendar's time zone; the
    /// days, the interval, the rotation (the assignees first) and the checklist are sent.
    @Test func createsARepeatingTaskWithARotationAndAChecklist() async throws {
        let harness = VMHarness()
        let editor = TaskEditorViewModel(session: harness.makeSession(), groupId: F.lilas)
        await editor.load()
        editor.title = "Ménage du samedi"
        #expect(!editor.hasDueDate && !editor.isRecurring && !editor.canUseRotation)
        #expect(editor.repeatFrequencyOptions.map(\.label) == ["Jamais", "Jour", "Semaine", "Mois"])
        #expect(editor.recurrenceSummary == nil)
        editor.repeatFrequency = .weekly
        #expect(editor.hasDueDate)
        #expect(editor.isDueDateRequired && editor.canUseRotation)
        #expect(!editor.showsRotation)
        editor.dueDate = F.date(2026, 9, 26, 11)
        #expect(editor.weekdayOptions.map(\.letter) == ["L", "M", "M", "J", "V", "S", "D"])
        #expect(editor.weekdayOptions.map(\.name).first == "Lundi")
        #expect(editor.weekdayOptions.filter(\.isSelected).map(\.id) == [6])
        #expect(editor.recurrenceSummary == "Chaque semaine, le samedi")
        editor.toggleWeekday(3)
        #expect(editor.recurrenceSummary == "Chaque semaine, le mercredi et le samedi")
        editor.toggleWeekday(3)
        #expect(editor.draft.recurrence?.weekdays == nil)
        editor.toggleWeekday(6)
        #expect(editor.weekdayOptions.filter(\.isSelected).map(\.id) == [6])
        editor.toggleWeekday(2)
        editor.toggleWeekday(6)
        #expect(editor.draft.recurrence?.weekdays == [2])
        editor.repeatInterval = 2
        #expect(editor.recurrenceSummary == "Toutes les 2 semaines, le mardi")
        #expect(editor.draft.recurrence?.timeZoneId == "Europe/Paris")

        editor.toggleAssignee(F.lucas.id)
        editor.isRotationEnabled = true
        #expect(editor.showsRotation && !editor.showsAssigneePicker)
        #expect(editor.rotationEntries.map(\.person.shortName) == ["Lucas", "Camille", "Inès"])
        #expect(editor.rotationEntries.map(\.position) == [1, 2, 3])
        #expect(editor.rotationEntries.map(\.badge) == ["Commence", nil, nil])
        editor.moveRotation(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(editor.rotationEntries.map(\.person.shortName) == ["Inès", "Lucas", "Camille"])
        editor.moveRotationMember(F.camille.id, by: -1)
        #expect(editor.rotationEntries.map(\.person.shortName) == ["Inès", "Camille", "Lucas"])
        editor.toggleRotationMember(F.lucas.id)
        #expect(editor.rotationEntries.filter(\.isIncluded).map(\.person.shortName) == ["Inès", "Camille"])
        #expect(editor.rotationEntries.last?.isIncluded == false)
        #expect(editor.rotationEntries.last?.position == nil)
        editor.toggleRotationMember(F.lucas.id)
        #expect(editor.rotationEntries.filter(\.isIncluded).map(\.person.shortName) == ["Inès", "Camille", "Lucas"])

        #expect(editor.showsChecklist)
        editor.newChecklistItemTitle = " Aspirateur "
        #expect(editor.addChecklistItem())
        editor.newChecklistItemTitle = "Serpillière"
        #expect(editor.addChecklistItem())
        editor.newChecklistItemTitle = "Salle de bain"
        #expect(editor.addChecklistItem())
        editor.moveChecklistItems(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(editor.checklistItems.map(\.title) == ["Salle de bain", "Aspirateur", "Serpillière"])
        #expect(editor.hasChanges)

        let task = try #require(await editor.save())
        #expect(task.recurrence == RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [2], timeZoneId: "Europe/Paris"))
        #expect(task.dueAt == F.date(2026, 9, 26, 11))
        #expect(task.rotation == [F.ines.id, F.camille.id, F.lucas.id])
        #expect(task.turnUserId == F.ines.id)
        #expect(task.assigneeIds == [F.ines.id])
        #expect(task.checklist.map(\.title) == ["Salle de bain", "Aspirateur", "Serpillière"])
    }

    /// A repetition needs a due date and a rotation 2 people: the fields say so; the server's errors land on them.
    @Test func repetitionErrors() async throws {
        let harness = VMHarness()
        let editor = TaskEditorViewModel(session: harness.makeSession(), groupId: F.lilas)
        await editor.load()
        editor.title = "Arroser"
        editor.repeatFrequency = .daily
        editor.hasDueDate = false
        #expect(editor.recurrenceError == "Choisissez une échéance pour répéter la tâche.")
        #expect(await editor.save() == nil)
        #expect(editor.recurrenceError == AppError.recurrenceNeedsDueDate.messageFR)
        #expect(harness.faults.calls(.createTask) == 0)
        editor.hasDueDate = true
        #expect(editor.recurrenceError == nil)

        editor.isRotationEnabled = true
        for entry in editor.rotationEntries.dropFirst() {
            editor.toggleRotationMember(entry.id)
        }
        #expect(editor.rotationEntries.filter(\.isIncluded).count == 1)
        #expect(await editor.save() == nil)
        #expect(editor.rotationError == AppError.invalidRotation.messageFR)
        #expect(harness.faults.calls(.createTask) == 0)

        // « Jamais »: a plain task, with its assignees.
        editor.repeatFrequency = .never
        #expect(!editor.showsRotation && editor.showsAssigneePicker)
        #expect(editor.rotationError == nil)
        editor.toggleAssignee(F.lucas.id)
        let plain = try #require(await editor.save())
        #expect(plain.recurrence == nil && plain.rotation.isEmpty && plain.assigneeIds == [F.lucas.id])

        let other = TaskEditorViewModel(session: harness.makeSession(), groupId: F.lilas)
        other.title = "Tâche"
        other.repeatFrequency = .weekly
        harness.faults.fail(.createTask, with: AppError.invalidRecurrence)
        #expect(await other.save() == nil)
        #expect(other.recurrenceError == "Répétition invalide.")
        other.newChecklistItemTitle = "Éponge"
        #expect(other.addChecklistItem())
        harness.faults.fail(.createTask, with: AppError.tooManyChecklistItems)
        #expect(await other.save() == nil)
        #expect(other.checklistError == "30 éléments au maximum.")
    }

    @Test func initialChecklistLimits() {
        let editor = TaskEditorViewModel(session: VMHarness().makeSession(), groupId: F.lilas)
        editor.newChecklistItemTitle = "   "
        #expect(!editor.canAddChecklistItem)
        #expect(!editor.addChecklistItem())
        #expect(editor.checklistError == AppError.invalidChecklistItem.messageFR)
        editor.newChecklistItemTitle = "x"
        #expect(editor.checklistError == nil)
        for index in 1...Limits.checklistItemsMax {
            editor.newChecklistItemTitle = "Élément \(index)"
            #expect(editor.addChecklistItem())
        }
        editor.newChecklistItemTitle = "Un de trop"
        #expect(!editor.canAddChecklistItem)
        #expect(!editor.addChecklistItem())
        #expect(editor.checklistError == AppError.tooManyChecklistItems.messageFR)
        editor.removeChecklistItem(editor.checklistItems[0].id)
        #expect(editor.checklistItems.count == Limits.checklistItemsMax - 1)
        editor.renameChecklistItem(editor.checklistItems[0].id, to: " ")
        editor.title = "Grand ménage"
        #expect(!editor.validate())
        #expect(editor.checklistError == AppError.invalidChecklistItem.messageFR)
    }

    /// Reordering keeps the turn holder's turn; taking them out gives it to the first listed; « Jamais » makes a plain
    /// task again.
    @Test func editingTheRotationOfAnExistingTask() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let poubelles = try await harness.services.tasks.task(id: T.sortirPoubelles)
        let editor = TaskEditorViewModel(session: session, task: poubelles)
        await editor.load()
        editor.moveRotation(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(editor.rotationEntries.map(\.person.shortName) == ["Camille", "Inès", "Lucas"])
        #expect(editor.rotationEntries.map(\.badge) == ["C’est ton tour", nil, nil])
        editor.toggleRotationMember(F.camille.id)
        #expect(editor.rotationEntries.filter(\.isIncluded).map(\.badge) == ["Commence", nil])
        editor.toggleRotationMember(F.camille.id)
        let saved = try #require(await editor.save())
        #expect(saved.rotation == [F.ines.id, F.lucas.id, F.camille.id])
        #expect(saved.turnUserId == F.camille.id)

        let again = TaskEditorViewModel(session: session, task: saved)
        await again.load()
        again.repeatFrequency = .never
        let plain = try #require(await again.save())
        #expect(plain.recurrence == nil && plain.rotation.isEmpty && plain.turnUserId == nil)
        #expect(plain.assigneeIds == [F.camille.id])
    }

    /// A rotation that still lists someone who left is sent back as it is until the user changes it.
    @Test func aRotationListingSomeoneWhoLeft() async throws {
        let harness = VMHarness(.showcase)
        try await harness.device(F.lucas).groups.leave(groupId: F.lilas)
        let poubelles = try await harness.services.tasks.task(id: T.sortirPoubelles)
        #expect(poubelles.rotation.contains(F.lucas.id))
        let editor = TaskEditorViewModel(session: harness.makeSession(), task: poubelles)
        await editor.load()
        #expect(!editor.hasChanges)
        #expect(editor.rotationEntries.map(\.person.shortName) == ["Inès", "Camille"])
        editor.title = "Poubelles"
        let saved = try #require(await editor.save())
        #expect(saved.rotation == poubelles.rotation)

        let second = TaskEditorViewModel(session: harness.makeSession(), task: saved)
        await second.load()
        second.moveRotationMember(F.camille.id, by: -1)
        let reordered = try #require(await second.save())
        #expect(reordered.rotation == [F.camille.id, F.ines.id])
    }

    @Test func movingFollowsSwiftUI() {
        let items = ["A", "B", "C", "D"]
        #expect(TaskEditorViewModel.moving(items, fromOffsets: IndexSet(integer: 0), toOffset: 2) == ["B", "A", "C", "D"])
        #expect(TaskEditorViewModel.moving(items, fromOffsets: IndexSet(integer: 3), toOffset: 0) == ["D", "A", "B", "C"])
        #expect(TaskEditorViewModel.moving(items, fromOffsets: IndexSet(integer: 1), toOffset: 4) == ["A", "C", "D", "B"])
        #expect(TaskEditorViewModel.moving(items, fromOffsets: IndexSet([0, 2]), toOffset: 4) == ["B", "D", "A", "C"])
        #expect(TaskEditorViewModel.moving(items, fromOffsets: IndexSet(integer: 9), toOffset: 0) == items)
    }
}

@MainActor
@Suite struct MyTasksV2Tests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    @Test func rowsAndTheDay() async throws {
        let harness = VMHarness(.showcase)
        let model = MyTasksViewModel(session: harness.makeSession())
        await model.load()
        #expect(harness.faults.calls(.myTasks) == 1)
        #expect(model.todayText == "Jeudi 24 septembre")
        let rows = model.sections.flatMap(\.rows)
        #expect(rows.map(\.id) == [T.sortirPoubelles, T.faireCourses, T.reserverGymnase])
        #expect(rows[0].isMyTurn && rows[0].hasRotation)
        #expect(rows[0].recurrenceText == "Chaque semaine")
        #expect(rows[0].groupShortName == "Coloc'")
        #expect(rows[0].groupAppearance == AvatarAppearance(color: .coral, emoji: "\u{1F3E0}", initials: "CR"))
        #expect(rows[1].checklistProgress?.compactText == "2/4")
        #expect(!rows[1].isMyTurn)
        #expect(rows[1].isNew)
        #expect(rows[2].groupShortName == "Projet")
        #expect(rows[2].groupAppearance?.color == .green)
        #expect(rows[2].groupAppearance?.emoji == "\u{26BD}")

        let day = model.daySummary
        #expect(day == DaySummary(doneCount: 1, plannedCount: 2, overdueCount: 0, newCount: 2))
        #expect(DaySummary.title == "Ta journée")
        #expect(day.ringText == "1/2")
        #expect(day.fraction == 0.5)
        #expect(day.subtitle == "1 tâche faite sur 2 prévues")
        #expect(day.overdueText == nil)
        #expect(day.newText == "2 nouvelles")
        #expect(model.doneTodayText == "1 tâche terminée aujourd’hui")
        #expect(model.doneTodayRows.map(\.title) == ["Nettoyer le frigo"])
        // One read gives the done tasks too; the sections do not show them.
        #expect(Set(model.doneTasks.map(\.title)) == ["Nettoyer la cuisine", "Nettoyer le frigo"])
        #expect(!model.tasks.contains { $0.status == .done })
    }

    @Test func completingAndReopeningToday() async throws {
        let harness = VMHarness(.showcase)
        let model = MyTasksViewModel(session: harness.makeSession())
        await model.load()
        let poubelles = try #require(model.tasks.first { $0.id == T.sortirPoubelles })
        #expect(await model.setStatus(.done, for: poubelles))
        #expect(model.daySummary.doneCount == 2)
        #expect(model.daySummary.plannedCount == 2)
        #expect(model.daySummary.subtitle == "Tout est fait pour aujourd’hui\u{00A0}!")
        #expect(model.doneTodayRows.map(\.title) == ["Sortir les poubelles", "Nettoyer le frigo"])
        #expect(model.tasks.first { $0.id == T.sortirPoubelles }?.groupColor == .coral)

        await model.load()
        #expect(model.doneTodayText == "2 tâches terminées aujourd’hui")
        #expect(!model.sections.flatMap(\.rows).contains { $0.id == T.sortirPoubelles })
        let done = try #require(model.doneTodayRows.first { $0.id == T.sortirPoubelles })
        #expect(done.groupShortName == "Coloc'")
        #expect(await model.setStatus(.todo, for: done.task))
        #expect(model.daySummary.doneCount == 1)
        #expect(model.daySummary.plannedCount == 2)
        #expect(model.doneTodayText == "1 tâche terminée aujourd’hui")
    }

    @Test func overdueAndNothingPlanned() async throws {
        let harness = VMHarness()
        let model = MyTasksViewModel(session: harness.makeSession())
        await model.load()
        // Camille (populated): « Sortir les poubelles » today at 20:00; nothing done today.
        #expect(model.daySummary == DaySummary(doneCount: 0, plannedCount: 1, overdueCount: 0, newCount: 2))
        #expect(model.daySummary.subtitle == "0 tâche faite sur 1 prévue")
        #expect(model.doneTodayText == nil)
        #expect(model.doneTodayRows.isEmpty)
        #expect(DaySummary(doneCount: 0, plannedCount: 0, overdueCount: 1, newCount: 1).subtitle == "Rien de prévu aujourd’hui")
        #expect(DaySummary(doneCount: 0, plannedCount: 0, overdueCount: 1, newCount: 1).overdueText == "1 en retard")
        #expect(DaySummary(doneCount: 0, plannedCount: 0, overdueCount: 0, newCount: 1).newText == "1 nouvelle")
        #expect(DaySummary(doneCount: 0, plannedCount: 0, overdueCount: 0, newCount: 0).fraction == 0)
    }
}
