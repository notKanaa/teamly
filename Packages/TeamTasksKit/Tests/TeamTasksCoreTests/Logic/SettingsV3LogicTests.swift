import Foundation
import Testing
@testable import TeamTasksCore

// v3 « Réglages » (docs/CONTRACTS-V3.md §8, §9): the quiet hours and their effect on the reminders, the personal
// stats of the profile card, and the per-device appearance settings.

@Suite struct QuietHoursTests {
    typealias F = LogicFixtures
    let calendar = LogicFixtures.parisCalendar
    let night = QuietHours(isEnabled: true)

    @Test func defaultsAreOffFromTenPMToEightAM() {
        let quietHours = QuietHours()
        #expect(!quietHours.isEnabled)
        #expect(!quietHours.isActive)
        #expect(quietHours.startMinute == 22 * 60)
        #expect(quietHours.endMinute == 8 * 60)
        #expect(quietHours.rangeText == "22:00\u{00A0}→ 8:00")
        #expect(QuietHours.load(from: InMemoryKeyValueStore()) == quietHours)
    }

    @Test func persistsInKeyValueStore() {
        let store = InMemoryKeyValueStore()
        let custom = QuietHours(isEnabled: true, startMinute: 23 * 60 + 30, endMinute: 7 * 60)
        custom.save(to: store)
        #expect(QuietHours.load(from: store) == custom)
        #expect(QuietHours.load(from: store).rangeText == "23:30\u{00A0}→ 7:00")
    }

    @Test func unreadableOrPartialValues() {
        let store = InMemoryKeyValueStore()
        store.set(Data([0xFF, 0x00]), forKey: QuietHours.storageKey)
        #expect(QuietHours.load(from: store) == QuietHours())
        store.set(Data("{\"isEnabled\":true}".utf8), forKey: QuietHours.storageKey)
        #expect(QuietHours.load(from: store) == QuietHours(isEnabled: true))
        // Out-of-range minutes are brought back into one day.
        store.set(Data("{\"isEnabled\":true,\"startMinute\":1500,\"endMinute\":-60}".utf8), forKey: QuietHours.storageKey)
        #expect(QuietHours.load(from: store) == QuietHours(isEnabled: true, startMinute: 60, endMinute: 23 * 60))
    }

    @Test func timeTexts() {
        #expect(QuietHours.timeText(480) == "8:00")
        #expect(QuietHours.timeText(22 * 60 + 30) == "22:30")
        #expect(QuietHours.timeText(5) == "0:05")
        #expect(QuietHours.timeText(24 * 60) == "0:00")
    }

    @Test func overnightWindow() {
        #expect(night.isActive)
        #expect(night.contains(F.date(2026, 9, 24, 22, 0), calendar: calendar))
        #expect(night.contains(F.date(2026, 9, 24, 23, 45), calendar: calendar))
        #expect(night.contains(F.date(2026, 9, 25, 0, 0), calendar: calendar))
        #expect(night.contains(F.date(2026, 9, 25, 7, 59, 59), calendar: calendar))
        #expect(!night.contains(F.date(2026, 9, 25, 8, 0), calendar: calendar))
        #expect(!night.contains(F.date(2026, 9, 24, 21, 59), calendar: calendar))
        #expect(!night.contains(F.date(2026, 9, 24, 12, 0), calendar: calendar))
        // Before midnight the window ends the next morning; after midnight, the same morning.
        #expect(night.windowEnd(containing: F.date(2026, 9, 24, 23, 0), calendar: calendar) == F.date(2026, 9, 25, 8, 0))
        #expect(night.windowEnd(containing: F.date(2026, 9, 25, 2, 0), calendar: calendar) == F.date(2026, 9, 25, 8, 0))
        #expect(night.windowEnd(containing: F.date(2026, 9, 25, 9, 0), calendar: calendar) == nil)
    }

    @Test func windowWithinOneDay() {
        let afternoon = QuietHours(isEnabled: true, startMinute: 13 * 60, endMinute: 15 * 60)
        #expect(afternoon.windowEnd(containing: F.date(2026, 9, 24, 14, 0), calendar: calendar) == F.date(2026, 9, 24, 15, 0))
        #expect(!afternoon.contains(F.date(2026, 9, 24, 15, 0), calendar: calendar))
        #expect(!afternoon.contains(F.date(2026, 9, 24, 12, 59), calendar: calendar))
        #expect(!afternoon.contains(F.date(2026, 9, 24, 23, 0), calendar: calendar))
    }

