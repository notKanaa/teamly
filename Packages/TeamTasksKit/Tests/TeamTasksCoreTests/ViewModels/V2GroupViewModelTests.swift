import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

// v2 group screens: appearance, « À qui le tour ? », status counts, the activity feed and the weekly recap.

@MainActor
@Suite struct GroupAppearanceTests {
    typealias F = VMFixtures

    @Test func createsAGroupWithItsColorAndEmoji() async throws {
        let harness = VMHarness()
        let model = CreateGroupViewModel(session: harness.makeSession(), color: .teal)
        #expect(model.color == .teal)
        #expect(model.emoji == nil)
        #expect(model.colorOptions == ColorKey.allCases)
        #expect(model.emojiOptions == EmojiChoices.groups)
        model.name = "Vacances 2027"
        #expect(model.preview == AvatarAppearance(color: .teal, emoji: nil, initials: "V2"))
        model.selectColor(.amber)
        model.selectEmoji("\u{1F3D6}\u{FE0F}")
        #expect(model.preview.symbol == "\u{1F3D6}\u{FE0F}")
        let group = try #require(await model.create())
        #expect(group.group.color == .amber)
        #expect(group.group.emoji == "\u{1F3D6}\u{FE0F}")
        #expect(group.group.appearance == AvatarAppearance(color: .amber, emoji: "\u{1F3D6}\u{FE0F}", initials: "V2"))
        // Picking the chosen emoji again removes it.
        model.selectEmoji("\u{1F3D6}\u{FE0F}")
        #expect(model.emoji == nil)
    }

    @Test func theDefaultColorIsAPaletteColor() {
        let model = CreateGroupViewModel(session: VMHarness().makeSession())
        #expect(ColorKey.allCases.contains(model.color))
        #expect(model.emoji == nil)
        #expect(model.preview.initials == "?")
    }

    @Test func adminsEditTheAppearance() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let detail = GroupDetailViewModel(session: session, groupId: F.lilas)
        #expect(detail.makeAppearanceEditor() == nil)
        await detail.load()
        #expect(detail.canSetAppearance)
        #expect(detail.appearance == AvatarAppearance(color: .coral, emoji: "\u{1F3E0}", initials: "CR"))
        let editor = try #require(detail.makeAppearanceEditor())
        #expect(GroupAppearanceViewModel.title == "Apparence")
        #expect(editor.isSelected(.coral))
        #expect(editor.isSelected(emoji: "\u{1F3E0}"))
        #expect(!editor.hasChanges && !editor.canSave)
        editor.selectColor(.violet)
        editor.selectEmoji("\u{1F389}")
        #expect(editor.preview == AvatarAppearance(color: .violet, emoji: "\u{1F389}", initials: "CR"))
        #expect(editor.canSave)
        let revision = session.feed.groupRevision(F.lilas)
        let memberships = session.feed.membershipsRevision
        let saved = try #require(await editor.save())
        #expect(saved.color == .violet && saved.emoji == "\u{1F389}")
        #expect(editor.savedGroup == saved)
        #expect(!editor.hasChanges)
        #expect(session.feed.groupRevision(F.lilas) > revision)
        #expect(session.feed.membershipsRevision > memberships)
        detail.apply(group: saved)
        #expect(detail.appearance?.color == .violet)
        let seenByLucas = try await harness.device(F.lucas).groups.myGroups().first { $0.id == F.lilas }
        #expect(seenByLucas?.group.emoji == "\u{1F389}")

