import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

// The French wording of the v2 screens: FrenchText, Initials, GroupShortName, RecurrenceText, ActivityText,
// RecapText, and the shared presentation values.

@Suite struct FrenchTextTests {
    @Test func quotesAndElision() {
        #expect(FrenchText.quoted("Lessive") == "«\u{00A0}Lessive\u{00A0}»")
        #expect(FrenchText.de("Lucas") == "de Lucas")
        #expect(FrenchText.de("Inès") == "d’Inès")
        #expect(FrenchText.de("Élodie") == "d’Élodie")
        #expect(FrenchText.de("Œdipe") == "d’Œdipe")
        #expect(FrenchText.de("un ancien membre") == "d’un ancien membre")
        #expect(FrenchText.de("Hugo") == "de Hugo")
        #expect(FrenchText.de("Yanis") == "de Yanis")
        #expect(FrenchText.dePrefix(before: "Anna") == "d’")
        #expect(FrenchText.dePrefix(before: "") == "de ")
    }

    @Test func firstNamesOrdinalsAndCounts() {
        #expect(FrenchText.firstName(of: " Camille Martin ") == "Camille")
        #expect(FrenchText.firstName(of: "Jean-Pierre Durand") == "Jean-Pierre")
        #expect(FrenchText.firstName(of: "Inès") == "Inès")
        #expect(FrenchText.firstName(of: "   ").isEmpty)
        #expect(FrenchText.ordinal(1) == "1re")
        #expect(FrenchText.ordinal(2) == "2e")
        #expect(FrenchText.ordinal(3) == "3e")
        #expect(FrenchText.count(0, "tâche", "tâches") == "0 tâche")
        #expect(FrenchText.count(1, "tâche", "tâches") == "1 tâche")
        #expect(FrenchText.count(2, "tâche", "tâches") == "2 tâches")
    }

    @Test func initials() {
        #expect(Initials.of("Camille Martin") == "CM")
        #expect(Initials.of("Coloc’ rue des Lilas") == "CR")
        #expect(Initials.of("Jean-Pierre") == "JP")
        #expect(Initials.of("inès") == "I")
        #expect(Initials.of("\u{1F389} Fête") == "F")
        #expect(Initials.of("") == "?")
        #expect(Initials.of("  -  ") == "?")
    }

    @Test func groupShortNames() {
        #expect(GroupShortName.of("Famille Martin") == "Famille Martin")
        #expect(GroupShortName.of(" Coloc’ rue des Lilas ") == "Coloc’")
        #expect(GroupShortName.of("Projet Asso Sport") == "Projet")
        #expect(GroupShortName.of("Les copains du foot") == "Copains")
        let long = GroupShortName.of("Anticonstitutionnellement")
        #expect(long.count == GroupShortName.maxLength)
        #expect(long.hasPrefix("Anticonstitu") && long.hasSuffix("…"))
    }
}

@Suite struct RecurrenceTextTests {
    typealias F = LogicFixtures
    static let paris = "Europe/Paris"

    static func rule(
        _ frequency: RecurrenceRule.Frequency,
        _ interval: Int = 1,
        weekdays: Set<Int>? = nil,
        monthDay: Int? = nil,
        zone: String = paris
    ) -> RecurrenceRule {
        RecurrenceRule(frequency: frequency, interval: interval, weekdays: weekdays, timeZoneId: zone, monthDay: monthDay)
    }

    @Test func summaries() {
        #expect(RecurrenceText.summary(Self.rule(.daily)) == "Chaque jour")
        #expect(RecurrenceText.summary(Self.rule(.daily, 2)) == "Tous les 2 jours")
        #expect(RecurrenceText.summary(Self.rule(.weekly)) == "Chaque semaine")
        #expect(RecurrenceText.summary(Self.rule(.weekly, 2)) == "Toutes les 2 semaines")
        #expect(RecurrenceText.summary(Self.rule(.monthly)) == "Chaque mois")
        #expect(RecurrenceText.summary(Self.rule(.monthly, 3)) == "Tous les 3 mois")
        #expect(RecurrenceText.summary(Self.rule(.daily, 0)) == "Chaque jour")
    }