    @Test func offOrEmptyWindowContainsNothing() {
        let off = QuietHours()
        let empty = QuietHours(isEnabled: true, startMinute: 600, endMinute: 600)
        for hour in [0, 7, 10, 22, 23] {
            let date = F.date(2026, 9, 24, hour, 0)
            #expect(!off.contains(date, calendar: calendar))
            #expect(!empty.contains(date, calendar: calendar))
            #expect(off.deferred(date, calendar: calendar) == date)
        }
        #expect(!empty.isActive)
    }

    @Test func deferredMovesOnlyTheDatesInside() {
        let inside = F.date(2026, 9, 24, 23, 10)
        let outside = F.date(2026, 9, 24, 19, 0)
        #expect(night.deferred(inside, calendar: calendar) == F.date(2026, 9, 25, 8, 0))
        #expect(night.deferred(outside, calendar: calendar) == outside)
    }

    @Test func endOfTheWindowKeepsTheWallClockTimeAcrossDST() {
        // The night of 24 to 25 October 2026 is one hour longer (CEST → CET at 03:00).
        let end = night.windowEnd(containing: F.date(2026, 10, 24, 23, 30), calendar: calendar)
        #expect(end == F.date(2026, 10, 25, 8, 0))
        // The night of 28 to 29 March 2026 is one hour shorter.
        #expect(night.windowEnd(containing: F.date(2026, 3, 28, 23, 30), calendar: calendar) == F.date(2026, 3, 29, 8, 0))
    }
}

@Suite struct QuietHoursReminderTests {
    typealias F = LogicFixtures
    let planner = ReminderPlanner(calendar: LogicFixtures.parisCalendar)
    let night = QuietHours(isEnabled: true)

    @Test func reminderInsideTheWindowFiresAtItsEnd() throws {
        let now = F.date(2026, 9, 24, 12, 0)
        let late = F.task(1, title: "Sortir les poubelles", due: F.date(2026, 9, 24, 23, 0)) // 1 h before: 22:00
        let morning = F.task(2, title: "Payer le loyer", due: F.date(2026, 9, 25, 10, 0)) // 1 h before: 09:00
        let plan = planner.plan(tasks: [late, morning], userId: F.me, leadTime: .oneHour, now: now, quietHours: night)
        #expect(plan.map(\.fireDate) == [F.date(2026, 9, 25, 8, 0), F.date(2026, 9, 25, 9, 0)])
        // Same id: only the fire date moves.
        let lateDue = try #require(late.dueAt)
        #expect(plan.first?.id == ReminderPlanner.identifier(taskId: late.id, dueAt: lateDue))

        let unchanged = planner.plan(tasks: [late, morning], userId: F.me, leadTime: .oneHour, now: now)
        #expect(unchanged.map(\.fireDate) == [F.date(2026, 9, 24, 22, 0), F.date(2026, 9, 25, 9, 0)])
    }

    @Test func deferredRemindersAreSortedByTheirNewFireDate() {
        let now = F.date(2026, 9, 24, 12, 0)
        let evening = F.task(1, due: F.date(2026, 9, 24, 23, 0)) // 22:45 → 08:00
        let early = F.task(2, due: F.date(2026, 9, 25, 8, 30)) // 08:15
        let plan = planner.plan(tasks: [early, evening], userId: F.me, leadTime: .fifteenMinutes, now: now, quietHours: night)
        #expect(plan.map(\.id).map { $0.contains(evening.id.uuidString) } == [true, false])
        #expect(plan.map(\.fireDate) == [F.date(2026, 9, 25, 8, 0), F.date(2026, 9, 25, 8, 15)])
    }

    @Test func aDeferredReminderStaysPlannedWhileTheWindowLasts() {
        // Due at 00:30: its reminder (23:30) has passed at 02:00, but it was deferred to 08:00.
        let task = F.task(1, due: F.date(2026, 9, 25, 0, 30))
        let during = planner.plan(tasks: [task], userId: F.me, leadTime: .oneHour, now: F.date(2026, 9, 25, 2, 0), quietHours: night)
        #expect(during.map(\.fireDate) == [F.date(2026, 9, 25, 8, 0)])
        let after = planner.plan(tasks: [task], userId: F.me, leadTime: .oneHour, now: F.date(2026, 9, 25, 9, 0), quietHours: night)
        #expect(after.isEmpty)
        // Without quiet hours it had passed.
        #expect(planner.plan(tasks: [task], userId: F.me, leadTime: .oneHour, now: F.date(2026, 9, 25, 2, 0)).isEmpty)
    }

