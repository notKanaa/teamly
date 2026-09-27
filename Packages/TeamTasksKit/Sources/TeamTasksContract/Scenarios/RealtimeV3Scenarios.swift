import Foundation
import TeamTasksCore

// v3 Realtime bindings (docs/CONTRACTS-V3.md §11): the five new bindings of the single channel. Same method as the v1
// and v2 Realtime scenarios (subscribe, wait for an expected event after a mark, check absence between a mark and a
// later flush); their names start with `realtime.`, so backends that skip Realtime skip them too.
extension ContractScenarios {
    static let realtimeV3Scenarios: [ContractScenario] = [
        ContractScenario("realtime.v3Nudges") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let task = try await alice.makeTask(in: group.id, assignees: [bob, carol])
            let bobProbe = try await bob.subscribe(groups: [group.id])
            defer { bobProbe.stop() }
            let aliceProbe = try await alice.subscribe(groups: [group.id])
            defer { aliceProbe.stop() }

            let bobMark = bobProbe.mark()
            let aliceMark = aliceProbe.mark()
            _ = try await alice.tasks.nudge(taskId: task.id)
            let (_, event) = try await bobProbe.waitFor("bob is nudged", after: bobMark) {
                if case let .nudged(_, taskId, groupId, fromUserId) = $0 {
                    return taskId == task.id && groupId == group.id && fromUserId == alice.id
                }
                return false
            }
            try await bobProbe.expectNone(since: bobMark, "only bob's own nudge") {
                if case .nudged = $0 { return $0 != event }
                return false
            }
            try await aliceProbe.expectNone(since: aliceMark, "the author is not nudged") {
                if case .nudged = $0 { return true }
                return false
            }
        },

        ContractScenario("realtime.v3Swaps") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await carol.makeGroup(joinedBy: [alice, bob])
            let task = try await carol.makeRotatingTask(in: group.id, dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [alice, bob, carol])
            let aliceProbe = try await alice.subscribe(groups: [group.id])
            defer { aliceProbe.stop() }
            let bobProbe = try await bob.subscribe(groups: [group.id])
            defer { bobProbe.stop() }
            let carolProbe = try await carol.subscribe(groups: [group.id])
            defer { carolProbe.stop() }
            let carolStart = carolProbe.mark()

            // Proposed: the target gets the INSERT.
            var bobMark = bobProbe.mark()
            var aliceMark = aliceProbe.mark()
            let first = try await alice.tasks.requestTurnSwap(taskId: task.id, to: bob.id)
            try await bobProbe.waitFor("bob gets the proposal", after: bobMark) {
                $0 == .turnSwapProposed(swapId: first.id, taskId: task.id, groupId: group.id, fromUserId: alice.id)
            }
            try await aliceProbe.expectNone(since: aliceMark, "the author gets no proposal") {
                if case .turnSwapProposed = $0 { return true }
                return false
            }

            // Declined: the author gets the UPDATE.
            aliceMark = aliceProbe.mark()
            bobMark = bobProbe.mark()
            _ = try await bob.tasks.respondToTurnSwap(swapId: first.id, accept: false)
            try await aliceProbe.waitFor("alice learns the refusal", after: aliceMark) {
                $0 == .turnSwapUpdated(
                    swapId: first.id, taskId: task.id, groupId: group.id, toUserId: bob.id, status: .declined, isRepaid: false
                )
            }
            try await bobProbe.expectNone(since: bobMark, "the target gets no update") {
                if case .turnSwapUpdated = $0 { return true }
                return false
            }