    /// The examples of the brief, and the other day lists.
    @Test func descriptions() {
        let saturday = F.date(2026, 9, 26, 11)
        #expect(RecurrenceText.description(Self.rule(.daily), dueAt: saturday) == "Chaque jour")
        #expect(RecurrenceText.description(Self.rule(.daily, 2), dueAt: saturday) == "Tous les 2 jours")
        #expect(RecurrenceText.description(Self.rule(.weekly), dueAt: saturday) == "Chaque semaine, le samedi")
        #expect(RecurrenceText.description(Self.rule(.weekly, 2, weekdays: [5, 2]), dueAt: saturday)
            == "Toutes les 2 semaines, le mardi et le vendredi")
        #expect(RecurrenceText.description(Self.rule(.monthly), dueAt: F.date(2026, 9, 25, 18)) == "Chaque mois, le 25")
        #expect(RecurrenceText.description(Self.rule(.monthly), dueAt: F.date(2026, 10, 1, 18)) == "Chaque mois, le 1er")
        #expect(RecurrenceText.description(Self.rule(.monthly, monthDay: 31), dueAt: F.date(2026, 9, 30, 18))
            == "Chaque mois, le 31 ou le dernier jour du mois")
        #expect(RecurrenceText.description(Self.rule(.weekly, weekdays: [1, 3, 5]), dueAt: saturday)
            == "Chaque semaine, le lundi, le mercredi et le vendredi")
        #expect(RecurrenceText.description(Self.rule(.weekly, weekdays: [1, 2, 3, 4, 5]), dueAt: nil)
            == "Chaque semaine, du lundi au vendredi")
        #expect(RecurrenceText.description(Self.rule(.weekly, weekdays: Set(1...7)), dueAt: nil) == "Chaque semaine, tous les jours")
        #expect(RecurrenceText.description(Self.rule(.weekly), dueAt: nil) == "Chaque semaine")
        #expect(RecurrenceText.description(Self.rule(.monthly), dueAt: nil) == "Chaque mois")
        #expect(RecurrenceText.weekdaysText([]) == nil)
        #expect(RecurrenceText.monthDayText(28) == "le 28")
        #expect(RecurrenceText.monthDayText(29) == "le 29 ou le dernier jour du mois")
    }

    /// The days that follow the due date are those of the rule's time zone.
    @Test func daysAreReadInTheRulesTimeZone() {
        // Saturday 26 September, 23:30 in Paris, is Sunday 27 in Tokyo.
        let due = F.date(2026, 9, 26, 23, 30)
        #expect(RecurrenceText.description(Self.rule(.weekly, zone: "Asia/Tokyo"), dueAt: due) == "Chaque semaine, le dimanche")
        #expect(RecurrenceText.description(Self.rule(.monthly, zone: "Asia/Tokyo"), dueAt: due) == "Chaque mois, le 27")
        #expect(RecurrenceText.description(Self.rule(.weekly), dueAt: due) == "Chaque semaine, le samedi")
    }
}

@Suite struct ActivityTextTests {
    typealias F = LogicFixtures
    static let me = F.me
    static let lucas = F.uuid(0xC2)
    static let ines = F.uuid(0xC3)
    /// Someone who left the group.
    static let departed = F.uuid(0xDE)
    static let names = [me: "Camille", lucas: "Lucas", ines: "Inès"]

    private func text(
        _ kind: ActivityEvent.Kind,
        actor: UUID? = nil,
        subject: UUID? = nil,
        task: String? = "Sortir les poubelles",
        item: String? = nil
    ) -> EmphasizedText {
        let event = ActivityEvent(
            id: 1, kind: kind, actorId: actor, subjectId: subject, taskId: F.uuid(1), taskTitle: task, itemTitle: item,
            createdAt: F.date(2026, 9, 24)
        )
        return ActivityText.text(for: event, currentUserId: Self.me, names: Self.names)
    }

