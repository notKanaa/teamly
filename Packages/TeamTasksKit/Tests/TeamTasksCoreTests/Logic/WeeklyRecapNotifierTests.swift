import Foundation
import Testing
@testable import TeamTasksCore

// docs/CONTRACTS-V2.md §8: the weekly recap notification, every Monday at 09:00.

@Suite struct WeeklyRepeatTests {
    typealias F = LogicFixtures
    static let monday9 = WeeklyRepeat(weekday: 1, hour: 9)

    @Test func platformComponents() {
        #expect(Self.monday9.gregorianWeekday == 2)
        #expect(WeeklyRepeat(weekday: 7, hour: 9).gregorianWeekday == 1)
        #expect(WeeklyRepeat(weekday: 6, hour: 9).gregorianWeekday == 7)
        #expect(Self.monday9.dateComponents == DateComponents(hour: 9, minute: 0, weekday: 2))
    }

    @Test func nextMondayAtNine() {
        let calendar = F.parisCalendar
        // Thursday 24 September 2026 → Monday 28 at 09:00.
        #expect(Self.monday9.nextDate(after: F.date(2026, 9, 24, 10), calendar: calendar) == F.date(2026, 9, 28, 9))
        // A Monday before 09:00: the same day; at 09:00 exactly: the next week.
        #expect(Self.monday9.nextDate(after: F.date(2026, 9, 28, 8, 59), calendar: calendar) == F.date(2026, 9, 28, 9))
        #expect(Self.monday9.nextDate(after: F.date(2026, 9, 28, 9), calendar: calendar) == F.date(2026, 10, 5, 9))
        // Across the fall-back change: 09:00 CET.
        #expect(Self.monday9.nextDate(after: F.date(2026, 10, 24, 12), calendar: calendar) == F.date(2026, 10, 26, 9))
        // Whatever the calendar's first weekday.
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        #expect(Self.monday9.nextDate(after: F.date(2026, 9, 27, 12), calendar: sundayFirst) == F.date(2026, 9, 28, 9))
    }
}

@MainActor
@Suite struct WeeklyRecapNotifierTests {
    typealias F = LogicFixtures
    static let now = F.date(2026, 9, 24, 10)
    static let id = WeeklyRecapNotifier.identifier

    private func notifier(_ scheduler: any NotificationScheduler, store: any KeyValueStore = InMemoryKeyValueStore()) -> WeeklyRecapNotifier {
        let now = Self.now
        return WeeklyRecapNotifier(scheduler: scheduler, store: store, calendar: F.parisCalendar, now: { now })
    }

    @Test func schedulesTheMondayNotificationOnce() async throws {
        let scheduler = LogicFakeScheduler()
        let notifier = notifier(scheduler)
        #expect(await notifier.synchronize())
        let pending = try #require(scheduler.pending[Self.id])
        #expect(pending.title == "Le récap de la semaine est prêt")
        #expect(pending.body == WeeklyRecapNotifier.body)
        #expect(pending.repeatsWeekly == WeeklyRepeat(weekday: 1, hour: 9))
        #expect(pending.fireDate == F.date(2026, 9, 28, 9))
        #expect(pending.userInfo.isEmpty)
        #expect(notifier.notification(now: Self.now) == pending)

        // Idempotent.
        #expect(await notifier.synchronize())
        #expect(scheduler.added.count == 1)
        #expect(scheduler.removeCalls.isEmpty)
    }

    @Test func theSwitchIsOnByDefault() {
        let store = InMemoryKeyValueStore()
        #expect(WeeklyRecapNotifier.isEnabled(in: store))
        WeeklyRecapNotifier.setEnabled(false, in: store)
        #expect(!WeeklyRecapNotifier.isEnabled(in: store))
        WeeklyRecapNotifier.setEnabled(true, in: store)
        #expect(WeeklyRecapNotifier.isEnabled(in: store))
    }

    @Test func switchedOffOrNotAuthorizedRemovesIt() async {
        let scheduler = LogicFakeScheduler()
        let store = InMemoryKeyValueStore()
        let notifier = notifier(scheduler, store: store)
        #expect(await notifier.synchronize())

        WeeklyRecapNotifier.setEnabled(false, in: store)
        #expect(await !notifier.synchronize())
        #expect(scheduler.pending[Self.id] == nil)

        WeeklyRecapNotifier.setEnabled(true, in: store)
        #expect(await notifier.synchronize())
        #expect(scheduler.pending[Self.id] != nil)

        scheduler.authorization = .denied
        #expect(await !notifier.synchronize())
        #expect(scheduler.pending[Self.id] == nil)
        scheduler.authorization = .authorized
        #expect(await notifier.synchronize())
    }

    /// A pending request of an earlier version (other content) is replaced.
    @Test func anOlderRequestIsReplaced() async {
        let scheduler = LogicFakeScheduler()
        scheduler.seedPending(LocalNotification(id: Self.id, title: "Ancien titre", body: "b", fireDate: Self.now.addingTimeInterval(60)))
        let notifier = notifier(scheduler)
        #expect(await notifier.synchronize())
        #expect(scheduler.removeCalls == [[Self.id]])
        #expect(scheduler.pending[Self.id]?.title == WeeklyRecapNotifier.title)
    }

    @Test func aFailedRequestIsRetried() async {
        let scheduler = LogicFakeScheduler()
        scheduler.failingIds = [Self.id]
        let notifier = notifier(scheduler)
        #expect(await !notifier.synchronize())
        #expect(scheduler.pending.isEmpty)
        scheduler.failingIds = []
        #expect(await notifier.synchronize())
        #expect(scheduler.pending[Self.id] != nil)
    }

    @Test func removeAllRemovesIt() async {
        let scheduler = LogicFakeScheduler()
        let notifier = notifier(scheduler)
        #expect(await notifier.synchronize())
        await notifier.removeAll()
        #expect(scheduler.pending.isEmpty)
    }

    /// Sign-out while the platform is still registering the request: the late request is withdrawn.
    @Test func removeAllSupersedesASynchronizationInProgress() async {
        let scheduler = LogicGatedScheduler(gatedCalls: [1])
        let notifier = notifier(scheduler)
        let synchronization = Task { await notifier.synchronize() }
        await LogicWait.until("add held") { scheduler.waitingCalls == [1] }
        await notifier.removeAll()
        scheduler.open(1)
        #expect(await synchronization.value == false)
        #expect(scheduler.pending.isEmpty)
        // The next synchronization (a new session) schedules it again.
        #expect(await notifier.synchronize())
        #expect(scheduler.pending[Self.id] != nil)
    }
}