            // Cancelled by the author, then accepted.
            aliceMark = aliceProbe.mark()
            let second = try await alice.tasks.requestTurnSwap(taskId: task.id, to: bob.id)
            _ = try await alice.tasks.cancelTurnSwap(swapId: second.id)
            try await aliceProbe.waitFor("alice's own cancellation", after: aliceMark) {
                $0 == .turnSwapUpdated(
                    swapId: second.id, taskId: task.id, groupId: group.id, toUserId: bob.id, status: .cancelled, isRepaid: false
                )
            }
            aliceMark = aliceProbe.mark()
            let third = try await alice.tasks.requestTurnSwap(taskId: task.id, to: bob.id)
            _ = try await bob.tasks.respondToTurnSwap(swapId: third.id, accept: true)
            try await aliceProbe.waitFor("alice learns the acceptance", after: aliceMark) {
                $0 == .turnSwapUpdated(
                    swapId: third.id, taskId: task.id, groupId: group.id, toUserId: bob.id, status: .accepted, isRepaid: false
                )
            }
            try await carolProbe.expectNone(since: carolStart, "carol is neither the author nor the target") {
                switch $0 {
                case .turnSwapProposed, .turnSwapUpdated: true
                default: false
                }
            }
        },

        ContractScenario("realtime.v3Reactions") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            _ = try await alice.makeTask(in: group.id, "Alice")
            _ = try await carol.makeTask(in: group.id, "Carol")
            let created = try await alice.events(.taskCreated, in: group.id)
            let aliceEvent = try Verify.unwrap(created.first { $0.actorId == alice.id }, "alice's event")
            let carolEvent = try Verify.unwrap(created.first { $0.actorId == carol.id }, "carol's event")
            let probe = try await alice.subscribe(groups: [group.id])
            defer { probe.stop() }

            var mark = probe.mark()
            _ = try await bob.groups.toggleReaction(activityId: aliceEvent.id, emoji: .fire)
            try await probe.waitFor("bob reacts to alice's event", after: mark) {
                $0 == .reactionAdded(activityId: aliceEvent.id, groupId: group.id, userId: bob.id, emoji: .fire)
            }
            mark = probe.mark()
            _ = try await bob.groups.toggleReaction(activityId: carolEvent.id, emoji: .clap)
            _ = try await bob.groups.toggleReaction(activityId: aliceEvent.id, emoji: .fire)
            try await probe.expectNone(since: mark, "another member's event, and a removal (DELETE is never published)") {
                if case .reactionAdded = $0 { return true }
                return false
            }
            mark = probe.mark()
            _ = try await alice.groups.toggleReaction(activityId: aliceEvent.id, emoji: .heart)
            try await probe.waitFor("alice's own reaction targets her too (clients skip it)", after: mark) {
                $0 == .reactionAdded(activityId: aliceEvent.id, groupId: group.id, userId: alice.id, emoji: .heart)
            }
        },

        ContractScenario("realtime.v3Comments") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let elsewhere = try await bob.makeGroup("Ailleurs")
            let task = try await alice.makeTask(in: group.id, assignees: [carol])
            let away = try await bob.makeTask(in: elsewhere.id)
            let probe = try await carol.subscribe(groups: [group.id])
            defer { probe.stop() }

            var mark = probe.mark()
            let comment = try await bob.tasks.addComment(taskId: task.id, body: "Tu peux\u{00A0}?", mentions: [carol.id])
            try await probe.waitFor("a comment in carol's group", after: mark) {
                $0 == .commentAdded(commentId: comment.id, taskId: task.id, groupId: group.id, authorId: bob.id, mentions: [carol.id])
            }
            mark = probe.mark()
            let own = try await carol.tasks.addComment(taskId: task.id, body: "Oui", mentions: [])
            try await probe.waitFor("her own comment arrives too (clients skip it)", after: mark) {
                $0 == .commentAdded(commentId: own.id, taskId: task.id, groupId: group.id, authorId: carol.id, mentions: [])
            }
            mark = probe.mark()
            _ = try await bob.tasks.addComment(taskId: away.id, body: "Ailleurs", mentions: [])
            try await probe.expectNone(since: mark, "a group carol does not belong to") {
                if case .commentAdded = $0 { return true }
                return false
            }
        },
    ]
}