    @Test func tasksAndChecklistItems() {
        #expect(text(.taskCreated, actor: Self.lucas).plainText == "Lucas a créé «\u{00A0}Sortir les poubelles\u{00A0}»")
        #expect(text(.taskCreated, actor: Self.lucas).emphasized == ["Lucas"])
        #expect(text(.taskCreated, actor: Self.me).plainText == "Tu as créé «\u{00A0}Sortir les poubelles\u{00A0}»")
        #expect(text(.taskCompleted, actor: Self.ines).plainText == "Inès a terminé «\u{00A0}Sortir les poubelles\u{00A0}»")
        #expect(text(.taskCompleted, actor: Self.departed).plainText
            == "Un ancien membre a terminé «\u{00A0}Sortir les poubelles\u{00A0}»")
        #expect(text(.taskCompleted, actor: nil, task: nil).plainText == "Un ancien membre a terminé une tâche")
        #expect(text(.checklistItemDone, actor: Self.ines, task: "Faire les courses", item: "Lessive").plainText
            == "Inès a coché «\u{00A0}Lessive\u{00A0}» dans «\u{00A0}Faire les courses\u{00A0}»")
        #expect(text(.checklistItemDone, actor: Self.me, task: nil, item: "Lessive").plainText
            == "Tu as coché «\u{00A0}Lessive\u{00A0}»")
        #expect(text(.checklistItemDone, actor: Self.lucas, task: "Faire les courses").plainText
            == "Lucas a coché un élément de «\u{00A0}Faire les courses\u{00A0}»")
        #expect(text(.checklistItemDone, actor: Self.lucas, task: nil).plainText == "Lucas a coché un élément")
    }

    @Test func turns() {
        #expect(text(.turnStarted, subject: Self.me).plainText == "C’est ton tour pour «\u{00A0}Sortir les poubelles\u{00A0}»")
        #expect(text(.turnStarted, subject: Self.me).emphasized == ["ton tour"])
        #expect(text(.turnStarted, subject: Self.lucas).plainText
            == "C’est au tour de Lucas pour «\u{00A0}Sortir les poubelles\u{00A0}»")
        #expect(text(.turnStarted, subject: Self.ines).plainText
            == "C’est au tour d’Inès pour «\u{00A0}Sortir les poubelles\u{00A0}»")
        #expect(text(.turnStarted, subject: Self.ines).emphasized == ["Inès"])
        #expect(text(.turnStarted, subject: Self.departed).plainText
            == "C’est au tour d’un ancien membre pour «\u{00A0}Sortir les poubelles\u{00A0}»")
        #expect(text(.turnStarted, subject: Self.lucas, task: nil).plainText == "C’est au tour de Lucas")
    }

    @Test func membersJoiningAndLeaving() {
        #expect(text(.memberJoined, actor: Self.ines, subject: Self.ines, task: nil).plainText == "Inès a rejoint le groupe")
        #expect(text(.memberJoined, actor: Self.me, subject: Self.me, task: nil).plainText == "Tu as rejoint le groupe")
        // Left: the member (usually no longer known).
        #expect(text(.memberLeft, actor: Self.departed, subject: Self.departed, task: nil).plainText
            == "Un ancien membre a quitté le groupe")
        #expect(text(.memberLeft, actor: Self.lucas, subject: Self.lucas, task: nil).plainText == "Lucas a quitté le groupe")
        #expect(text(.memberLeft, actor: Self.me, subject: Self.me, task: nil).plainText == "Tu as quitté le groupe")
        // Removed by someone.
        let removed = text(.memberLeft, actor: Self.me, subject: Self.departed, task: nil)
        #expect(removed.plainText == "Tu as retiré un ancien membre du groupe")
        #expect(removed.emphasized == ["Tu", "un ancien membre"])
        #expect(text(.memberLeft, actor: Self.lucas, subject: Self.ines, task: nil).plainText == "Lucas a retiré Inès du groupe")
        #expect(text(.memberLeft, actor: Self.lucas, subject: Self.me, task: nil).plainText == "Lucas t’a retiré du groupe")
        #expect(text(.memberLeft, actor: Self.departed, subject: Self.lucas, task: nil).plainText
            == "Un ancien membre a retiré Lucas du groupe")
        #expect(text(.memberLeft, actor: Self.lucas, subject: nil, task: nil).plainText
            == "Lucas a retiré un ancien membre du groupe")
        #expect(text(.memberLeft, actor: nil, subject: Self.lucas, task: nil).plainText == "Lucas a été retiré du groupe")
        #expect(text(.memberLeft, actor: nil, subject: Self.me, task: nil).plainText == "Tu as été retiré du groupe")
        // A deleted account.
        let deleted = text(.memberLeft, actor: nil, subject: nil, task: nil)
        #expect(deleted.plainText == "Un membre a supprimé son compte")
        #expect(deleted.emphasized == ["Un membre"])
    }

    @Test func dayTitles() {
        let now = F.date(2026, 9, 24, 10)
        let calendar = F.parisCalendar
        #expect(ActivityText.dayTitle(of: F.date(2026, 9, 24, 0, 5), now: now, calendar: calendar) == "Aujourd’hui")
        #expect(ActivityText.dayTitle(of: F.date(2026, 9, 25, 0, 1), now: now, calendar: calendar) == "Aujourd’hui")
        #expect(ActivityText.dayTitle(of: F.date(2026, 9, 23, 23, 59), now: now, calendar: calendar) == "Hier")
        #expect(ActivityText.dayTitle(of: F.date(2026, 9, 21, 10), now: now, calendar: calendar) == "Lundi 21 septembre")
        #expect(ActivityText.dayTitle(of: F.date(2025, 12, 31, 10), now: now, calendar: calendar) == "Mercredi 31 décembre 2025")
    }
}