    @Test func synchronizerReadsTheStoredQuietHours() async {
        let scheduler = LogicFakeScheduler()
        let store = InMemoryKeyValueStore()
        let now = F.date(2026, 9, 24, 12, 0)
        let synchronizer = ReminderSynchronizer(scheduler: scheduler, store: store, calendar: F.parisCalendar, now: { now })
        let tasks = [F.task(1, due: F.date(2026, 9, 24, 23, 0))]

        await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(scheduler.pending.values.map(\.fireDate) == [F.date(2026, 9, 24, 22, 0)])

        QuietHours(isEnabled: true).save(to: store)
        let deferred = await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(deferred.replaced.count == 1)
        #expect(scheduler.pending.values.map(\.fireDate) == [F.date(2026, 9, 25, 8, 0)])

        QuietHours(isEnabled: false).save(to: store)
        let restored = await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(restored.replaced.count == 1)
        #expect(scheduler.pending.values.map(\.fireDate) == [F.date(2026, 9, 24, 22, 0)])
    }
}

@Suite struct PersonalStatsTests {
    typealias F = LogicFixtures
    let calendar = LogicFixtures.parisCalendar
    /// Thursday 24 September 2026, 12:00: the week of Monday 21 September.
    let now = LogicFixtures.date(2026, 9, 24, 12, 0)

    @Test func readStartCoversTwelveWeeks() {
        // Monday 21 September minus 11 weeks.
        #expect(PersonalStats.readStart(now: now, calendar: calendar) == F.date(2026, 7, 6))
        #expect(PersonalStats.monthStart(of: now, calendar: calendar) == F.date(2026, 9, 1))
        #expect(PersonalStats.monthStart(of: F.date(2026, 10, 1, 0, 0), calendar: calendar) == F.date(2026, 10, 1))
    }

    @Test func tasksThisMonthStartOnTheFirstAtMidnight() {
        let stats = PersonalStats(
            completions: [F.date(2026, 8, 31, 23, 59), F.date(2026, 9, 1), F.date(2026, 9, 10, 18, 0), F.date(2026, 9, 24, 9, 0)],
            now: now, calendar: calendar
        )
        #expect(stats.tasksThisMonth == 3)
    }

    @Test func streakCountsConsecutiveWeeksFromTheCurrentOne() {
        let stats = PersonalStats(
            completions: [
                F.date(2026, 9, 21), // Monday of the current week
                F.date(2026, 9, 20, 23, 59), // Sunday of the week before
                F.date(2026, 9, 10, 18, 0),
                F.date(2026, 8, 31, 9, 0), // Monday 31 August: 4th week
                F.date(2026, 8, 17, 9, 0), // after a week without any
            ],
            now: now, calendar: calendar
        )
        #expect(stats.streakWeeks == 4)
    }

    @Test func anEmptyCurrentWeekStartsTheCountFromTheWeekBefore() {
        let fromLastWeek = PersonalStats(
            completions: [F.date(2026, 9, 18, 9, 0), F.date(2026, 9, 8, 9, 0)], now: now, calendar: calendar
        )
        #expect(fromLastWeek.streakWeeks == 2)
        #expect(fromLastWeek.tasksThisMonth == 2)
        let broken = PersonalStats(completions: [F.date(2026, 9, 8, 9, 0), F.date(2026, 9, 1, 9, 0)], now: now, calendar: calendar)
        #expect(broken.streakWeeks == 0)
        let onlyThisWeek = PersonalStats(completions: [F.date(2026, 9, 24, 11, 0)], now: now, calendar: calendar)
        #expect(onlyThisWeek.streakWeeks == 1)
        #expect(PersonalStats(completions: [], now: now, calendar: calendar) == PersonalStats(tasksThisMonth: 0, streakWeeks: 0))
    }

    @Test func onlyTheWeeksReadCount() {
        // One completion every week for 20 weeks.
        let everyWeek = (0..<20).compactMap { calendar.date(byAdding: .day, value: -7 * $0, to: now) }
        #expect(PersonalStats(completions: everyWeek, now: now, calendar: calendar).streakWeeks == 12)
        // Nothing this week: the 11 weeks before it.
        #expect(PersonalStats(completions: Array(everyWeek.dropFirst()), now: now, calendar: calendar).streakWeeks == 11)
    }