        // No emoji: the initials.
        let editorAgain = try #require(detail.makeAppearanceEditor())
        editorAgain.selectEmoji(nil)
        #expect(try #require(await editorAgain.save()).emoji == nil)
    }

    @Test func anAutomaticColorStaysAutomatic() {
        let date = F.now
        let group = TeamGroup(id: F.lilas, name: "Coloc", createdBy: nil, createdAt: date, lastActivityAt: date)
        let editor = GroupAppearanceViewModel(session: VMHarness().makeSession(), group: group)
        let automatic = ColorKey.automatic(for: F.lilas)
        #expect(editor.isSelected(automatic))
        editor.selectColor(automatic == .teal ? .pink : .teal)
        #expect(editor.hasChanges)
        editor.selectColor(automatic)
        #expect(editor.color == nil)
        #expect(!editor.hasChanges)
    }

    @Test func membersCannotAndErrorsAreShown() async throws {
        let harness = VMHarness()
        let detail = GroupDetailViewModel(session: harness.makeSession(), groupId: F.sport)
        await detail.load()
        #expect(!detail.canSetAppearance)
        #expect(detail.makeAppearanceEditor() == nil)
        // Not an admin: the server refuses.
        let editor = GroupAppearanceViewModel(session: harness.makeSession(), group: try #require(detail.group))
        editor.selectColor(.pink)
        #expect(await editor.save() == nil)
        #expect(editor.errorMessage == AppError.forbidden.messageFR)
        #expect(!editor.isGone)

        // Deleted meanwhile.
        let lilas = GroupDetailViewModel(session: harness.makeSession(), groupId: F.lilas)
        await lilas.load()
        let lilasEditor = try #require(lilas.makeAppearanceEditor())
        try await harness.device(F.camille).groups.deleteGroup(groupId: F.lilas)
        lilasEditor.selectEmoji(nil)
        #expect(await lilasEditor.save() == nil)
        #expect(lilasEditor.isGone)
        #expect(lilasEditor.errorMessage == GroupAppearanceViewModel.goneMessage)
        #expect(!lilasEditor.canSave)
    }
}

@MainActor
@Suite struct GroupDetailV2Tests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    @Test func headerRowsAndCounts() async throws {
        let harness = VMHarness(.showcase)
        let model = GroupDetailViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        #expect(model.tab == .tasks)
        #expect(GroupDetailViewModel.Tab.allCases.map(\.label) == ["Tâches", "Activité"])
        #expect(model.activity.groupId == F.lilas)
        #expect(model.membersSummary == "3 membres · Tu es admin")
        #expect(model.memberBadges.map(\.shortName) == ["Camille", "Inès", "Lucas"])
        #expect(model.memberBadges.map(\.isMe) == [true, false, false])

        // Counts per status chip, the other criteria applied.
        let tasks = model.tasks
        #expect(model.count(for: .todo) == 3)
        #expect(model.count(for: .inProgress) == 1)
        #expect(model.count(for: .done) == tasks.filter { $0.status == .done }.count)
        #expect(model.count(for: .all) == tasks.count)
        #expect(model.filterChips.map(\.countedLabel).prefix(3) == ["Toutes · \(tasks.count)", "À faire · 3", "En cours · 1"])
        model.toggleFilterChip(.assignedToMe)
        #expect(model.count(for: .todo) == 1)
        #expect(model.count(for: .inProgress) == 1)
        model.resetFilter()