@Suite struct RecapTextTests {
    typealias F = LogicFixtures

    @Test func weekRanges() {
        let calendar = F.parisCalendar
        #expect(RecapText.range(weekStart: F.date(2026, 9, 21), weekEnd: F.date(2026, 9, 28), calendar: calendar)
            == "Du lundi 21 au dimanche 27 septembre")
        #expect(RecapText.range(weekStart: F.date(2026, 9, 28), weekEnd: F.date(2026, 10, 5), calendar: calendar)
            == "Du lundi 28 septembre au dimanche 4 octobre")
        #expect(RecapText.range(weekStart: F.date(2025, 12, 29), weekEnd: F.date(2026, 1, 5), calendar: calendar)
            == "Du lundi 29 décembre 2025 au dimanche 4 janvier 2026")
        #expect(RecapText.range(weekStart: F.date(2026, 6, 1), weekEnd: F.date(2026, 6, 8), calendar: calendar)
            == "Du lundi 1er au dimanche 7 juin")
        // The week of the fall-back change (a 25-hour Sunday).
        #expect(RecapText.range(weekStart: F.date(2026, 10, 19), weekEnd: F.date(2026, 10, 26), calendar: calendar)
            == "Du lundi 19 au dimanche 25 octobre")
    }

    @Test func totalsPlacesAndStreaks() {
        #expect(RecapText.totalLabel(0) == "tâche faite")
        #expect(RecapText.totalLabel(1) == "tâche faite")
        #expect(RecapText.totalLabel(14) == "tâches faites")
        #expect(RecapText.place(1) == "1re")
        #expect(RecapText.place(2) == "2e")
        let streak = RecapText.streak(name: "Inès", isMe: false, weeks: 3)
        #expect(streak.plainText == "Inès mène pour la 3e semaine d’affilée.")
        #expect(streak.emphasized == ["Inès"])
        #expect(RecapText.streak(name: "Camille", isMe: true, weeks: 2).plainText == "Tu mènes pour la 2e semaine d’affilée.")
    }
}

@MainActor
@Suite struct V2PresentationTests {
    typealias F = LogicFixtures

