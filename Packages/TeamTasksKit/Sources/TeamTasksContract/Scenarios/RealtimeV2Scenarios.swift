import Foundation
import TeamTasksCore

// v2 change signals (docs/CONTRACTS-V2.md §0, §2, §5, §6): nothing new is published to Realtime, the v2 writes reuse
// the v1 bindings. Same method as the v1 Realtime scenarios: subscribe (`.connected`, then a barrier flush), wait
// (bounded) for an expected event after a mark, check absence between a mark and a later flush. Their names start
// with `realtime.`, so backends that skip Realtime skip them too.
extension ContractScenarios {
    static let realtimeV2Scenarios: [ContractScenario] = [
        ContractScenario("realtime.v2GroupSignals") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let task = try await alice.makeTask(in: group.id, assignees: [alice])
            let probe = try await bob.subscribe(groups: [group.id])
            defer { probe.stop() }
            let activity = RealtimeEvent.groupActivity(groupId: group.id)
            let start = probe.mark()

            var mark = probe.mark()
            _ = try await alice.groups.setAppearance(groupId: group.id, color: .teal, emoji: "🧺")
            try await probe.waitFor("groupActivity after setAppearance", after: mark) { $0 == activity }
            mark = probe.mark()
            _ = try await alice.profiles.updateDisplayName(Unique.name("Alice"))
            try await probe.waitFor("groupActivity after a co-member's display-name change", after: mark) { $0 == activity }
            mark = probe.mark()
            _ = try await alice.profiles.updateAvatar(color: .pink, emoji: "🦊")
            try await probe.waitFor("groupActivity after a co-member's avatar change", after: mark) { $0 == activity }
            mark = probe.mark()
            _ = try await alice.profiles.updateAvatar(color: .pink, emoji: "🦊")
            try await alice.profiles.completeOnboarding()
            try await probe.expectNone(since: mark, "no groupActivity for identical values nor the onboarding") { $0 == activity }

            mark = probe.mark()
            let item = try await alice.tasks.addChecklistItem(taskId: task.id, title: "Un")
            try await probe.waitFor("groupActivity after adding an item", after: mark) { $0 == activity }
            mark = probe.mark()
            _ = try await alice.tasks.setChecklistItemDone(itemId: item.id, done: true)
            try await probe.waitFor("groupActivity after checking an item", after: mark) { $0 == activity }
            mark = probe.mark()
            _ = try await alice.tasks.setChecklistItemDone(itemId: item.id, done: true)
            try await probe.expectNone(since: mark, "no groupActivity for a no-op check") { $0 == activity }
            mark = probe.mark()
            try await alice.tasks.deleteChecklistItem(itemId: item.id)
            try await probe.waitFor("groupActivity after deleting an item", after: mark) { $0 == activity }
            // A co-member's profile changes never reach bob's own profile binding.
            let received = Array(probe.events[start...])
            try Verify.that(!received.contains(.membershipsChanged), "no membershipsChanged for alice's profile, got \(received)")
        },

        ContractScenario("realtime.v2OwnProfileSignals") { harness in
            let alice = try await harness.user("Alice")
            let probe = try await alice.subscribe(groups: [])
            defer { probe.stop() }

            var mark = probe.mark()
            _ = try await alice.profiles.updateAvatar(color: .green, emoji: "🌱")
            try await probe.waitFor("membershipsChanged after an avatar change", after: mark) { $0 == .membershipsChanged }
            mark = probe.mark()
            try await alice.profiles.completeOnboarding()
            try await probe.waitFor("membershipsChanged after completing the onboarding", after: mark) { $0 == .membershipsChanged }
            mark = probe.mark()
            try await alice.profiles.completeOnboarding()
            try await probe.expectNone(since: mark, "an onboarded account writes nothing") { $0 == .membershipsChanged }
        },

        ContractScenario("realtime.v2RotationTurns") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan])
            let task = try await alice.makeRecurringTask(
                in: group.id, rule: Rule.weekly(), dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [bob, carol, dan]
            )
            let carolProbe = try await carol.subscribe(groups: [group.id])
            defer { carolProbe.stop() }
            let danProbe = try await dan.subscribe(groups: [group.id])
            defer { danProbe.stop() }

            // A spawn hands the turn to the next member, assigned by nobody.
            let carolMark = carolProbe.mark()
            var danMark = danProbe.mark()
            let done = try await bob.tasks.setStatus(taskId: task.id, status: .done)
            let nextId = try Verify.unwrap(done.nextOccurrenceId, "the next occurrence")
            try await carolProbe.waitFor("carol's turn", after: carolMark) {
                $0 == .assigned(taskId: nextId, groupId: group.id, assignedBy: nil)
            }
            try await danProbe.expectNone(since: danMark, "not dan's turn yet", where: isAssignment)

            // The turn holder leaves: the next member is assigned by nobody, at once.
            danMark = danProbe.mark()
            try await carol.groups.leave(groupId: group.id)
            try await danProbe.waitFor("dan's turn after carol left", after: danMark) {
                $0 == .assigned(taskId: nextId, groupId: group.id, assignedBy: nil)
            }
        },
    ]
}