        let rows = model.rows
        let poubelles = try #require(rows.first { $0.id == T.sortirPoubelles })
        #expect(poubelles.recurrenceText == "Chaque semaine")
        #expect(poubelles.hasRotation)
        #expect(poubelles.isMyTurn)
        #expect(poubelles.assignees.map(\.shortName) == ["Camille"])
        #expect(TaskRow.rotationLabel == "À tour de rôle")
        #expect(TaskRow.myTurnLabel == "Ton tour")
        let courses = try #require(rows.first { $0.id == T.faireCourses })
        #expect(courses.checklistProgress == ChecklistProgress(done: 2, total: 4))
        #expect(courses.assignees.map(\.shortName) == ["Camille", "Lucas"])
        #expect(!courses.isMyTurn && !courses.hasRotation && courses.recurrenceText == nil)
        let loyer = try #require(rows.first { $0.id == T.payerLoyer })
        #expect(loyer.assignees.map(\.shortName) == ["Inès"])
        #expect(loyer.groupAppearance == nil && loyer.groupShortName == nil)
    }

    /// « À qui le tour ? »: whose turn it is and who comes next, over the current members, then after a completion.
    @Test func turnCards() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = GroupDetailViewModel(session: session, groupId: F.lilas)
        await model.load()
        #expect(GroupDetailViewModel.turnCardsTitle == "À qui le tour\u{00A0}?")
        let card = try #require(model.turnCards.first)
        #expect(model.turnCards.count == 1)
        #expect(card.id == T.sortirPoubelles)
        #expect(card.title == "Sortir les poubelles")
        #expect(card.dueText == "Aujourd’hui à 20:00")
        #expect(!card.isOverdue)
        #expect(card.isMyTurn)
        #expect(card.current?.shortName == "Camille")
        #expect(card.next?.shortName == "Lucas")
        #expect(card.nextText == "puis Lucas")
        #expect(model.turnCardsSubtitle == "1 tâche tournante")

        // Done: the next occurrence is Lucas's turn, then Inès's.
        #expect(await model.setStatus(.done, for: card.task))
        await model.load()
        let next = try #require(model.turnCards.first)
        #expect(next.id != T.sortirPoubelles)
        #expect(next.current?.shortName == "Lucas")
        #expect(!next.isMyTurn)
        #expect(next.nextText == "puis Inès")
        #expect(next.dueText == "Jeudi 1er octobre à 20:00")

        // Inès leaves: after Lucas comes Camille.
        try await harness.device(F.ines).groups.leave(groupId: F.lilas)
        session.feed.bump(groupId: F.lilas)
        await model.load()
        #expect(model.turnCards.first?.nextText == "puis toi")
    }

    @Test func noRotatingTask() async {
        let harness = VMHarness()
        let model = GroupDetailViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        #expect(model.turnCards.isEmpty)
        #expect(model.turnCardsSubtitle == nil)
        #expect(model.rows.allSatisfy { !$0.isMyTurn && !$0.hasRotation && $0.checklistProgress == nil })
    }
}