    @Test func curatedEmojisAreValidAndDistinct() throws {
        for emoji in EmojiChoices.avatars + EmojiChoices.groups {
            #expect(try InputValidation.emoji(emoji) == emoji, "\(emoji.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        #expect(Set(EmojiChoices.avatars).count == EmojiChoices.avatars.count)
        #expect(Set(EmojiChoices.groups).count == EmojiChoices.groups.count)
        // The demo groups' emojis are in the grid (selected when their group is edited).
        #expect(EmojiChoices.groups.contains(DemoData.lilasGroupEmoji))
        #expect(EmojiChoices.groups.contains(DemoData.sportGroupEmoji))
    }

    @Test func colorLabels() {
        #expect(ColorKey.allCases.map(\.label) == ["Indigo", "Violet", "Bleu", "Turquoise", "Vert", "Ambre", "Orange", "Corail", "Rose"])
    }

    @Test func appearances() {
        let date = F.date(2026, 9, 24)
        let camille = UserProfile(id: F.me, displayName: "Camille Martin")
        #expect(camille.appearance == AvatarAppearance(color: ColorKey.automatic(for: F.me), emoji: nil, initials: "CM"))
        #expect(!camille.appearance.showsEmoji)
        #expect(camille.appearance.symbol == "CM")
        let fox = UserProfile(id: F.me, displayName: "Camille Martin", avatarColor: .teal, avatarEmoji: "\u{1F98A}")
        #expect(fox.appearance == AvatarAppearance(color: .teal, emoji: "\u{1F98A}", initials: "CM"))
        #expect(fox.appearance.symbol == "\u{1F98A}")
        let group = TeamGroup(id: F.groupA, name: "Coloc’ rue des Lilas", createdBy: nil, createdAt: date, lastActivityAt: date, emoji: "\u{1F3E0}")
        #expect(group.appearance == AvatarAppearance(color: ColorKey.automatic(for: F.groupA), emoji: "\u{1F3E0}", initials: "CR"))
        #expect(AvatarAppearance.unknown(id: F.other) == AvatarAppearance(color: ColorKey.automatic(for: F.other), emoji: nil, initials: "?"))
        var task = F.task(1)
        task.groupColor = .green
        task.groupEmoji = "\u{26BD}"
        #expect(task.groupAppearance == AvatarAppearance(color: .green, emoji: "\u{26BD}", initials: "CR"))
        task.groupName = nil
        #expect(task.groupAppearance == nil)
    }

    @Test func checklistProgress() {
        #expect(ChecklistProgress([]) == nil)
        let items = (1...5).map { ChecklistItem(id: F.uuid($0), title: "É\($0)", position: $0, isDone: $0 <= 2) }
        let progress = ChecklistProgress(items)
        #expect(progress == ChecklistProgress(done: 2, total: 5))
        #expect(progress?.compactText == "2/5")
        #expect(progress?.text == "2 sur 5")
        #expect(progress?.fraction == 0.4)
        #expect(progress?.isComplete == false)
        #expect(ChecklistProgress(done: 3, total: 3).isComplete)
    }

    @Test func shortNamesAndBadges() {
        let date = F.date(2026, 1, 1)
        let lucas = F.uuid(0xC2)
        let ines = F.uuid(0xC3)
        let homonym = F.uuid(0xC4)
        let people: [(UUID, String, MemberRole)] = [
            (F.me, "Camille Martin", .admin), (homonym, "camille Dupont", .member), (lucas, "Lucas Bernard", .member),
            (ines, "Inès Dubois", .member),
        ]
        let members = people.map { Membership(groupId: F.groupA, user: UserProfile(id: $0.0, displayName: $0.1), role: $0.2, joinedAt: date) }
        let directory = MemberDirectory(members: members, currentUserId: F.me)
        #expect(directory.shortNames == [F.me: "Camille Martin", homonym: "camille Dupont", lucas: "Lucas", ines: "Inès"])
        #expect(directory.shortName(of: lucas) == "Lucas")
        #expect(directory.shortName(of: F.other) == "Ancien membre")
        #expect(directory.shortName(of: nil) == "Ancien membre")
        let departed = directory.badge(of: F.other)
        #expect(!departed.isMember && departed.name == "Ancien membre" && departed.appearance.initials == "?")
        let me = directory.badge(of: F.me)
        #expect(me.isMe && me.isMember && me.appearance.initials == "CM")
        #expect(directory.badges(of: [lucas, F.me, ines, lucas]).map(\.id) == [F.me, ines, lucas])
        #expect(directory.memberBadges.map(\.id) == people.map { $0.0 })
    }

    @Test func filterChipsWithCounts() {
        let chips = TaskFilterChip.chips(for: .all, counts: [.todo: 4, .inProgress: 1])
        #expect(chips.map(\.countedLabel) == ["Toutes", "À faire · 4", "En cours · 1", "Terminées", "Assignées à moi", "En retard"])
        #expect(TaskFilterChip.chips(for: .all) == TaskFilterChip.chips(for: .all, counts: [:]))
    }

    /// Every v2 text the screens show follows the French typography (’, no-break spaces).
    @Test func typographyOfTheV2Texts() {
        let names = [F.me: "Camille", F.other: "Inès"]
        var shown: [String] = []
        let people: [(UUID?, UUID?)] = [(F.me, F.me), (F.other, F.other), (F.other, F.me), (F.me, nil), (nil, nil), (nil, F.other)]
        for kind in ActivityEvent.Kind.allCases {
            for (actor, subject) in people {
                let event = ActivityEvent(
                    id: 1, kind: kind, actorId: actor, subjectId: subject, taskTitle: "Vaisselle", itemTitle: "Éponge",
                    createdAt: F.date(2026, 9, 24)
                )
                shown.append(ActivityText.text(for: event, currentUserId: F.me, names: names).plainText)
            }
        }
        shown += [
            RecapText.streak(name: "Inès", isMe: false, weeks: 2).plainText, RecapText.emptyMessage,
            RecapText.range(weekStart: F.date(2026, 9, 21), weekEnd: F.date(2026, 9, 28), calendar: F.parisCalendar),
            RecurrenceText.description(RecurrenceRule(frequency: .monthly, timeZoneId: "Europe/Paris", monthDay: 31), dueAt: nil),
            GroupActivityViewModel.emptyFeedMessage, GroupActivityViewModel.feedTitle, GroupDetailViewModel.turnCardsTitle,
            OnboardingViewModel.welcomeMessage, OnboardingViewModel.avatarMessage, OnboardingViewModel.firstGroupMessage,
            OnboardingViewModel.joinHint, OnboardingViewModel.notificationsMessage, OnboardingViewModel.notificationsTitle,
            TaskEditorViewModel.recurrenceHint, TaskEditorViewModel.dueDateRequiredText, TaskEditorViewModel.rotationSubtitle,
            TaskEditorViewModel.departedRotationMessage, TaskEditorViewModel.rotationTurnBadge, TaskEditorViewModel.rotationMyTurnBadge,
            SettingsViewModel.weeklyRecapFooter, WeeklyRecapNotifier.title, WeeklyRecapNotifier.body,
            DaySummary(doneCount: 2, plannedCount: 2, overdueCount: 0, newCount: 0).subtitle,
            DaySummary(doneCount: 0, plannedCount: 0, overdueCount: 0, newCount: 0).subtitle,
            CreateGroupViewModel.namePlaceholder, TaskDetailViewModel.upcomingTitle,
        ] + OnboardingViewModel.highlights.flatMap { [$0.title, $0.message] }
        let problems = shown.flatMap { text in WordingTests.typographyProblems(in: text).map { "\($0) in « \(text) »" } }
        #expect(problems.isEmpty, "\(problems)")
        let ascii = shown.filter { $0.contains("'") }
        #expect(ascii.isEmpty, "\(ascii)")
    }
}
