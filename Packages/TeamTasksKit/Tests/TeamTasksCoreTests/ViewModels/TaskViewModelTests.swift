import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

@MainActor
@Suite struct TaskEditorViewModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    @Test func newTaskDefaults() async {
        let harness = VMHarness()
        let model = TaskEditorViewModel(session: harness.makeSession(), groupId: F.lilas)
        #expect(!model.isEditing)
        #expect(model.navigationTitle == "Nouvelle tâche")
        #expect(model.saveButtonTitle == "Créer")
        #expect(model.priority == .medium)
        #expect(!model.hasDueDate)
        #expect(model.dueDate == F.date(2026, 9, 25, 18))
        #expect(!model.hasChanges)
        #expect(!model.canSave)
        #expect(model.loadState == .idle)

        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.assigneeOptions.map(\.name) == ["Camille Martin (vous)", "Inès Dubois", "Lucas Bernard"])
        #expect(model.assigneeOptions.map(\.isMe) == [true, false, false])
        #expect(model.assigneesSummary == "Non assignée")
        await model.load()
        #expect(harness.faults.calls(.members) == 1)
    }

    @Test func validatesBeforeCallingTheService() async {
        let harness = VMHarness()
        let model = TaskEditorViewModel(session: harness.makeSession(), groupId: F.lilas)
        model.title = "   "
        model.details = String(repeating: "d", count: 5001)
        model.hasDueDate = true
        model.dueDate = Date(timeIntervalSince1970: 253_402_300_800) // year 10000
        #expect(await model.save() == nil)
        #expect(model.titleError == "Le titre doit contenir entre 1 et 200 caractères.")
        #expect(model.detailsError == "La description ne doit pas dépasser 5000 caractères.")
        #expect(model.dueDateError == TaskEditorViewModel.invalidDueDateMessage)
        #expect(harness.faults.calls(.createTask) == 0)

        model.title = "Arroser les plantes"
        #expect(model.titleError == nil)
        model.details = "Deux fois par semaine."
        #expect(model.detailsError == nil)
        model.hasDueDate = false
        #expect(model.dueDateError == nil)
    }

    @Test func createsATask() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = TaskEditorViewModel(session: session, groupId: F.lilas)
        await model.load()
        model.title = "  Arroser les plantes "
        model.details = "Deux fois par semaine."
        model.priority = .high
        model.hasDueDate = true
        model.toggleAssignee(F.lucas.id)
        model.toggleAssignee(F.camille.id)
        #expect(model.assigneesSummary == "Vous, Lucas Bernard")
        #expect(model.hasChanges)
        #expect(model.canSave)
        let groupRevision = session.feed.groupRevision(F.lilas)

        let task = try #require(await model.save())
        #expect(task.title == "Arroser les plantes")
        #expect(task.details == "Deux fois par semaine.")
        #expect(task.priority == .high)
        #expect(task.dueAt == F.date(2026, 9, 25, 18))
        #expect(Set(task.assigneeIds) == [F.lucas.id, F.camille.id])
        #expect(task.createdBy == F.camille.id)
        #expect(model.savedTask == task)
        #expect(session.feed.groupRevision(F.lilas) == groupRevision + 1)
        #expect(try await harness.services.tasks.task(id: task.id) == task)
    }

    @Test func assigneeLimit() async throws {
        let harness = VMHarness()
        // 20 more members in « Coloc' rue des Lilas ».
        for index in 1...20 {
            let account = try harness.backend.createAccount(
                email: "colocataire\(index)@example.com",
                password: DemoData.password,
                displayName: "Colocataire \(index)"
            )
            _ = try await harness.backend.services(for: account.id).groups.join(code: try #require(InviteCode("LYLAS234")))
        }
        let model = TaskEditorViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        #expect(model.members.count == 23)
        for member in model.members.prefix(20) {
            model.toggleAssignee(member.user.id)
        }
        #expect(model.assigneeLimitReached)
        let extra = model.members[20].user.id
        model.toggleAssignee(extra)
        #expect(!model.isAssigned(extra))
        #expect(model.assigneesError == "20 personnes assignées au maximum.")
        model.toggleAssignee(model.members[0].user.id)
        #expect(model.assigneesError == nil)
        #expect(!model.assigneeLimitReached)

        model.title = "Grand ménage"
        model.toggleAssignee(extra)
        let task = try #require(await model.save())
        #expect(task.assigneeIds.count == 20)
    }

    @Test func serverAssigneeErrorsReloadTheMembers() async {
        let harness = VMHarness()
        let model = TaskEditorViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        model.title = "Tâche"
        model.toggleAssignee(F.ines.id)
        harness.faults.fail(.createTask, with: AppError.assigneeNotMember)
        #expect(await model.save() == nil)
        #expect(model.assigneesError == AppError.assigneeNotMember.messageFR)
        #expect(harness.faults.calls(.members) == 2)

        harness.faults.fail(.createTask, with: AppError.network)
        #expect(await model.save() == nil)
        #expect(model.errorMessage == AppError.network.messageFR)
        #expect(model.savedTask == nil)
    }

    @Test func editsATask() async throws {
        let harness = VMHarness()
        let original = try await harness.services.tasks.task(id: T.sortirPoubelles)
        let model = TaskEditorViewModel(session: harness.makeSession(), task: original)
        #expect(model.isEditing)
        #expect(model.navigationTitle == "Modifier la tâche")
        #expect(model.saveButtonTitle == "Enregistrer")
        #expect(model.title == "Sortir les poubelles")
        #expect(model.priority == .high)
        #expect(model.hasDueDate)
        #expect(model.dueDate == original.dueAt)
        #expect(model.assigneeIds == [F.camille.id])
        #expect(!model.hasChanges)

        await model.load()
        #expect(model.canEdit)
        model.title = "Sortir toutes les poubelles"
        model.hasDueDate = false
        #expect(model.hasChanges)
        let saved = try #require(await model.save())
        #expect(saved.title == "Sortir toutes les poubelles")
        #expect(saved.dueAt == nil)
        #expect(harness.faults.calls(.updateTask) == 1)
    }

    @Test func nonEditorsCannotSave() async throws {
        let harness = VMHarness()
        let affiche = try await harness.services.tasks.task(id: T.creerAffiche)
        let model = TaskEditorViewModel(session: harness.makeSession(), task: affiche)
        await model.load()
        #expect(model.myRole == .member)
        #expect(!model.canEdit)
        #expect(!model.canSave)
        #expect(await model.save() == nil)
        #expect(model.errorMessage == AppError.forbidden.messageFR)
        #expect(harness.faults.calls(.updateTask) == 0)
    }

    @Test func editingADeletedTask() async throws {
        let harness = VMHarness()
        let fuite = try await harness.services.tasks.task(id: T.reparerFuite)
        let model = TaskEditorViewModel(session: harness.makeSession(), task: fuite)
        try await harness.device(F.ines).tasks.delete(taskId: fuite.id)
        model.title = "Réparer la fuite (urgent)"
        #expect(await model.save() == nil)
        #expect(model.isGone)
        #expect(model.errorMessage == TaskEditorViewModel.goneMessage)
    }

    @Test func defaultDueDateIsTomorrowEvening() {
        let calendar = VMFixtures.calendar
        #expect(TaskEditorViewModel.defaultDueDate(now: F.date(2026, 9, 24, 23, 30), calendar: calendar) == F.date(2026, 9, 25, 18))
        #expect(TaskEditorViewModel.defaultDueDate(now: F.date(2026, 12, 31, 8), calendar: calendar) == F.date(2027, 1, 1, 18))
    }
}

