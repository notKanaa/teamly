import Foundation
import TeamTasksCore

// Realtime change signals (docs/CONTRACTS.md §6). Every scenario subscribes with `ContractUser.subscribe`
// (`.connected`, then a barrier flush), then waits (bounded) for the expected event after a mark. Absence is
// checked by ordering: no matching event between a mark and a later barrier flush.
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

        // Binding INSERT task_assignees filtered on user_id=eq.<me>: assignments of co-members are not delivered.
        ContractScenario("realtime.assignedOnlyToMe") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let probe = try await bob.subscribe(groups: [group.id])
            defer { probe.stop() }

            let mark = probe.mark()
            let forCarol = try await alice.makeTask(in: group.id, assignees: [carol])
            let later = try await alice.makeTask(in: group.id)
            _ = try await alice.reassign(later, to: [carol, alice])
            try await probe.expectNone(since: mark, "no .assigned for other members' assignments") {
                if case .assigned = $0 { return true }
                return false
            }
            let next = probe.mark()
            _ = try await alice.reassign(forCarol, to: [carol, bob])
            try await probe.waitFor("bob's own assignment", after: next) {
                $0 == .assigned(taskId: forCarol.id, groupId: group.id, assignedBy: alice.id)
            }
        },

        // Binding UPDATE profiles filtered on id=eq.<me>: co-members' membership changes are not delivered.
        ContractScenario("realtime.membershipsChangedOnlyForMe") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let probe = try await bob.subscribe(groups: [group.id])
            defer { probe.stop() }

            let mark = probe.mark()
            _ = try await carol.join(group)
            try await alice.groups.setRole(groupId: group.id, userId: carol.id, role: .admin)
            try await alice.groups.removeMember(groupId: group.id, userId: carol.id)
            try await probe.expectNone(since: mark, "no .membershipsChanged for other members' changes") {
                $0 == .membershipsChanged
            }
            let next = probe.mark()
            try await alice.groups.setRole(groupId: group.id, userId: bob.id, role: .admin)
            try await probe.waitFor("bob's own role change", after: next) { $0 == .membershipsChanged }
        },

        // groups UPDATE follows RLS: a removed member no longer receives the group's activity.
        ContractScenario("realtime.groupActivityOnlyForMembers") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let probe = try await bob.subscribe(groups: [group.id])
            defer { probe.stop() }

            var mark = probe.mark()
            try await alice.groups.removeMember(groupId: group.id, userId: bob.id)
            try await probe.waitFor("membershipsChanged after the removal", after: mark) { $0 == .membershipsChanged }
            try await probe.flush("the removal")
            mark = probe.mark()
            _ = try await alice.makeTask(in: group.id)
            _ = try await alice.groups.rename(groupId: group.id, name: Unique.name("Groupe"))
            try await probe.expectNone(since: mark, "no groupActivity of a group bob left") {
                $0 == .groupActivity(groupId: group.id)
            }
        },
    ]
}
