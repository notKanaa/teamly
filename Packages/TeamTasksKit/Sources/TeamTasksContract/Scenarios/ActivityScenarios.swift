import Foundation
import TeamTasksCore

// v2 activity feed (docs/CONTRACTS-V2.md §7) and the weekly recap read (§8). The 90-day retention needs a controllable
// clock: it is covered by the backend-specific tests (mock clock, pgTAP).
extension ContractScenarios {
    static let activityScenarios: [ContractScenario] = [
        ContractScenario("activity.everyKind") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let group = try await alice.makeGroup("Activite", joinedBy: [bob, carol, dan])
            let rejoined = try await bob.join(group)
            try Verify.that(rejoined.alreadyMember, "bob is already a member")

            let title = Unique.name("Vaisselle")
            let task = try await bob.tasks.create(groupId: group.id, draft: TaskDraft(title: "  \(title) ", assigneeIds: [carol.id]))
            let firstDone = try await carol.tasks.setStatus(taskId: task.id, status: .done)
            _ = try await carol.tasks.setStatus(taskId: task.id, status: .done)
            _ = try await carol.tasks.setStatus(taskId: task.id, status: .inProgress)
            let secondDone = try await carol.tasks.setStatus(taskId: task.id, status: .done)
            let item = try await bob.tasks.addChecklistItem(taskId: task.id, title: "Les verres")
            let checked = try await carol.tasks.setChecklistItemDone(itemId: item.id, done: true)
            _ = try await carol.tasks.setChecklistItemDone(itemId: item.id, done: true)
            _ = try await carol.tasks.setChecklistItemDone(itemId: item.id, done: false)
            let rotating = try await bob.makeRecurringTask(
                in: group.id, "Poubelles", rule: Rule.weekly(), dueAt: try utc("2041-03-02T19:00:00Z"), rotation: [bob, carol, dan]
            )
            let (rotatingDone, next) = try await bob.completeAndReadNext(rotating)
            try await alice.groups.removeMember(groupId: group.id, userId: carol.id)
            try await dan.groups.leave(groupId: group.id)

            let feed = try await bob.feed(of: group.id)
            let expected: [EventShape] = [
                EventShape(.memberLeft, actor: dan.id, subject: dan.id),
                EventShape(.turnStarted, subject: dan.id, task: next.id, title: rotating.title),
                EventShape(.memberLeft, actor: alice.id, subject: carol.id),
                EventShape(.turnStarted, subject: carol.id, task: next.id, title: rotating.title),
                EventShape(.taskCompleted, actor: bob.id, task: rotating.id, title: rotating.title),
                EventShape(.taskCreated, actor: bob.id, task: rotating.id, title: rotating.title),
                EventShape(.checklistItemDone, actor: carol.id, task: task.id, title: title, item: "Les verres"),
                EventShape(.taskCompleted, actor: carol.id, task: task.id, title: title),
                EventShape(.taskCompleted, actor: carol.id, task: task.id, title: title),
                EventShape(.taskCreated, actor: bob.id, task: task.id, title: title),
                EventShape(.memberJoined, actor: dan.id, subject: dan.id),
                EventShape(.memberJoined, actor: carol.id, subject: carol.id),
                EventShape(.memberJoined, actor: bob.id, subject: bob.id),
            ]
            try Verify.equal(feed.map(EventShape.init), expected, "the feed, newest first (the creator's own membership is not a join)")
            for (newer, older) in zip(feed, feed.dropFirst()) {
                try Verify.that(newer.id > older.id, "ids decrease: \(newer.id) after \(older.id)")
                try Verify.that(newer.createdAt >= older.createdAt, "dates do not increase: \(newer.createdAt) after \(older.createdAt)")
            }
            // Every event is dated by the write that caused it.
            try Verify.equal(feed[3].createdAt, rotatingDone.completedAt, "the spawn's turn_started is written with the completion")
            try Verify.equal(feed[4].createdAt, rotatingDone.completedAt, "task_completed at the completion")
            try Verify.equal(feed[5].createdAt, rotating.createdAt, "task_created at the creation")
            try Verify.equal(feed[6].createdAt, checked.doneAt, "checklist_item_done at the check")
            try Verify.equal(feed[7].createdAt, secondDone.completedAt, "the second completion")
            try Verify.equal(feed[8].createdAt, firstDone.completedAt, "the first completion")
            try Verify.equal(feed[9].createdAt, task.createdAt, "task_created at the creation")

            // Every member reads the same feed; former members and non-members read nothing.
            let aliceFeed = try await alice.feed(of: group.id)
            try Verify.equal(aliceFeed, feed, "every member reads the same feed")
            try await Verify.hidden("the feed for a removed member") { try await carol.groups.activity(groupId: group.id) }
            try await Verify.hidden("the feed for a member who left") { try await dan.groups.activity(groupId: group.id) }
            let eve = try await harness.user("Eve")
            try await Verify.hidden("the feed for a non-member") { try await eve.groups.activity(groupId: group.id) }
            try await Verify.hidden("the feed of an unknown group") { try await alice.groups.activity(groupId: UUID()) }
        },