@MainActor
@Suite struct TaskDetailViewModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    @Test func loadsTheTaskWithNames() async {
        let harness = VMHarness()
        let model = TaskDetailViewModel(session: harness.makeSession(), groupId: F.lilas, taskId: T.faireCourses)
        #expect(model.title == "Tâche")
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.title == "Faire les courses")
        #expect(model.details == "Lait, pâtes, lessive et papier toilette.")
        #expect(model.status == .inProgress)
        #expect(model.priority == .medium)
        #expect(model.dueText == "Demain à 18:00")
        #expect(!model.isOverdue)
        #expect(model.assigneeNames == ["Vous", "Lucas Bernard"])
        #expect(model.assigneesText == "Vous, Lucas Bernard")
        #expect(model.creatorName == "Lucas Bernard")
        #expect(model.createdText == "Créée par Lucas Bernard mardi 22 septembre à 10:00")
        #expect(model.completedText == nil)
        #expect(model.myRole == .admin)
        #expect(model.canEdit && model.canChangeStatus && model.canDelete)
        #expect(model.statusOptions == [.todo, .inProgress, .done])
        #expect(model.deleteConfirmationMessage.contains("« Faire les courses »"))
    }

    @Test func myOwnTaskAndOverdue() async {
        let harness = VMHarness()
        let model = TaskDetailViewModel(session: harness.makeSession(), groupId: F.lilas, taskId: T.payerLoyer)
        await model.load()
        #expect(model.isOverdue)
        #expect(model.dueText == "Hier à 10:00")
        #expect(model.creatorName == "Vous")
        #expect(model.createdText == "Créée par vous vendredi 18 septembre à 10:00")
        #expect(model.assigneeNames == ["Inès Dubois"])
    }

    @Test func assigneeCanOnlyChangeTheStatus() async {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = TaskDetailViewModel(session: session, groupId: F.sport, taskId: T.reserverGymnase)
        await model.load()
        #expect(model.myRole == .member)
        #expect(model.canChangeStatus)
        #expect(!model.canEdit && !model.canDelete)
        #expect(model.makeEditor() == nil)

        #expect(await !model.delete())
        #expect(model.errorMessage == AppError.forbidden.messageFR)
        #expect(harness.faults.calls(.deleteTask) == 0)

        let myTasksRevision = session.feed.myTasksRevision
        #expect(await model.setStatus(.done))
        #expect(model.status == .done)
        #expect(model.completedText?.hasPrefix("Terminée aujourd'hui à ") == true)
        #expect(session.feed.myTasksRevision == myTasksRevision + 1)
        // Same status again: nothing to do.
        #expect(await !model.setStatus(.done))
        #expect(harness.faults.calls(.setStatus) == 1)
    }

    @Test func otherMembersSeeButCannotAct() async {
        let harness = VMHarness()
        let model = TaskDetailViewModel(session: harness.makeSession(), groupId: F.sport, taskId: T.creerAffiche)
        await model.load()
        #expect(!model.canChangeStatus && !model.canEdit && !model.canDelete)
        #expect(await !model.setStatus(.done))
        #expect(harness.faults.calls(.setStatus) == 0)
    }

    @Test func deletes() async throws {
        let harness = VMHarness()
        let model = TaskDetailViewModel(session: harness.makeSession(), groupId: F.lilas, taskId: T.reparerFuite)
        await model.load()
        #expect(await model.delete())
        #expect(model.didDelete && model.isGone)
        await #expect(throws: AppError.notFound) { try await harness.services.tasks.task(id: T.reparerFuite) }
    }

    @Test func deletedElsewhereIsGone() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.faireCourses)
        await model.load()
        try await harness.device(F.lucas).tasks.delete(taskId: T.faireCourses)
        session.feed.bump(groupId: F.lilas)
        await model.load()
        #expect(model.isGone)
        #expect(!model.didDelete)
        #expect(model.error == nil)
    }

    @Test func reloadsOnGroupRevision() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = TaskDetailViewModel(session: session, groupId: F.lilas, taskId: T.faireCourses)
        await model.load()
        await model.load()
        #expect(harness.faults.calls(.task) == 1)
        _ = try await harness.device(F.lucas).tasks.setStatus(taskId: T.faireCourses, status: .done)
        session.feed.bump(groupId: F.lilas)
        await model.load()
        #expect(harness.faults.calls(.task) == 2)
        #expect(model.status == .done)
    }

    @Test func editorRoundTrip() async throws {
        let harness = VMHarness()
        let model = TaskDetailViewModel(session: harness.makeSession(), groupId: F.lilas, taskId: T.sortirPoubelles)
        await model.load()
        let editor = try #require(model.makeEditor())
        #expect(editor.isEditing)
        #expect(editor.loadState == .loaded) // members handed over
        editor.title = "Sortir les poubelles (jaune)"
        let saved = try #require(await editor.save())
        model.apply(saved)
        #expect(model.title == "Sortir les poubelles (jaune)")
    }

    @Test func loadFailureThenRetry() async {
        let harness = VMHarness()
        let model = TaskDetailViewModel(session: harness.makeSession(), groupId: F.lilas, taskId: T.faireCourses)
        harness.faults.fail(.task, with: AppError.network)
        await model.load()
        #expect(model.loadState == .failed(AppError.network.messageFR))
        #expect(!model.canEdit)
        await model.reload()
        #expect(model.loadState == .loaded)
    }
}

