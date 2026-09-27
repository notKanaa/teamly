import Foundation
import TeamTasksCore

// v3 « Mode absent » and « Échanger mon tour » (docs/CONTRACTS-V3.md §2, §3, §10). Absences and due dates are in 2041
// (Europe/Paris): the clock rule of `set_away` (`until >= current_date - 1`) is only checked with a date in the past.
extension ContractScenarios {
    static let awaySwapScenarios: [ContractScenario] = [
        ContractScenario("away.setAndClear") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let first = try await alice.makeGroup("Un", joinedBy: [bob])
            let second = try await bob.makeGroup("Deux", joinedBy: [alice])
            let from = try day("2041-03-01")
            let until = try day("2041-03-10")
            let bumpedFirst = try await bob.lastActivity(of: first.id)

            let profile = try await alice.profiles.setAway(from: from, until: until, announce: true)
            try Verify.equal(profile.awayFrom, from, "the first day")
            try Verify.equal(profile.awayUntil, until, "the last day")
            try Verify.equal(profile, try await alice.profiles.myProfile(), "set_away returns the profile myProfile() reads")
            let seen = try await bob.member(alice.id, of: first.id)
            try Verify.equal(seen.user.awayFrom, from, "co-members read the absence")
            try Verify.equal(seen.user.awayUntil, until, "both dates")
            try Verify.that(seen.user.isAway(on: try day("2041-03-10")) && !seen.user.isAway(on: try day("2041-03-11")), "both days included")
            _ = try await bob.checkBumped(first.id, since: bumpedFirst, "a new absence (co-members reload the members)")
            for group in [first, second] {
                let events = try await bob.events(.memberAway, in: group.id)
                try Verify.equal(
                    events.map(EventShape.init),
                    [EventShape(.memberAway, actor: alice.id, subject: alice.id, startsOn: from, endsOn: until)],
                    "member_away in each of alice's groups"
                )
            }

            // Without the announcement: new dates, no event. One day is a valid absence.
            let single = try await alice.profiles.setAway(from: try day("2041-04-02"), until: try day("2041-04-02"), announce: false)
            try Verify.equal(single.awayRange, try day("2041-04-02")...(try day("2041-04-02")), "a one-day absence")
            try Verify.equal(try await bob.events(.memberAway, in: first.id).count, 1, "no announcement, no event")

            // invalid_away: order, more than 366 days (both ends counted), an end before yesterday. Refused calls change
            // nothing.
            try await Verify.fails(with: .invalidAway, "the end before the start") {
                try await alice.profiles.setAway(from: try day("2041-03-10"), until: try day("2041-03-09"), announce: true)
            }
            try await Verify.fails(with: .invalidAway, "367 days, both ends counted") {
                try await alice.profiles.setAway(from: try day("2041-01-01"), until: try day("2042-01-02"), announce: true)
            }
            try await Verify.fails(with: .invalidAway, "an absence over in the past") {
                try await alice.profiles.setAway(from: try day("2020-01-01"), until: try day("2020-01-05"), announce: true)
            }
            try Verify.equal(try await alice.profiles.myProfile(), single, "refused absences change nothing")
            let longest = try await alice.profiles.setAway(from: try day("2041-01-01"), until: try day("2042-01-01"), announce: false)
            try Verify.equal(longest.awayUntil, try day("2042-01-01"), "366 days, both ends counted, is the longest absence")

            // clear_away: no dates, no event; it bumps the groups (the absence ends), except without an absence.
            let feedBefore = try await bob.feed(of: first.id)
            let beforeClear = try await bob.lastActivity(of: first.id)
            let cleared = try await alice.profiles.clearAway()
            let afterClear = try await bob.checkBumped(first.id, since: beforeClear, "the end of an absence")
            try Verify.equal(cleared.awayFrom, nil, "no first day")
            try Verify.equal(cleared.awayUntil, nil, "no last day")
            try Verify.equal(try await bob.member(alice.id, of: first.id).user.awayRange, nil, "co-members read no absence")
            try Verify.equal(try await bob.feed(of: first.id), feedBefore, "clear_away writes no event")
            try Verify.equal(try await alice.profiles.clearAway(), cleared, "clearing again changes nothing")
            try Verify.equal(try await bob.lastActivity(of: first.id), afterClear, "and writes nothing")
        },

