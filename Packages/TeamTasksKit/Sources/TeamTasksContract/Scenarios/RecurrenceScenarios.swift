import Foundation
import TeamTasksCore

// v2 recurring tasks (docs/CONTRACTS-V2.md §3, §5, §6): the stored rule, its validation and check order, the spawn of
// the next occurrence when an occurrence becomes done, and the series lifecycle. The expected due dates come from the
// spec's test vectors, or from the backend's own completion time (`completedAt` is the `now()` of the spawn).
extension ContractScenarios {
    static let recurrenceScenarios: [ContractScenario] = [
        ContractScenario("recurrence.createStoresTheRule") { harness in
            let alice = try await harness.user("Alice")
            let group = try await alice.makeGroup()
            let weekly = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                title: Unique.name("Hebdo"), dueAt: try utc("2041-10-09T16:00:00Z"),
                recurrence: Rule.weekly(interval: 2, weekdays: [5, 1, 3])
            ))
            try Verify.equal(
                weekly.recurrence, RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [1, 3, 5], timeZoneId: Zone.paris),
                "the stored weekly rule (no month day)"
            )
            try Verify.equal(weekly.seriesId, weekly.id, "the first occurrence starts the series")
            try Verify.equal(weekly.nextOccurrenceId, nil, "no next occurrence yet")
            try Verify.equal(weekly.rotation, [], "no rotation")
            try Verify.equal(weekly.turnUserId, nil, "no turn")
            try Verify.equal(weekly.completedBy, nil, "not completed")
            try Verify.equal(weekly.checklist, [], "no checklist")
            let fetched = try await alice.tasks.task(id: weekly.id)
            try Verify.equal(fetched, weekly, "task(id:) returns what create returned")

            // Monthly: the server stores the local day of the due date (Jan 31 00:30 in Tokyo, Jan 30 in UTC)…
            let tokyo = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                title: Unique.name("Tokyo"), dueAt: try utc("2041-01-30T15:30:00Z"), recurrence: Rule.monthly(tz: Zone.tokyo)
            ))
            try Verify.equal(
                tokyo.recurrence, RecurrenceRule(frequency: .monthly, timeZoneId: Zone.tokyo, monthDay: 31),
                "monthly: the month day is the local day of the due date"
            )
            // … whatever month day a client puts in its draft (it is never sent).
            var withDay = Rule.monthly()
            withDay.monthDay = 5
            let paris = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                title: Unique.name("Paris"), dueAt: try utc("2041-01-31T17:00:00Z"), recurrence: withDay
            ))
            try Verify.equal(paris.recurrence?.monthDay, 31, "the month day is the server's")
            let daily = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                title: Unique.name("Jour"), dueAt: try utc("2041-10-09T06:00:00Z"), recurrence: Rule.daily(tz: Zone.utc)
            ))
            try Verify.equal(daily.recurrence, RecurrenceRule(frequency: .daily, timeZoneId: Zone.utc), "a daily rule, interval 1")
            let plain = try await alice.makeTask(in: group.id, dueAt: Fixed.dueA)
            try Verify.equal(plain.recurrence, nil, "a plain task has no rule")
            try Verify.equal(plain.seriesId, nil, "a plain task has no series")

            let listed = try await alice.tasks.tasks(groupId: group.id, includeOldDone: false)
            try Verify.equal(Set(listed), Set([weekly, tokyo, paris, daily, plain]), "the group's tasks carry their rules")
        },

        ContractScenario("recurrence.validation") { harness in
            let alice = try await harness.user("Alice")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup()
            _ = try await eve.makeGroup("Eve", joinedBy: [alice])
            let due = try utc("2041-10-07T16:00:00Z")
            func create(
                title: String = "Règle", details: String = "", dueAt: Date?, rule: RecurrenceRule?, assignees: Set<UUID> = []
            ) async throws -> TaskItem {
                try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                    title: title, details: details, dueAt: dueAt, assigneeIds: assignees, recurrence: rule
                ))
            }

            let invalid: [(String, RecurrenceRule)] = [
                ("interval 0", Rule.daily(interval: 0)),
                ("interval 53", Rule.daily(interval: Limits.repeatIntervalMax + 1)),
                ("weekdays on a daily rule", RecurrenceRule(frequency: .daily, weekdays: [1], timeZoneId: Zone.paris)),
                ("weekdays on a monthly rule", RecurrenceRule(frequency: .monthly, weekdays: [1], timeZoneId: Zone.paris)),
                ("empty weekdays", Rule.weekly(weekdays: [])),
                ("weekday 0", Rule.weekly(weekdays: [0])),
                ("weekday 8", Rule.weekly(weekdays: [8])),
                ("a zone in the wrong case", Rule.daily(tz: "europe/paris")),
                ("an unknown zone", Rule.daily(tz: "Europe/Pariss")),
                ("an abbreviation", Rule.daily(tz: "CEST")),
                ("a POSIX offset", Rule.daily(tz: "UTC+3")),
                ("a posix/ copy", Rule.daily(tz: "posix/Europe/Paris")),
            ]
            for (label, rule) in invalid {
                try await Verify.fails(with: .invalidRecurrence, "create: \(label)") { try await create(dueAt: due, rule: rule) }
            }
            try await Verify.fails(with: .recurrenceNeedsDueDate, "create: a rule without a due date") {
                try await create(dueAt: nil, rule: Rule.daily(tz: Zone.utc))
            }
            // Order (§3): title → details → due date → recurrence (shape, then due date) → assignees.
            let wrong = Rule.daily(interval: 0)
            try await Verify.fails(with: .invalidTitle, "the title before the rule") { try await create(title: "  ", dueAt: due, rule: wrong) }
            try await Verify.fails(with: .invalidDetails, "the details before the rule") {
                try await create(details: Fixed.text(Limits.taskDetailsMax + 1), dueAt: due, rule: wrong)
            }
            let outOfRange = InputValidation.dueDateRange.upperBound.addingTimeInterval(86_400)
            try await Verify.fails(with: .invalidInput, "the due date before the rule") { try await create(dueAt: outOfRange, rule: wrong) }
            try await Verify.fails(with: .invalidRecurrence, "the rule's shape before the due-date requirement") {
                try await create(dueAt: nil, rule: wrong)
            }
            try await Verify.fails(with: .invalidRecurrence, "the rule before the assignees") {
                try await create(dueAt: due, rule: wrong, assignees: [eve.id])
            }
            try await Verify.fails(with: .recurrenceNeedsDueDate, "the due-date requirement before the assignees") {
                try await create(dueAt: nil, rule: Rule.daily(), assignees: [eve.id])
            }

            // Accepted limits: interval 52, weekdays in any order, a three-part zone name, UTC.
            let accepted = [
                Rule.daily(interval: Limits.repeatIntervalMax), Rule.weekly(weekdays: [7, 1]),
                Rule.daily(tz: "America/Argentina/Buenos_Aires"), Rule.daily(tz: Zone.utc),
            ]
            for rule in accepted {
                let task = try await Verify.step("create with \(rule)") { try await create(dueAt: due, rule: rule) }
                try Verify.equal(task.recurrence, rule, "the rule \(rule) is stored as sent")
            }
            let tasks = try await alice.tasks.tasks(groupId: group.id, includeOldDone: true)
            try Verify.equal(tasks.count, accepted.count, "refused creations create nothing")

            // update_task: the same rules, after the title.
            let task = try Verify.unwrap(tasks.first, "a recurring task")
            try await Verify.fails(with: .recurrenceNeedsDueDate, "update: the due date cleared under a rule") {
                var draft = TaskDraft(task: task)
                draft.dueAt = nil
                return try await alice.tasks.update(taskId: task.id, draft: draft)
            }
            try await Verify.fails(with: .invalidRecurrence, "update: an invalid rule") {
                var draft = TaskDraft(task: task)
                draft.recurrence = wrong
                return try await alice.tasks.update(taskId: task.id, draft: draft)
            }
            try await Verify.fails(with: .invalidTitle, "update: the title before the rule") {
                var draft = TaskDraft(task: task)
                draft.title = ""
                draft.recurrence = wrong
                return try await alice.tasks.update(taskId: task.id, draft: draft)
            }
            let unchanged = try await alice.tasks.task(id: task.id)
            try Verify.equal(unchanged, task, "refused updates change nothing")
        },

        ContractScenario("recurrence.spawnOnCompletion") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let dueAt = try utc("2041-03-04T07:00:00Z")
            let first = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                title: Unique.name("Série"), details: "Détails", priority: .high, dueAt: dueAt,
                assigneeIds: [bob.id, carol.id], recurrence: Rule.daily(), checklist: ["Un", "Deux", "Trois"]
            ))
            let items = first.checklist
            try Verify.equal(items.map(\.title), ["Un", "Deux", "Trois"], "the initial checklist")
            try await alice.tasks.deleteChecklistItem(itemId: items[1].id)
            _ = try await alice.tasks.setChecklistItemDone(itemId: items[0].id, done: true)

            // Bob is an assignee, not an editor: completing still spawns the next occurrence.
            let (done, next) = try await bob.completeAndReadNext(first)
            let completedAt = try Verify.unwrap(done.completedAt, "completedAt")
            try Verify.equal(done.status, .done, "the completed occurrence")
            try Verify.equal(done.completedBy, bob.id, "completedBy = the completer")
            let fetchedDone = try await alice.tasks.task(id: first.id)
            try Verify.equal(fetchedDone, done, "task(id:) returns what setStatus returned")

            try Verify.equal(next.dueAt, try utc("2041-03-05T07:00:00Z"), "completed early: due one day after the due date")
            try Verify.equal(next.groupId, group.id, "the group")
            try Verify.equal(next.title, first.title, "the title is copied")
            try Verify.equal(next.details, "Détails", "the details are copied")
            try Verify.equal(next.priority, .high, "the priority is copied")
            try Verify.equal(next.status, .todo, "a new occurrence is to do")
            try Verify.equal(next.recurrence, first.recurrence, "the rule is copied")
            try Verify.equal(next.seriesId, first.id, "the series id is the first occurrence")
            try Verify.equal(next.createdBy, alice.id, "the series creator is kept (not the completer)")
            try Verify.equal(next.createdAt, completedAt, "created in the completion's transaction")
            try Verify.equal(next.updatedAt, completedAt, "updatedAt = createdAt")
            try Verify.equal(next.completedAt, nil, "not completed")
            try Verify.equal(next.completedBy, nil, "no completer")
            try Verify.equal(next.nextOccurrenceId, nil, "no next occurrence yet")
            try Verify.equal(next.assigneeIds, sortedIDs([bob, carol]), "the same assignees")
            try Verify.equal(next.checklist.map(\.title), ["Un", "Trois"], "the checklist is copied")
            try Verify.equal(next.checklist.map(\.position), [1, 3], "with the same positions (gaps kept)")
            try Verify.that(
                next.checklist.allSatisfy { !$0.isDone && $0.doneAt == nil && $0.doneBy == nil }, "the copied items are unchecked"
            )
            try Verify.that(Set(next.checklist.map(\.id)).isDisjoint(with: items.map(\.id)), "the copied items are new items")

            // Continuations notify no one (assigned_by = the assignee): not in assignments(since:).
            for user in [bob, carol] {
                let event = try await user.assignmentIfAny(of: next.id)
                try Verify.that(event == nil, "a continuation is not a new assignment for \(user.displayName), got \(String(describing: event))")
            }
            let bobTasks = try await bob.tasks.myTasks(includeDone: false)
            let mine = try Verify.unwrap(bobTasks.first { $0.id == next.id }, "the next occurrence in bob's tasks")
            try Verify.equal(mine.myAssignedBy, bob.id, "a continuation row is assigned by the assignee")
            try Verify.equal(mine.myAssignedAt, completedAt, "assigned in the completion's transaction")

            // Reopening, completing again, done → done: nothing more.
            _ = try await bob.tasks.setStatus(taskId: first.id, status: .todo)
            let redone = try await bob.tasks.setStatus(taskId: first.id, status: .done)
            try Verify.equal(redone.nextOccurrenceId, next.id, "completing again keeps the next occurrence")
            _ = try await carol.tasks.setStatus(taskId: first.id, status: .done)
            var series = try await alice.tasks.tasks(groupId: group.id, includeOldDone: true).filter { $0.seriesId == first.id }
            try Verify.equal(Set(series.map(\.id)), [first.id, next.id], "no second spawn")

            // The next occurrence continues the series.
            let (secondDone, third) = try await carol.completeAndReadNext(next)
            try Verify.equal(third.seriesId, first.id, "the same series")
            try Verify.equal(third.dueAt, try utc("2041-03-06T07:00:00Z"), "one day later")
            try Verify.equal(third.createdBy, alice.id, "the series creator")
            try Verify.equal(secondDone.completedBy, carol.id, "completed by carol")

            // Deleting the pending occurrence ends the series.
            try await alice.tasks.delete(taskId: third.id)
            _ = try await carol.tasks.setStatus(taskId: next.id, status: .todo)
            let again = try await carol.tasks.setStatus(taskId: next.id, status: .done)
            try Verify.equal(again.nextOccurrenceId, third.id, "nextOccurrenceId is kept after its deletion")
            series = try await alice.tasks.tasks(groupId: group.id, includeOldDone: true).filter { $0.seriesId == first.id }
            try Verify.equal(Set(series.map(\.id)), [first.id, next.id], "nothing respawns once the pending occurrence is deleted")
        },

        ContractScenario("recurrence.ruleEdits") { harness in
            let alice = try await harness.user("Alice")
            let group = try await alice.makeGroup()
            let first = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                title: Unique.name("Loyer"), dueAt: try utc("2041-01-31T17:00:00Z"), recurrence: Rule.monthly()
            ))
            try Verify.equal(first.recurrence?.monthDay, 31, "monthly on January 31")
            let (done, feb) = try await alice.completeAndReadNext(first)
            try Verify.equal(feb.dueAt, try utc("2041-02-28T17:00:00Z"), "the 31st → February 28")
            try Verify.equal(feb.recurrence?.monthDay, 31, "the spawn copies the month day (no drift)")

            // A full-draft edit with the same values changes nothing (month day 31 kept, updatedAt kept).
            let same = try await alice.tasks.update(taskId: feb.id, draft: TaskDraft(task: feb))
            try Verify.equal(same, feb, "an identical edit")
            // A new time on the same local date keeps the month day.
            var draft = TaskDraft(task: feb)
            draft.dueAt = try utc("2041-02-28T19:00:00Z")
            let later = try await alice.tasks.update(taskId: feb.id, draft: draft)
            try Verify.equal(later.recurrence?.monthDay, 31, "a new time on the same local date keeps month day 31")
            try Verify.that(later.updatedAt > feb.updatedAt, "a new due date moves updatedAt")
            // A new interval keeps it too, and a rule-only edit keeps updatedAt.
            draft = TaskDraft(task: later)
            draft.recurrence?.interval = 2
            let everyTwo = try await alice.tasks.update(taskId: feb.id, draft: draft)
            try Verify.equal(everyTwo.recurrence?.interval, 2, "the new interval")
            try Verify.equal(everyTwo.recurrence?.monthDay, 31, "a new interval keeps month day 31")
            try Verify.equal(everyTwo.updatedAt, later.updatedAt, "a rule-only edit keeps updatedAt")
            // A new zone, or a new local date, recomputes it.
            draft = TaskDraft(task: everyTwo)
            draft.recurrence?.timeZoneId = Zone.tokyo
            let tokyo = try await alice.tasks.update(taskId: feb.id, draft: draft)
            try Verify.equal(tokyo.recurrence?.monthDay, 1, "a new zone recomputes the month day (March 1 in Tokyo)")
            draft = TaskDraft(task: tokyo)
            draft.recurrence?.timeZoneId = Zone.paris
            let backToParis = try await alice.tasks.update(taskId: feb.id, draft: draft)
            try Verify.equal(backToParis.recurrence?.monthDay, 28, "back to Paris: the local day, 28")
            draft = TaskDraft(task: backToParis)
            draft.dueAt = try utc("2041-02-26T17:00:00Z")
            let moved = try await alice.tasks.update(taskId: feb.id, draft: draft)
            try Verify.equal(moved.recurrence?.monthDay, 26, "a new local due date recomputes the month day")
            draft = TaskDraft(task: moved)
            draft.recurrence = Rule.weekly()
            let weekly = try await alice.tasks.update(taskId: feb.id, draft: draft)
            try Verify.equal(weekly.recurrence, Rule.weekly(), "weekly: no month day")
            draft = TaskDraft(task: weekly)
            draft.recurrence = Rule.monthly()
            let monthlyAgain = try await alice.tasks.update(taskId: feb.id, draft: draft)
            try Verify.equal(monthlyAgain.recurrence?.monthDay, 26, "becoming monthly sets the month day")
            try Verify.equal(monthlyAgain.seriesId, first.id, "rule edits keep the series")
            let series = try await alice.tasks.tasks(groupId: group.id, includeOldDone: true).filter { $0.seriesId == first.id }
            try Verify.equal(Set(series.map(\.id)), [first.id, feb.id], "editing the rule never spawns")

            // Clearing the rule: a plain task; completing it spawns nothing.
            draft = TaskDraft(task: monthlyAgain)
            draft.recurrence = nil
            let plain = try await alice.tasks.update(taskId: feb.id, draft: draft)
            try Verify.equal(plain.recurrence, nil, "no rule")
            try Verify.equal(plain.seriesId, nil, "no series")
            try Verify.equal(plain.dueAt, monthlyAgain.dueAt, "the due date is kept")
            let plainDone = try await alice.tasks.setStatus(taskId: feb.id, status: .done)
            try Verify.equal(plainDone.nextOccurrenceId, nil, "a plain task spawns nothing")
            // A done occurrence whose rule is cleared keeps its next occurrence id and completion.
            var doneDraft = TaskDraft(task: done)
            doneDraft.recurrence = nil
            let doneCleared = try await alice.tasks.update(taskId: first.id, draft: doneDraft)
            try Verify.equal(doneCleared.nextOccurrenceId, feb.id, "nextOccurrenceId is kept")
            try Verify.equal(doneCleared.completedBy, alice.id, "completedBy is kept")
            try Verify.equal(doneCleared.seriesId, nil, "no series any more")
            // A plain task that gets a rule starts a new series.
            let other = try await alice.makeTask(in: group.id)
            var ruled = TaskDraft(task: other)
            ruled.dueAt = try utc("2041-05-10T08:00:00Z")
            ruled.recurrence = Rule.daily()
            let newSeries = try await alice.tasks.update(taskId: other.id, draft: ruled)
            try Verify.equal(newSeries.seriesId, other.id, "a new series starts at this occurrence")
            try Verify.equal(newSeries.recurrence, Rule.daily(), "the new rule")
        },

        ContractScenario("recurrence.spawnMatchesSpecVectors") { harness in
            let alice = try await harness.user("Alice")
            let group = try await alice.makeGroup()
            func spawn(_ label: String, rule: RecurrenceRule, due: Date) async throws -> (done: TaskItem, next: TaskItem) {
                let task = try await alice.makeRecurringTask(in: group.id, "Vecteur", rule: rule, dueAt: due)
                let result = try await alice.completeAndReadNext(task)
                try Verify.equal(result.next.recurrence, task.recurrence, "\(label): the rule is copied")
                return result
            }

            // Rows of the table of docs/CONTRACTS-V2.md §6 whose next due date is the first step after the due date:
            // any completion before that date gives exactly the table's value. On a backend whose clock is past it,
            // the missed occurrences are skipped: the expectation is then derived from its completion time.
            let rows: [(name: String, rule: RecurrenceRule, due: String, next: String)] = [
                ("2 completed early", Rule.daily(), "2026-09-26T18:00:00Z", "2026-09-27T18:00:00Z"),
                ("11 Tue/Thu every 2 weeks, from a Thursday", Rule.weekly(interval: 2, weekdays: [2, 4]),
                 "2026-09-24T16:00:00Z", "2026-10-06T16:00:00Z"),
                ("18 the 31st, leap year", Rule.monthly(), "2028-01-31T17:00:00Z", "2028-02-29T17:00:00Z"),
                ("22 the autumn DST change", Rule.weekly(), "2026-10-19T16:30:00Z", "2026-10-26T17:30:00Z"),
                ("25 Sunday only, UTC", Rule.weekly(weekdays: [7], tz: Zone.utc), "2026-09-27T20:00:00Z", "2026-10-04T20:00:00Z"),
            ]
            for row in rows {
                let due = try utc(row.due)
                let (done, next) = try await spawn("vector \(row.name)", rule: row.rule, due: due)
                let completedAt = try Verify.unwrap(done.completedAt, "vector \(row.name): completedAt")
                var expected = try utc(row.next)
                if completedAt >= expected {
                    let rule = try Verify.unwrap(done.recurrence, "vector \(row.name): the stored rule")
                    expected = try Verify.unwrap(
                        NextDueCalculator.nextDueDate(after: due, rule: rule, now: completedAt),
                        "vector \(row.name): the next due date after \(completedAt)"
                    )
                }
                try Verify.equal(next.dueAt, expected, "vector \(row.name) (completed at \(completedAt))")
            }

            // Vectors 14–17 in 2041 (always ahead of the backend's clock): the « 31st » series comes back to the 31st
            // after a short month, without drift, and keeps 18:00 local time across the spring DST change (March 31).
            let chain = [
                "2041-01-31T17:00:00Z", "2041-02-28T17:00:00Z", "2041-03-31T16:00:00Z", "2041-04-30T16:00:00Z",
                "2041-05-31T16:00:00Z",
            ]
            var occurrence = try await alice.makeRecurringTask(in: group.id, "Mensuel", rule: Rule.monthly(), dueAt: try utc(chain[0]))
            for expected in chain.dropFirst() {
                occurrence = try await alice.completeAndReadNext(occurrence).next
                try Verify.equal(occurrence.dueAt, try utc(expected), "monthly on the 31st → \(expected)")
                try Verify.equal(occurrence.recurrence?.monthDay, 31, "month day 31 is kept (\(expected))")
            }
            // Vector 24 in 2041: the local date counts (Jan 31 00:30 in Tokyo → Feb 28 00:30).
            let tokyo = try await spawn("Tokyo", rule: Rule.monthly(tz: Zone.tokyo), due: try utc("2041-01-30T15:30:00Z")).next
            try Verify.equal(tokyo.dueAt, try utc("2041-02-27T15:30:00Z"), "the local date in Tokyo")
            try Verify.equal(tokyo.recurrence?.monthDay, 31, "month day 31 in Tokyo")
            // Vector 22 in 2041: 18:30 CEST → 18:30 CET across the autumn change (October 27, 2041).
            let autumn = try await spawn("autumn", rule: Rule.weekly(), due: try utc("2041-10-21T16:30:00Z")).next
            try Verify.equal(autumn.dueAt, try utc("2041-10-28T17:30:00Z"), "weekly across the autumn DST change")
            // Vector 23 in 2041: another zone, 09:00 EST → 09:00 EDT (March 10, 2041).
            let newYork = try await spawn("New York", rule: Rule.daily(tz: Zone.newYork), due: try utc("2041-03-09T14:00:00Z")).next
            try Verify.equal(newYork.dueAt, try utc("2041-03-10T13:00:00Z"), "daily across the New York DST change")
            // Vector 7 in 2041: every 2 weeks, on the due date's weekday.
            let biweekly = try await spawn("biweekly", rule: Rule.weekly(interval: 2), due: try utc("2041-03-04T07:00:00Z")).next
            try Verify.equal(biweekly.dueAt, try utc("2041-03-18T07:00:00Z"), "every 2 weeks")

            // Missed occurrences, relative to the backend's now: a daily task overdue by 3 days at 07:15 in Paris comes
            // back at the first 07:15 after its completion (checked with the device's calendar, not the server's rule).
            let reference = try Verify.unwrap(try await alice.summary(of: group.id), "the group").group.createdAt
            let calendar = Zone.parisCalendar
            let threeDaysAgo = try Verify.unwrap(
                calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: reference)), "three days ago"
            )
            let overdueDue = try Verify.unwrap(
                calendar.date(bySettingHour: 7, minute: 15, second: 0, of: threeDaysAgo), "07:15 three days ago"
            )
            let (overdueDone, overdueNext) = try await spawn("overdue", rule: Rule.daily(), due: overdueDue)
            let completedAt = try Verify.unwrap(overdueDone.completedAt, "overdue completedAt")
            var expected = overdueDue
            while expected <= completedAt {
                expected = try Verify.unwrap(calendar.date(byAdding: .day, value: 1, to: expected), "the next day")
            }
            try Verify.equal(overdueNext.dueAt, expected, "missed occurrences are skipped (completed at \(completedAt))")
            try Verify.that(expected.timeIntervalSince(completedAt) <= 25 * 3600, "the next slot is within a day")
        },
    ]
}