@MainActor
@Suite struct MyTasksViewModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    @Test func sectionsAndNewBadges() async {
        let harness = VMHarness()
        let model = MyTasksViewModel(session: harness.makeSession())
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.sections.map(\.bucket) == [.today, .thisWeek])
        #expect(model.sections.map(\.title) == ["Aujourd'hui", "Cette semaine"])
        #expect(model.sections[0].rows.map(\.id) == [T.sortirPoubelles])
        #expect(model.sections[1].rows.map(\.id) == [T.faireCourses, T.reserverGymnase])
        let rows = model.sections.flatMap(\.rows)
        #expect(rows.map(\.groupName) == ["Coloc' rue des Lilas", "Coloc' rue des Lilas", "Projet Asso Sport"])
        #expect(rows.map(\.dueText) == ["Aujourd'hui à 20:00", "Demain à 18:00", "Dimanche 27 septembre à 18:00"])
        #expect(rows.allSatisfy { $0.canChangeStatus && !$0.canEdit && $0.assigneesText == nil })
        // Never looked: tasks assigned by someone else are new, my own task is not.
        #expect(rows.map(\.isNew) == [false, true, true])
        #expect(model.newCount == 2)
        #expect(!model.isEmpty)
    }

    @Test func markAllSeenPersistsPerUser() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = MyTasksViewModel(session: session)
        await model.load()
        model.markAllSeen()
        #expect(model.newCount == 0)
        #expect(harness.store.value(Date.self, forKey: MyTasksViewModel.lastSeenKey(userId: F.camille.id)) != nil)

        let again = MyTasksViewModel(session: session)
        await again.load()
        #expect(again.newCount == 0)

        // A new assignment by Lucas after that is new.
        harness.clock.advance(by: 60)
        let created = try await harness.device(F.lucas).tasks.create(
            groupId: F.lilas,
            draft: TaskDraft(title: "Descendre le carton", assigneeIds: [F.camille.id])
        )
        session.feed.bumpMyTasks()
        await again.load()
        #expect(again.newCount == 1)
        #expect(again.tasks.first { $0.id == created.id }.map { again.isNew($0) } == true)
    }

    @Test func includeDoneShowsTheDoneSection() async {
        let harness = VMHarness()
        let model = MyTasksViewModel(session: harness.makeSession())
        await model.load()
        model.includeDone = true
        #expect(model.needsRefresh)
        await model.load()
        #expect(harness.faults.calls(.myTasks) == 2)
        #expect(model.sections.map(\.bucket) == [.today, .thisWeek, .done])
        #expect(model.sections.last?.rows.map(\.id) == [T.nettoyerCuisine])
        #expect(model.sections.last?.rows.first?.isNew == false)
    }

    @Test func synchronizesRemindersAfterASuccessfulLoadOnly() async throws {
        let harness = VMHarness()
        let model = MyTasksViewModel(session: harness.makeSession())

        harness.faults.fail(.myTasks, with: AppError.network)
        await model.load()
        #expect(model.loadState == .failed(AppError.network.messageFR))
        #expect(harness.scheduler.dueIds.isEmpty)

        await model.reload()
        let expected = try await harness.reminderIds([T.sortirPoubelles, T.faireCourses, T.reserverGymnase])
        #expect(harness.scheduler.dueIds == expected)

        // A failed reload keeps the content and every reminder.
        harness.faults.fail(.myTasks, with: AppError.network)
        await model.reload()
        #expect(model.loadState == .loaded)
        #expect(model.errorMessage == AppError.network.messageFR)
        #expect(harness.scheduler.dueIds == expected)
    }

    @Test func statusChangeFromTheList() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = MyTasksViewModel(session: session)
        await model.load()
        let courses = try #require(model.tasks.first { $0.id == T.faireCourses })
        let groupRevision = session.feed.groupRevision(F.lilas)
        #expect(await model.setStatus(.done, for: courses))
        // Hidden until « Terminées » is shown, group name kept.
        #expect(!model.sections.flatMap(\.rows).contains { $0.id == courses.id })
        #expect(model.tasks.first { $0.id == courses.id }?.groupName == "Coloc' rue des Lilas")
        #expect(model.tasks.first { $0.id == courses.id }?.myAssignedAt != nil)
        #expect(session.feed.groupRevision(F.lilas) == groupRevision + 1)

        // Refreshes on the « Mes tâches » revision.
        await model.load()
        #expect(harness.faults.calls(.myTasks) == 2)
        #expect(!model.tasks.contains { $0.id == courses.id })
    }

    @Test func emptyState() async {
        let harness = VMHarness(.emptyGroups)
        let model = MyTasksViewModel(session: harness.makeSession())
        await model.load()
        #expect(model.isEmpty)
        #expect(model.newCount == 0)
    }
}
