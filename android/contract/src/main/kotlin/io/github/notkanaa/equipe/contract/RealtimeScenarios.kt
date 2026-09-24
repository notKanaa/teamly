package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.core.TaskStatus

// Realtime change signals (docs/CONTRACTS.md §6). Every scenario subscribes with `ContractUser.subscribe` (Connected,
// then a barrier flush), then waits (bounded) for the expected event after a mark. Absence is checked by ordering:
// no matching event between a mark and a later barrier flush.
internal val realtimeScenarios: List<ContractScenario> = listOf(
    ContractScenario("realtime.connectedFirst") { harness ->
        val alice = harness.user("Alice")
        val group = alice.makeGroup()
        StreamProbe(alice.realtime.events(alice.id, listOf(group.id))).use { probe ->
            val first = probe.waitFor("first realtime event") { true }
            Verify.equal(first.value, RealtimeEvent.Connected, "the first event")
        }
    },

    ContractScenario("realtime.groupActivity") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        alice.subscribe(listOf(group.id)).use { probe ->
            val activity = RealtimeEvent.GroupActivity(group.id)

            var mark = probe.mark()
            val task = bob.makeTask(group.id)
            probe.waitFor("groupActivity after a task creation", after = mark) { it == activity }
            mark = probe.mark()
            bob.tasks.setStatus(task.id, TaskStatus.DONE)
            probe.waitFor("groupActivity after a status change", after = mark) { it == activity }
            mark = probe.mark()
            alice.groups.rename(group.id, Unique.name("Groupe"))
            probe.waitFor("groupActivity after a rename", after = mark) { it == activity }
            mark = probe.mark()
            bob.groups.leave(group.id)
            probe.waitFor("groupActivity after a member left", after = mark) { it == activity }
        }
    },

    ContractScenario("realtime.groupFilter") { harness ->
        val alice = harness.user("Alice")
        val watched = alice.makeGroup("Suivi")
        val ignored = alice.makeGroup("Ignore")
        alice.subscribe(listOf(watched.id)).use { probe ->
            val mark = probe.mark()
            alice.makeTask(ignored.id)
            alice.makeTask(watched.id)
            val match = probe.waitFor("groupActivity of the watched group", after = mark) {
                it == RealtimeEvent.GroupActivity(watched.id)
            }
            val before = probe.events.subList(mark, match.index)
            Verify.that(
                RealtimeEvent.GroupActivity(ignored.id) !in before,
                "no groupActivity for a group outside the filter, got $before",
            )
        }
    },

    ContractScenario("realtime.membershipsChanged") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup()
        bob.subscribe(emptyList()).use { probe ->
            var mark = probe.mark()
            bob.join(group)
            probe.waitFor("membershipsChanged after joining", after = mark) { it == RealtimeEvent.MembershipsChanged }
            mark = probe.mark()
            alice.groups.setRole(group.id, bob.id, MemberRole.ADMIN)
            probe.waitFor("membershipsChanged after a role change", after = mark) {
                it == RealtimeEvent.MembershipsChanged
            }
            mark = probe.mark()
            alice.groups.removeMember(group.id, bob.id)
            probe.waitFor("membershipsChanged after removal", after = mark) { it == RealtimeEvent.MembershipsChanged }
            mark = probe.mark()
            bob.join(group)
            probe.waitFor("membershipsChanged after rejoining", after = mark) {
                it == RealtimeEvent.MembershipsChanged
            }
            mark = probe.mark()
            alice.groups.deleteGroup(group.id)
            probe.waitFor("membershipsChanged after the group was deleted", after = mark) {
                it == RealtimeEvent.MembershipsChanged
            }
        }
    },

    ContractScenario("realtime.assigned") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        bob.subscribe(listOf(group.id)).use { probe ->
            var mark = probe.mark()
            val byAlice = alice.makeTask(group.id, assignees = listOf(bob))
            probe.waitFor("assigned by alice", after = mark) {
                it == RealtimeEvent.Assigned(byAlice.id, group.id, alice.id)
            }
            mark = probe.mark()
            val own = bob.makeTask(group.id, assignees = listOf(bob))
            probe.waitFor("self-assignment", after = mark) { it == RealtimeEvent.Assigned(own.id, group.id, bob.id) }
            val unassigned = alice.makeTask(group.id)
            mark = probe.mark()
            alice.reassign(unassigned, listOf(bob))
            probe.waitFor("assigned through an update", after = mark) {
                it == RealtimeEvent.Assigned(unassigned.id, group.id, alice.id)
            }
        }
    },

    // Binding INSERT task_assignees filtered on user_id=eq.<me>: assignments of co-members are not delivered.
    ContractScenario("realtime.assignedOnlyToMe") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val carol = harness.user("Carol")
        val group = alice.makeGroup(joinedBy = listOf(bob, carol))
        bob.subscribe(listOf(group.id)).use { probe ->
            val mark = probe.mark()
            val forCarol = alice.makeTask(group.id, assignees = listOf(carol))
            val later = alice.makeTask(group.id)
            alice.reassign(later, listOf(carol, alice))
            probe.expectNone(mark, "no .assigned for other members' assignments") { it is RealtimeEvent.Assigned }
            val next = probe.mark()
            alice.reassign(forCarol, listOf(carol, bob))
            probe.waitFor("bob's own assignment", after = next) {
                it == RealtimeEvent.Assigned(forCarol.id, group.id, alice.id)
            }
        }
    },

    // Binding UPDATE profiles filtered on id=eq.<me>: co-members' membership changes are not delivered.
    ContractScenario("realtime.membershipsChangedOnlyForMe") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val carol = harness.user("Carol")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        bob.subscribe(listOf(group.id)).use { probe ->
            val mark = probe.mark()
            carol.join(group)
            alice.groups.setRole(group.id, carol.id, MemberRole.ADMIN)
            alice.groups.removeMember(group.id, carol.id)
            probe.expectNone(mark, "no .membershipsChanged for other members' changes") {
                it == RealtimeEvent.MembershipsChanged
            }
            val next = probe.mark()
            alice.groups.setRole(group.id, bob.id, MemberRole.ADMIN)
            probe.waitFor("bob's own role change", after = next) { it == RealtimeEvent.MembershipsChanged }
        }
    },

    // groups UPDATE follows RLS: a removed member no longer receives the group's activity.
    ContractScenario("realtime.groupActivityOnlyForMembers") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        bob.subscribe(listOf(group.id)).use { probe ->
            var mark = probe.mark()
            alice.groups.removeMember(group.id, bob.id)
            probe.waitFor("membershipsChanged after the removal", after = mark) {
                it == RealtimeEvent.MembershipsChanged
            }
            probe.flush("the removal")
            mark = probe.mark()
            alice.makeTask(group.id)
            alice.groups.rename(group.id, Unique.name("Groupe"))
            probe.expectNone(mark, "no groupActivity of a group bob left") {
                it == RealtimeEvent.GroupActivity(group.id)
            }
        }
    },
)
