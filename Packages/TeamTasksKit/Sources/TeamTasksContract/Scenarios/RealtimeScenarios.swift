import Foundation
import TeamTasksCore

// Realtime change signals (docs/CONTRACTS.md §6). Every scenario waits for `.connected` before acting,
// then waits (bounded) for the expected event after a mark. Absence is only checked by ordering: an event
// that must not arrive is checked not to precede an event that must arrive later.
extension ContractScenarios {
    static let realtimeScenarios: [ContractScenario] = [
        ContractScenario("realtime.connectedFirst") { harness in
            let alice = try await harness.user("Alice")
            let group = try await alice.makeGroup()
            let probe = StreamProbe(alice.realtime.events(userId: alice.id, groupIds: [group.id]))
            defer { probe.stop() }
            let first = try await probe.waitFor("first realtime event") { _ in true }
            try Verify.equal(first.element, .connected, "the first event")
        },

        ContractScenario("realtime.groupActivity") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let probe = try await alice.subscribe(groups: [group.id])
            defer { probe.stop() }
            let activity = RealtimeEvent.groupActivity(groupId: group.id)

            var mark = probe.mark()
            let task = try await bob.makeTask(in: group.id)
            try await probe.waitFor("groupActivity after a task creation", after: mark) { $0 == activity }
            mark = probe.mark()
            _ = try await bob.tasks.setStatus(taskId: task.id, status: .done)
            try await probe.waitFor("groupActivity after a status change", after: mark) { $0 == activity }
            mark = probe.mark()
            _ = try await alice.groups.rename(groupId: group.id, name: Unique.name("Groupe"))
            try await probe.waitFor("groupActivity after a rename", after: mark) { $0 == activity }
            mark = probe.mark()
            try await bob.groups.leave(groupId: group.id)
            try await probe.waitFor("groupActivity after a member left", after: mark) { $0 == activity }
        },

        ContractScenario("realtime.groupFilter") { harness in
            let alice = try await harness.user("Alice")
            let watched = try await alice.makeGroup("Suivi")
            let ignored = try await alice.makeGroup("Ignore")
            let probe = try await alice.subscribe(groups: [watched.id])
            defer { probe.stop() }
            let mark = probe.mark()
            _ = try await alice.makeTask(in: ignored.id)
            _ = try await alice.makeTask(in: watched.id)
            let match = try await probe.waitFor("groupActivity of the watched group", after: mark) {
                $0 == .groupActivity(groupId: watched.id)
            }
            let before = probe.events[mark..<match.index]
            try Verify.that(
                !before.contains(.groupActivity(groupId: ignored.id)),
                "no groupActivity for a group outside the filter, got \(Array(before))"
            )
        },

        ContractScenario("realtime.membershipsChanged") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup()
            let probe = try await bob.subscribe(groups: [])
            defer { probe.stop() }

            var mark = probe.mark()
            _ = try await bob.join(group)
            try await probe.waitFor("membershipsChanged after joining", after: mark) { $0 == .membershipsChanged }
            mark = probe.mark()
            try await alice.groups.setRole(groupId: group.id, userId: bob.id, role: .admin)
            try await probe.waitFor("membershipsChanged after a role change", after: mark) { $0 == .membershipsChanged }
            mark = probe.mark()
            try await alice.groups.removeMember(groupId: group.id, userId: bob.id)
            try await probe.waitFor("membershipsChanged after removal", after: mark) { $0 == .membershipsChanged }
            mark = probe.mark()
            _ = try await bob.join(group)
            try await probe.waitFor("membershipsChanged after rejoining", after: mark) { $0 == .membershipsChanged }
            mark = probe.mark()
            try await alice.groups.deleteGroup(groupId: group.id)
            try await probe.waitFor("membershipsChanged after the group was deleted", after: mark) {
                $0 == .membershipsChanged
            }
        },

        ContractScenario("realtime.assigned") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let probe = try await bob.subscribe(groups: [group.id])
            defer { probe.stop() }

            var mark = probe.mark()
            let byAlice = try await alice.makeTask(in: group.id, assignees: [bob])
            try await probe.waitFor("assigned by alice", after: mark) {
                $0 == .assigned(taskId: byAlice.id, groupId: group.id, assignedBy: alice.id)
            }
            mark = probe.mark()
            let own = try await bob.makeTask(in: group.id, assignees: [bob])
            try await probe.waitFor("self-assignment", after: mark) {
                $0 == .assigned(taskId: own.id, groupId: group.id, assignedBy: bob.id)
            }
            let unassigned = try await alice.makeTask(in: group.id)
            mark = probe.mark()
            _ = try await alice.reassign(unassigned, to: [bob])
            try await probe.waitFor("assigned through an update", after: mark) {
                $0 == .assigned(taskId: unassigned.id, groupId: group.id, assignedBy: alice.id)
            }
        },
    ]
}