        ContractScenario("away.handover") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan])
            let inRange = try await dan.makeRotatingTask(in: group.id, "Dedans", dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [alice, bob, carol])
            let lateLocal = try await dan.makeRotatingTask(in: group.id, "Tard", dueAt: try utc("2041-03-10T22:30:00Z"), rotation: [alice, carol])
            let outside = try await dan.makeRotatingTask(in: group.id, "Dehors", dueAt: try utc("2041-03-12T07:00:00Z"), rotation: [alice, bob])
            let notMine = try await dan.makeRotatingTask(in: group.id, "Pas moi", dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [carol, alice])
            let plain = try await dan.makeTask(in: group.id, "Simple", assignees: [alice], dueAt: try utc("2041-03-04T07:00:00Z"))
            try Verify.equal(inRange.turnUserId, alice.id, "alice's turn")

            // Bob is away on 2041-03-04 too: the turn skips him.
            _ = try await bob.profiles.setAway(from: try day("2041-03-03"), until: try day("2041-03-05"), announce: false)
            _ = try await alice.profiles.setAway(from: try day("2041-03-01"), until: try day("2041-03-11"), announce: true)

            let handed = try await dan.tasks.task(id: inRange.id)
            try Verify.equal(handed.turnUserId, carol.id, "the next member who is not away (bob is away that day)")
            try Verify.equal(handed.assigneeIds, [carol.id], "the only assignee")
            try Verify.equal(handed.rotation, inRange.rotation, "the rotation is unchanged")
            let carolEvent = try await carol.assignment(of: inRange.id)
            try Verify.equal(carolEvent.assignedBy, nil, "a handover is assigned by nobody")
            try Verify.that(carolEvent.isRotationTurn, "worded « C’est ton tour »")
            // 2041-03-10T22:30Z is 2041-03-10 23:30 in Paris: in the range (the local due date counts).
            let late = try await dan.tasks.task(id: lateLocal.id)
            try Verify.equal(late.turnUserId, carol.id, "the local due date is in the range")
            try Verify.equal(try await dan.tasks.task(id: outside.id), outside, "a due date after the absence is untouched")
            try Verify.equal(try await dan.tasks.task(id: notMine.id), notMine, "an occurrence alice does not hold is untouched")
            try Verify.equal(try await dan.tasks.task(id: plain.id), plain, "a task without rotation is untouched")
            let turns = try await dan.events(.turnStarted, in: group.id)
            try Verify.equal(
                Set(turns.map(EventShape.init)),
                [
                    EventShape(.turnStarted, subject: carol.id, task: inRange.id, title: inRange.title),
                    EventShape(.turnStarted, subject: carol.id, task: lateLocal.id, title: lateLocal.title),
                ],
                "one turn_started per occurrence handed over"
            )
            try Verify.equal(try await dan.events(.memberAway, in: group.id).count, 1, "the announcement")

            // clear_away moves no turn back.
            _ = try await alice.profiles.clearAway()
            try Verify.equal(try await dan.tasks.task(id: inRange.id).turnUserId, carol.id, "the turn stays with carol")

            // Every candidate away: the normal choice.
            let pair = try await dan.makeRotatingTask(in: group.id, "Paire", dueAt: try utc("2041-05-06T07:00:00Z"), rotation: [alice, bob])
            _ = try await bob.profiles.setAway(from: try day("2041-05-01"), until: try day("2041-05-31"), announce: false)
            _ = try await alice.profiles.setAway(from: try day("2041-05-01"), until: try day("2041-05-31"), announce: false)
            let pairNow = try await dan.tasks.task(id: pair.id)
            try Verify.equal(pairNow.turnUserId, bob.id, "bob is away too: the next member all the same")
        },

        ContractScenario("away.skipOnCreateSpawnAndLeave") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let erin = try await harness.user("Erin")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan, erin])
            _ = try await bob.profiles.setAway(from: try day("2041-03-01"), until: try day("2041-03-20"), announce: false)

            // Create: the first listed member who is not away on the local due date.
            let task = try await alice.makeRotatingTask(in: group.id, dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [bob, carol, dan])
            try Verify.equal(task.turnUserId, carol.id, "bob is away: carol's turn")
            try Verify.equal(task.assigneeIds, [carol.id], "carol is the only assignee")
            try Verify.equal(try await carol.assignment(of: task.id).assignedBy, alice.id, "the first turn is assigned by the creator")

            // Spawn: the next member after the previous turn holder who is not away on the new due date.
            let second = try await carol.completeAndReadNext(task).next
            try Verify.equal(second.turnUserId, dan.id, "03-11: dan")
            let third = try await dan.completeAndReadNext(second).next
            try Verify.equal(third.dueAt, try utc("2041-03-18T07:00:00Z"), "the third occurrence")
            try Verify.equal(third.turnUserId, carol.id, "03-18: bob is away, carol")
            let fourth = try await carol.completeAndReadNext(third).next
            try Verify.equal(fourth.turnUserId, dan.id, "03-25: after carol, dan")
            let fifth = try await dan.completeAndReadNext(fourth).next
            try Verify.equal(fifth.turnUserId, bob.id, "04-01: bob is back")
            let bobEvent = try await bob.assignment(of: fifth.id)
            try Verify.that(bobEvent.isRotationTurn, "a turn handed out by the spawn")

            // Every candidate away at the creation: rotation[0].
            _ = try await dan.profiles.setAway(from: try day("2041-03-01"), until: try day("2041-03-10"), announce: false)
            let allAway = try await alice.makeRotatingTask(in: group.id, "Absents", dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [bob, dan])
            try Verify.equal(allAway.turnUserId, bob.id, "both are away: rotation[0] all the same")

            // The handover when the turn holder leaves skips the members away too.
            let leaving = try await alice.makeRotatingTask(in: group.id, "Depart", dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [erin, bob, alice])
            try Verify.equal(leaving.turnUserId, erin.id, "erin's turn")
            try await erin.groups.leave(groupId: group.id)
            let handed = try await alice.tasks.task(id: leaving.id)
            try Verify.equal(handed.turnUserId, alice.id, "erin left, bob is away: alice's turn")
            try Verify.equal(handed.assigneeIds, [alice.id], "alice is the only assignee")
        },

        ContractScenario("swap.requestAndAccept") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan])
            let task = try await dan.makeRotatingTask(in: group.id, dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [alice, bob, carol])
            let plain = try await dan.makeTask(in: group.id, "Simple", assignees: [alice])

            // Errors of the request: task_not_found → not_your_turn → invalid_rotation → swap_pending.
            try await Verify.fails(with: .notFound, "a non-member") { try await eve.tasks.requestTurnSwap(taskId: task.id, to: bob.id) }
            try await Verify.fails(with: .notFound, "an unknown task") { try await alice.tasks.requestTurnSwap(taskId: UUID(), to: bob.id) }
            try await Verify.fails(with: .notYourTurn, "bob does not hold the turn") {
                try await bob.tasks.requestTurnSwap(taskId: task.id, to: carol.id)
            }
            try await Verify.fails(with: .notYourTurn, "a task without rotation") {
                try await alice.tasks.requestTurnSwap(taskId: plain.id, to: bob.id)
            }
            try await Verify.fails(with: .notYourTurn, "the turn before the target") {
                try await bob.tasks.requestTurnSwap(taskId: task.id, to: eve.id)
            }
            try await Verify.fails(with: .invalidRotation, "a member outside the rotation") {
                try await alice.tasks.requestTurnSwap(taskId: task.id, to: dan.id)
            }
            try await Verify.fails(with: .invalidRotation, "herself") { try await alice.tasks.requestTurnSwap(taskId: task.id, to: alice.id) }
            try await Verify.fails(with: .invalidRotation, "a non-member") { try await alice.tasks.requestTurnSwap(taskId: task.id, to: eve.id) }

            var bumped = try await alice.lastActivity(of: group.id)
            let swap = try await alice.tasks.requestTurnSwap(taskId: task.id, to: bob.id)
            bumped = try await alice.checkBumped(group.id, since: bumped, "a proposal")
            try Verify.equal(swap.status, .pending, "pending")
            try Verify.equal(swap.taskId, task.id, "the occurrence")
            try Verify.equal(swap.groupId, group.id, "the group")
            try Verify.equal(swap.seriesId, task.id, "the series: the first occurrence")
            try Verify.equal(swap.fromUserId, alice.id, "from the turn holder")
            try Verify.equal(swap.toUserId, bob.id, "to bob")
            try Verify.equal(swap.respondedAt, nil, "not answered")
            try Verify.equal(swap.repaidAt, nil, "not repaid")
            try await Verify.fails(with: .swapPending, "a second proposal") { try await alice.tasks.requestTurnSwap(taskId: task.id, to: carol.id) }
            try Verify.equal(try await carol.tasks.turnSwaps(taskId: task.id), [swap], "members read the swaps of the task")
            try await Verify.hidden("a non-member reads none") { try await eve.tasks.turnSwaps(taskId: task.id) }
            try Verify.equal(try await bob.tasks.pendingTurnSwaps(), [swap], "proposed to bob")
            try Verify.equal(try await alice.tasks.pendingTurnSwaps(), [swap], "proposed by alice")
            try await Verify.hidden("nothing pending for carol") { try await carol.tasks.pendingTurnSwaps() }
            try Verify.equal(try await dan.tasks.task(id: task.id), task, "a proposal changes nothing yet")

            // Errors of the answer: swap_not_found → forbidden → swap_not_pending.
            try await Verify.fails(with: .notFound, "a non-member answers") { try await eve.tasks.respondToTurnSwap(swapId: swap.id, accept: true) }
            try await Verify.fails(with: .notFound, "an unknown swap") { try await bob.tasks.respondToTurnSwap(swapId: UUID(), accept: true) }
            try await Verify.fails(with: .forbidden, "carol answers") { try await carol.tasks.respondToTurnSwap(swapId: swap.id, accept: true) }
            try await Verify.fails(with: .forbidden, "the author answers") { try await alice.tasks.respondToTurnSwap(swapId: swap.id, accept: true) }
            try await Verify.fails(with: .forbidden, "the target cancels") { try await bob.tasks.cancelTurnSwap(swapId: swap.id) }
            try await Verify.fails(with: .notFound, "a non-member cancels") { try await eve.tasks.cancelTurnSwap(swapId: swap.id) }

            let accepted = try await bob.tasks.respondToTurnSwap(swapId: swap.id, accept: true)
            try Verify.equal(accepted.status, .accepted, "accepted")
            try Verify.that(accepted.respondedAt != nil, "answered")
            try Verify.equal(accepted.id, swap.id, "the same swap")
            let taken = try await dan.tasks.task(id: task.id)
            try Verify.equal(taken.turnUserId, bob.id, "bob's turn")
            try Verify.equal(taken.assigneeIds, [bob.id], "bob is the only assignee")
            try Verify.equal(taken.rotation, task.rotation, "the rotation is unchanged")
            try Verify.that(try await bob.assignmentIfAny(of: task.id) == nil, "bob accepted: assigned by himself, no notification")
            let mine = try await bob.tasks.myTasks(includeDone: false)
            try Verify.equal(mine.first { $0.id == task.id }?.myAssignedBy, bob.id, "assigned by bob")
            _ = try await alice.checkBumped(group.id, since: bumped, "an accepted swap")
            let events = try await carol.events(.turnSwapped, in: group.id)
            try Verify.equal(
                events.map(EventShape.init), [EventShape(.turnSwapped, actor: bob.id, subject: alice.id, task: task.id, title: task.title)],
                "turn_swapped: actor = who took the turn, subject = who gave it"
            )
            try Verify.equal(events.first?.createdAt, accepted.respondedAt, "written with the answer")
            try Verify.equal(try await carol.tasks.turnSwaps(taskId: task.id), [accepted], "the read agrees")
            try await Verify.hidden("nothing pending any more") { try await bob.tasks.pendingTurnSwaps() }
            try await Verify.fails(with: .swapNotPending, "answered twice") { try await bob.tasks.respondToTurnSwap(swapId: swap.id, accept: false) }
            try await Verify.fails(with: .swapNotPending, "cancelled after the answer") { try await alice.tasks.cancelTurnSwap(swapId: swap.id) }
            try await Verify.fails(with: .notYourTurn, "alice no longer holds the turn") {
                try await alice.tasks.requestTurnSwap(taskId: task.id, to: carol.id)
            }
        },

        ContractScenario("swap.declineCancelAndAutoCancel") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let group = try await dan.makeGroup(joinedBy: [alice, bob, carol])
            let task = try await dan.makeRotatingTask(in: group.id, dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [alice, bob, carol])

            // Declined: the turn stays; a new proposal is allowed. Every swap write bumps the group.
            let first = try await alice.tasks.requestTurnSwap(taskId: task.id, to: bob.id)
            var bumped = try await dan.lastActivity(of: group.id)
            let declined = try await bob.tasks.respondToTurnSwap(swapId: first.id, accept: false)
            bumped = try await dan.checkBumped(group.id, since: bumped, "a refusal")
            try Verify.equal(declined.status, .declined, "declined")
            try Verify.that(declined.respondedAt != nil, "answered")
            try Verify.equal(try await dan.tasks.task(id: task.id), task, "a declined swap changes nothing on the task")
            try Verify.equal(try await dan.events(.turnSwapped, in: group.id), [], "no event")

            // Cancelled by its author.
            let second = try await alice.tasks.requestTurnSwap(taskId: task.id, to: carol.id)
            try await Verify.fails(with: .forbidden, "carol cannot cancel it") { try await carol.tasks.cancelTurnSwap(swapId: second.id) }
            bumped = try await dan.lastActivity(of: group.id)
            let cancelled = try await alice.tasks.cancelTurnSwap(swapId: second.id)
            try Verify.equal(cancelled.status, .cancelled, "cancelled")
            try Verify.that(cancelled.respondedAt != nil, "every status change sets respondedAt")
            _ = try await dan.checkBumped(group.id, since: bumped, "a cancellation")
            try await Verify.fails(with: .swapNotPending, "answered after the cancellation") {
                try await carol.tasks.respondToTurnSwap(swapId: second.id, accept: true)
            }
            try await Verify.fails(with: .swapNotPending, "cancelled twice") { try await alice.tasks.cancelTurnSwap(swapId: second.id) }
            try Verify.equal(try await dan.tasks.turnSwaps(taskId: task.id).map(\.status), [.declined, .cancelled], "the history")

            // Automatic cancellation: the occurrence becomes done.
            let third = try await alice.tasks.requestTurnSwap(taskId: task.id, to: bob.id)
            let (_, next) = try await alice.completeAndReadNext(task)
            var swaps = try await dan.tasks.turnSwaps(taskId: task.id)
            try Verify.equal(swaps.last?.id, third.id, "the third swap")
            try Verify.equal(swaps.last?.status, .cancelled, "done: the pending swap is cancelled")
            try Verify.that(swaps.last?.respondedAt != nil, "an automatic cancellation sets respondedAt")
            try Verify.equal(next.turnUserId, bob.id, "the spawn follows the rotation")

            // … the turn holder changes another way: a new rotation without him.
            let fourth = try await bob.tasks.requestTurnSwap(taskId: next.id, to: carol.id)
            var draft = TaskDraft(task: next)
            draft.rotation = [carol.id, alice.id, dan.id]
            let edited = try await dan.tasks.update(taskId: next.id, draft: draft)
            try Verify.equal(edited.turnUserId, carol.id, "the turn goes to rotation[0]")
            swaps = try await dan.tasks.turnSwaps(taskId: next.id)
            try Verify.equal(swaps.map(\.id), [fourth.id], "the fourth swap")
            try Verify.equal(swaps.first?.status, .cancelled, "the turn holder changed: cancelled")

            // … the turn holder leaves (handover).
            let fifth = try await carol.tasks.requestTurnSwap(taskId: next.id, to: alice.id)
            try await carol.groups.leave(groupId: group.id)
            swaps = try await dan.tasks.turnSwaps(taskId: next.id)
            try Verify.equal(swaps.last?.id, fifth.id, "the fifth swap")
            try Verify.equal(swaps.last?.status, .cancelled, "the turn holder left: cancelled")

            // … the rotation no longer lists the target (the turn holder is kept).
            try Verify.equal(try await dan.tasks.task(id: next.id).turnUserId, alice.id, "alice's turn after carol left")
            let sixth = try await alice.tasks.requestTurnSwap(taskId: next.id, to: dan.id)
            var narrowing = TaskDraft(task: try await dan.tasks.task(id: next.id))
            narrowing.rotation = [alice.id, bob.id]
            let narrowed = try await dan.tasks.update(taskId: next.id, draft: narrowing)
            try Verify.equal(narrowed.turnUserId, alice.id, "alice keeps the turn")
            swaps = try await dan.tasks.turnSwaps(taskId: next.id)
            try Verify.equal(swaps.last?.id, sixth.id, "the sixth swap")
            try Verify.equal(swaps.last?.status, .cancelled, "the target is no longer listed: cancelled")
            // … the target leaves the group.
            let seventh = try await alice.tasks.requestTurnSwap(taskId: next.id, to: bob.id)
            try await bob.groups.leave(groupId: group.id)
            swaps = try await dan.tasks.turnSwaps(taskId: next.id)
            try Verify.equal(swaps.last?.id, seventh.id, "the seventh swap")
            try Verify.equal(swaps.last?.status, .cancelled, "the target left: cancelled")
            // … the occurrence is deleted: its swaps go with it.
            try await dan.tasks.delete(taskId: next.id)
            try await Verify.hidden("the swaps of a deleted occurrence") { try await dan.tasks.turnSwaps(taskId: next.id) }
            try await Verify.hidden("nothing pending for alice") { try await alice.tasks.pendingTurnSwaps() }
        },

        ContractScenario("swap.repayment") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await carol.makeGroup(joinedBy: [alice, bob])
            let first = try await carol.makeRotatingTask(in: group.id, dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [alice, bob, carol])

            // Alice gives her turn to Bob; Bob does it.
            let swap = try await alice.tasks.requestTurnSwap(taskId: first.id, to: bob.id)
            _ = try await bob.tasks.respondToTurnSwap(swapId: swap.id, accept: true)
            let second = try await bob.completeAndReadNext(try await carol.tasks.task(id: first.id)).next
            try Verify.equal(second.turnUserId, carol.id, "after bob's turn, carol's")
            let third = try await carol.completeAndReadNext(second).next
            try Verify.equal(third.turnUserId, alice.id, "then alice's (the next turn is not bob's: nothing to repay)")
            try Verify.equal(try await carol.tasks.turnSwaps(taskId: first.id).first?.repaidAt, nil, "not repaid yet")

            // The turn would be bob's: alice pays the favour back.
            let (thirdDone, fourth) = try await alice.completeAndReadNext(third)
            try Verify.equal(fourth.turnUserId, alice.id, "bob's turn goes to alice, who owed it")
            try Verify.equal(fourth.assigneeIds, [alice.id], "alice is the only assignee")
            let repaid = try Verify.unwrap(try await carol.tasks.turnSwaps(taskId: first.id).first, "the swap")
            try Verify.equal(repaid.status, .accepted, "still accepted")
            try Verify.equal(repaid.repaidAt, thirdDone.completedAt, "repaid at the spawn")
            try Verify.that(try await alice.assignmentIfAny(of: fourth.id) == nil, "alice completed and takes the turn: not notified")
            let turn = try Verify.unwrap(try await carol.events(.turnStarted, in: group.id).first, "the last turn_started")
            try Verify.equal(EventShape(turn), EventShape(.turnStarted, subject: alice.id, task: fourth.id, title: first.title), "alice's turn")

            // Repaid once: the rotation goes on.
            let fifth = try await alice.completeAndReadNext(fourth).next
            try Verify.equal(fifth.turnUserId, bob.id, "then bob's turn again")
            let bobEvent = try await bob.assignment(of: fifth.id)
            try Verify.that(bobEvent.isRotationTurn, "handed out by the spawn")

            // An author who is away on the new due date is not repaid then.
            let other = try await carol.makeRotatingTask(in: group.id, "Autre", dueAt: try utc("2041-06-03T07:00:00Z"), rotation: [alice, bob])
            let owed = try await alice.tasks.requestTurnSwap(taskId: other.id, to: bob.id)
            _ = try await bob.tasks.respondToTurnSwap(swapId: owed.id, accept: true)
            _ = try await alice.profiles.setAway(from: try day("2041-06-05"), until: try day("2041-06-15"), announce: false)
            let otherNext = try await bob.completeAndReadNext(try await carol.tasks.task(id: other.id)).next
            try Verify.equal(otherNext.dueAt, try utc("2041-06-10T07:00:00Z"), "the next week")
            try Verify.equal(otherNext.turnUserId, bob.id, "alice is away that day: bob again (absence skip)")
            try Verify.equal(try await carol.tasks.turnSwaps(taskId: other.id).first?.repaidAt, nil, "alice is away: not repaid yet")
            _ = try await alice.profiles.clearAway()
            let (otherDone, repaidNext) = try await bob.completeAndReadNext(otherNext)
            try Verify.equal(repaidNext.turnUserId, alice.id, "back: after bob comes alice anyway")
            try Verify.equal(try await carol.tasks.turnSwaps(taskId: other.id).first?.repaidAt, nil, "the next turn is alice's own: nothing repaid")
            _ = otherDone
        },
    ]
}