@MainActor
@Suite struct GroupActivityViewModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    /// The showcase feed: the events of the last 3 days, by day, in French, and the podium of the week.
    @Test func feedAndRecap() async throws {
        let harness = VMHarness(.showcase)
        let model = GroupActivityViewModel(session: harness.makeSession(), groupId: F.lilas)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.events.count == 10)
        let sections = model.sections
        #expect(sections.map(\.title) == ["Aujourd’hui", "Hier", "Mardi 22 septembre", "Lundi 21 septembre"])
        #expect(sections.map(\.rows.count) == [5, 2, 1, 2])
        let today = sections[0].rows
        #expect(today.map(\.text.plainText) == [
            "Inès a terminé «\u{00A0}Arroser les plantes\u{00A0}»",
            "Lucas a terminé «\u{00A0}Descendre le verre\u{00A0}»",
            "Tu as coché «\u{00A0}Pâtes\u{00A0}» dans «\u{00A0}Faire les courses\u{00A0}»",
            "Inès a terminé «\u{00A0}Passer l’aspirateur\u{00A0}»",
            "Tu as terminé «\u{00A0}Nettoyer le frigo\u{00A0}»",
        ])
        #expect(today.map(\.timeText) == ["09:00", "06:00", "05:00", "03:00", "00:00"])
        #expect(today[0].person?.shortName == "Inès")
        #expect(today[0].systemImage == "checkmark.circle.fill")
        #expect(today[2].kind == .checklistItemDone)
        #expect(today[2].taskId == T.faireCourses)
        #expect(sections[1].rows.map(\.text.plainText) == [
            "Inès a terminé «\u{00A0}Faire la vaisselle\u{00A0}»",
            "Lucas a coché «\u{00A0}Lait\u{00A0}» dans «\u{00A0}Faire les courses\u{00A0}»",
        ])
        #expect(sections[2].rows.map(\.text.plainText) == ["Lucas a créé «\u{00A0}Faire les courses\u{00A0}»"])
        let monday = sections[3].rows
        #expect(monday.map(\.text.plainText) == [
            "C’est ton tour pour «\u{00A0}Sortir les poubelles\u{00A0}»",
            "Tu as terminé «\u{00A0}Sortir les poubelles\u{00A0}»",
        ])
        #expect(monday[0].kind == .turnStarted)
        #expect(monday[0].taskId == T.sortirPoubelles)
        #expect(monday[0].person?.isMe == true)
        #expect(monday.map(\.timeText) == ["10:00", "10:00"])
        #expect(!model.isFeedEmpty)

        #expect(GroupActivityViewModel.recapTitle == "Cette semaine")
        #expect(model.recapRangeText == "Du lundi 21 au dimanche 27 septembre")
        #expect(model.recapTotal == 7)
        #expect(model.recapTotalLabel == "tâches faites")
        #expect(!model.isRecapEmpty)
        #expect(model.podium.map(\.person.shortName) == ["Inès", "Camille", "Lucas"])
        #expect(model.podium.map(\.count) == [3, 2, 1])
        #expect(model.podium.map(\.placeText) == ["1re", "2e", "3e"])
        #expect(model.podium.map(\.person.isMe) == [false, true, false])
        #expect(model.podiumStageOrder.map(\.person.shortName) == ["Camille", "Inès", "Lucas"])
        #expect(model.streakText?.plainText == "Inès mène pour la 3e semaine d’affilée.")
    }

    /// Reloads on the group's signal: a completion elsewhere shows at the top and moves the podium (ties share a place).
    @Test func reloadsOnTheGroupsSignal() async throws {
        let harness = VMHarness(.showcase)
        let session = harness.makeSession()
        let model = GroupActivityViewModel(session: session, groupId: F.lilas)
        await model.load()
        await model.load()
        #expect(harness.faults.calls(.activity) == 1)
        #expect(harness.faults.calls(.completions) == 1)
        #expect(harness.faults.calls(.members) == 1)

        _ = try await harness.device(F.lucas).tasks.setStatus(taskId: T.faireCourses, status: .done)
        session.feed.bump(groupId: F.lilas)
        #expect(model.needsRefresh)
        await model.load()
        #expect(harness.faults.calls(.activity) == 2)
        #expect(model.sections.first?.rows.first?.text.plainText == "Lucas a terminé «\u{00A0}Faire les courses\u{00A0}»")
        #expect(model.recapTotal == 8)
        #expect(model.podium.map(\.count) == [3, 2, 2])
        #expect(model.podium.map(\.placeText) == ["1re", "2e", "2e"])

        session.feed.bump(groupId: F.sport)
        await model.load()
        #expect(harness.faults.calls(.activity) == 2)
    }

    @Test func emptyFeedFailuresAndGone() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = GroupActivityViewModel(session: session, groupId: F.sport)
        await model.load()
        #expect(model.isFeedEmpty)
        #expect(model.sections.isEmpty)
        #expect(model.isRecapEmpty)
        #expect(model.podium.isEmpty && model.podiumStageOrder.isEmpty)
        #expect(model.streakText == nil)
        #expect(model.recapRangeText == "Du lundi 21 au dimanche 27 septembre")

        harness.faults.fail(.completions, with: AppError.network)
        let failing = GroupActivityViewModel(session: session, groupId: F.lilas)
        await failing.load()
        #expect(failing.loadState == .failed(AppError.network.messageFR))
        await failing.reload()
        #expect(failing.loadState == .loaded)
        // « Nettoyer la cuisine » (done yesterday by nobody known) counts in the total only.
        #expect(failing.recapTotal == 1)
        #expect(failing.podium.isEmpty)

        try await harness.device(F.lucas).groups.removeMember(groupId: F.sport, userId: F.camille.id)
        session.feed.bump(groupId: F.sport)
        await model.load()
        #expect(model.isGone)
        #expect(model.error == nil)
    }
}