        ContractScenario("activity.snapshots") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let task = try await bob.makeTask(in: group.id, "Vaisselle", assignees: [bob])
            let item = try await bob.tasks.addChecklistItem(taskId: task.id, title: "Les verres")
            _ = try await bob.tasks.setChecklistItemDone(itemId: item.id, done: true)
            let done = try await bob.tasks.setStatus(taskId: task.id, status: .done)
            var draft = TaskDraft(task: done)
            draft.title = Unique.name("Renommée")
            _ = try await bob.tasks.update(taskId: task.id, draft: draft)
            _ = try await bob.tasks.renameChecklistItem(itemId: item.id, title: "Les assiettes")
            try await bob.tasks.delete(taskId: task.id)

            let events = try await alice.feed(of: group.id).filter { $0.taskId == task.id }
            try Verify.equal(
                events.map(EventShape.init),
                [
                    EventShape(.taskCompleted, actor: bob.id, task: task.id, title: task.title),
                    EventShape(.checklistItemDone, actor: bob.id, task: task.id, title: task.title, item: "Les verres"),
                    EventShape(.taskCreated, actor: bob.id, task: task.id, title: task.title),
                ],
                "the events keep their titles and task id after a rename and the deletion"
            )
        },

        ContractScenario("activity.deletedAccount") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let frank = try await harness.user("Frank")
            let group = try await alice.makeGroup(joinedBy: [bob, frank])
            let frankTask = try await frank.makeTask(in: group.id, "Ancienne")
            let rotating = try await alice.makeRecurringTask(
                in: group.id, rule: Rule.weekly(), dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [frank, bob, alice]
            )
            try await frank.auth.deleteAccount()

            let feed = try await alice.feed(of: group.id)
            try Verify.equal(
                feed.map(EventShape.init),
                [
                    EventShape(.turnStarted, subject: bob.id, task: rotating.id, title: rotating.title),
                    EventShape(.memberLeft),
                    EventShape(.taskCreated, actor: alice.id, task: rotating.id, title: rotating.title),
                    EventShape(.taskCreated, task: frankTask.id, title: frankTask.title),
                    EventShape(.memberJoined),
                    EventShape(.memberJoined, actor: bob.id, subject: bob.id),
                ],
                "member_left (no actor, no subject) then turn_started; the account's earlier events lose their references"
            )
            try Verify.that(
                !feed.contains { $0.actorId == frank.id || $0.subjectId == frank.id }, "no event references the deleted account"
            )
            let handed = try await alice.tasks.task(id: rotating.id)
            try Verify.equal(handed.turnUserId, bob.id, "the turn was handed over")
        },

        ContractScenario("activity.readLimit") { harness in
            let alice = try await harness.user("Alice")
            let group = try await alice.makeGroup()
            var created: [TaskItem] = []
            for index in 1...(Limits.activityFeedMax + 1) {
                created.append(try await alice.makeTask(in: group.id, "Tâche\(index)"))
            }
            let feed = try await alice.feed(of: group.id)
            try Verify.equal(feed.count, Limits.activityFeedMax, "at most 50 events are read")
            try Verify.equal(
                feed.map(\.taskId), created.dropFirst().reversed().map { Optional($0.id) }, "the newest 50, newest first"
            )
        },
    ]

    static let recapScenarios: [ContractScenario] = [
        ContractScenario("recap.completions") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan])
            let other = try await alice.makeGroup("Autre")
            let t1 = try await alice.makeTask(in: group.id, assignees: [bob])
            let t2 = try await alice.makeTask(in: group.id, assignees: [bob])
            let t3 = try await alice.makeTask(in: group.id, assignees: [carol])
            let t4 = try await alice.makeTask(in: group.id, assignees: [alice])
            let t5 = try await alice.makeTask(in: group.id, assignees: [bob])
            let t6 = try await alice.makeTask(in: group.id, assignees: [dan])
            let elsewhere = try await alice.makeTask(in: other.id, assignees: [alice])
            let d1 = try await bob.tasks.setStatus(taskId: t1.id, status: .done)
            let d2 = try await bob.tasks.setStatus(taskId: t2.id, status: .done)
            let d3 = try await carol.tasks.setStatus(taskId: t3.id, status: .done)
            let d4 = try await alice.tasks.setStatus(taskId: t4.id, status: .done)
            _ = try await bob.tasks.setStatus(taskId: t5.id, status: .inProgress)
            let d6 = try await dan.tasks.setStatus(taskId: t6.id, status: .done)
            _ = try await alice.tasks.setStatus(taskId: elsewhere.id, status: .done)
            func completion(_ task: TaskItem) throws -> TaskCompletion {
                TaskCompletion(
                    taskId: task.id, completedBy: task.completedBy,
                    completedAt: try Verify.unwrap(task.completedAt, "completedAt of \(task.title)")
                )
            }
            let expected = try [d1, d2, d3, d4, d6].map(completion)

            let all = try await alice.tasks.completions(groupId: group.id, since: Fixed.longAgo)
            try Verify.equal(Set(all), Set(expected), "the group's done tasks, with their completer and completion date")
            let seenByBob = try await bob.tasks.completions(groupId: group.id, since: Fixed.longAgo)
            try Verify.equal(Set(seenByBob), Set(expected), "every member reads the same completions")
            let fromSecond = try await alice.tasks.completions(groupId: group.id, since: try Verify.unwrap(d2.completedAt, "d2"))
            try Verify.equal(Set(fromSecond.map(\.taskId)), [t2.id, t3.id, t4.id, t6.id], "since is inclusive")
            let afterLast = try await alice.tasks.completions(
                groupId: group.id, since: try Verify.unwrap(d6.completedAt, "d6").addingTimeInterval(0.001)
            )
            try Verify.that(afterLast.isEmpty, "nothing after the last completion, got \(afterLast)")
            try await Verify.hidden("completions for a non-member") {
                try await eve.tasks.completions(groupId: group.id, since: Fixed.longAgo)
            }

            // The recap of the week (when every completion falls in the same week of the French calendar).
            let members = try await alice.groups.members(groupId: group.id)
            let now = try Verify.unwrap(d6.completedAt, "the last completion")
            let recap = WeeklyRecap(completions: all, members: members, now: now, calendar: Zone.parisCalendar)
            if WeeklyRecap.weekStart(of: try Verify.unwrap(d1.completedAt, "d1"), calendar: Zone.parisCalendar) == recap.weekStart {
                try Verify.equal(recap.total, 5, "the week's total")
                try Verify.equal(recap.podium.map(\.user.id), [bob.id, alice.id, carol.id], "bob first, then by name")
                try Verify.equal(recap.podium.map(\.count), [2, 1, 1], "the podium's counts")
            }

            // A reopened task is no longer done; a completer who left keeps the completion (the recap leaves them out);
            // the completions of a deleted account have no completer.
            _ = try await bob.tasks.setStatus(taskId: t2.id, status: .todo)
            try await carol.groups.leave(groupId: group.id)
            try await dan.auth.deleteAccount()
            let final = try await alice.tasks.completions(groupId: group.id, since: Fixed.longAgo)
            let deleted = TaskCompletion(taskId: t6.id, completedBy: nil, completedAt: try Verify.unwrap(d6.completedAt, "d6"))
            try Verify.equal(
                Set(final), Set(try [d1, d3, d4].map(completion) + [deleted]),
                "reopened tasks disappear; a former member's completion stays; a deleted account's has no completer"
            )
        },

        ContractScenario("recap.completedBy") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let task = try await alice.makeTask(in: group.id, assignees: [bob, carol])
            try Verify.equal(task.completedBy, nil, "a new task has no completer")
            let done = try await bob.tasks.setStatus(taskId: task.id, status: .done)
            try Verify.equal(done.completedBy, bob.id, "the user whose change made the task done")
            let again = try await carol.tasks.setStatus(taskId: task.id, status: .done)
            try Verify.equal(again.completedBy, bob.id, "done → done keeps the completer")
            try Verify.equal(again.completedAt, done.completedAt, "and the completion date")
            var draft = TaskDraft(task: again)
            draft.title = Unique.name("Modifiée")
            let edited = try await alice.tasks.update(taskId: task.id, draft: draft)
            try Verify.equal(edited.completedBy, bob.id, "editing a done task keeps the completer")
            let reopened = try await carol.tasks.setStatus(taskId: task.id, status: .inProgress)
            try Verify.equal(reopened.completedBy, nil, "leaving done clears the completer")
            let redone = try await carol.tasks.setStatus(taskId: task.id, status: .done)
            try Verify.equal(redone.completedBy, carol.id, "the next completion records the new completer")
            let fetched = try await alice.tasks.task(id: task.id)
            try Verify.equal(fetched, redone, "task(id:) returns what setStatus returned")
        },
    ]
}