    @Test func tasksCompletedByTheUserOnly() {
        var mine = F.task(1, status: .done, completedAt: F.date(2026, 9, 22, 9, 0))
        mine.completedBy = F.me
        var theirs = F.task(2, status: .done, completedAt: F.date(2026, 9, 22, 10, 0))
        theirs.completedBy = F.other
        let unknown = F.task(3, status: .done, completedAt: F.date(2026, 9, 22, 11, 0)) // v1: completedBy nil
        var reopened = F.task(4, status: .todo)
        reopened.completedBy = F.me
        var lastWeek = F.task(5, status: .done, completedAt: F.date(2026, 9, 15, 9, 0))
        lastWeek.completedBy = F.me
        let stats = PersonalStats(tasks: [mine, theirs, unknown, reopened, lastWeek, mine], userId: F.me, now: now, calendar: calendar)
        #expect(stats == PersonalStats(tasksThisMonth: 2, streakWeeks: 2))
    }

    @Test func labels() {
        #expect(PersonalStats(tasksThisMonth: 0, streakWeeks: 0).tasksThisMonthLabel == "tâche ce mois")
        #expect(PersonalStats(tasksThisMonth: 1, streakWeeks: 1).streakLabel == "semaine de série")
        #expect(PersonalStats(tasksThisMonth: 23, streakWeeks: 3).tasksThisMonthLabel == "tâches ce mois")
        #expect(PersonalStats(tasksThisMonth: 23, streakWeeks: 3).streakLabel == "semaines de série")
        #expect(PersonalStats.groupsLabel(1) == "groupe")
        #expect(PersonalStats.groupsLabel(2) == "groupes")
    }
}

@Suite struct DeviceSettingsTests {
    @Test func defaults() {
        let settings = DeviceSettings()
        #expect(settings.theme == .auto)
        #expect(settings.isConfettiEnabled)
        #expect(settings.isHapticsEnabled)
        #expect(DeviceSettings.load(from: InMemoryKeyValueStore()) == settings)
        #expect(settings.summary(icon: .default) == "Auto · Icône B")
    }

    @Test func persistsInKeyValueStore() {
        let store = InMemoryKeyValueStore()
        let custom = DeviceSettings(theme: .dark, isConfettiEnabled: false, isHapticsEnabled: false)
        custom.save(to: store)
        #expect(DeviceSettings.load(from: store) == custom)
        #expect(custom.summary(icon: .monogram) == "Sombre · Icône C")
    }

    @Test func missingOrUnknownValuesTakeTheirDefault() {
        let store = InMemoryKeyValueStore()
        store.set(Data("{\"theme\":\"light\"}".utf8), forKey: DeviceSettings.storageKey)
        #expect(DeviceSettings.load(from: store) == DeviceSettings(theme: .light))
        store.set(Data("{\"theme\":\"sepia\",\"isHapticsEnabled\":false}".utf8), forKey: DeviceSettings.storageKey)
        #expect(DeviceSettings.load(from: store) == DeviceSettings(isHapticsEnabled: false))
        store.set(Data([0xFF]), forKey: DeviceSettings.storageKey)
        #expect(DeviceSettings.load(from: store) == DeviceSettings())
    }

    @Test func themes() {
        #expect(ThemePreference.allCases.map(\.label) == ["Auto", "Clair", "Sombre"])
    }

    @Test func appIcons() {
        #expect(AppIconChoice.allCases.map(\.letter) == ["A", "B", "C"])
        #expect(AppIconChoice.allCases.map(\.label) == ["Trio", "Carte cochée", "Monogramme"])
        #expect(AppIconChoice.allCases.map(\.alternateIconName) == ["AppIconTrio", nil, "AppIconMonogramme"])
        #expect(AppIconChoice.default == .checkedCard)
        #expect(AppIconChoice(alternateIconName: nil) == .checkedCard)
        #expect(AppIconChoice(alternateIconName: "AppIconTrio") == .trio)
        #expect(AppIconChoice(alternateIconName: "AppIconMonogramme") == .monogram)
        #expect(AppIconChoice(alternateIconName: "Inconnue") == .checkedCard)
    }
}
