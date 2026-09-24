package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.RealtimeEvent
import java.util.UUID

// Membership rules (docs/CONTRACTS.md §2): roles, last admin, removal, leaving.
internal val memberScenarios: List<ContractScenario> = listOf(
    ContractScenario("members.sortedAdminsFirstThenName") { harness ->
        val delta = harness.user("Delta")
        val alpha = harness.user("Alpha")
        val charlie = harness.user("Charlie")
        val bravo = harness.user("Bravo")
        val group = delta.makeGroup(joinedBy = listOf(alpha, charlie, bravo))
        val initial = bravo.memberIds(group.id)
        Verify.equal(initial, listOf(delta, alpha, bravo, charlie).map { it.id }, "admins first, then by display name")

        delta.groups.setRole(group.id, charlie.id, MemberRole.ADMIN)
        val promoted = alpha.groups.members(group.id)
        Verify.equal(
            promoted.map { it.user.id }, listOf(charlie, delta, alpha, bravo).map { it.id }, "order after a promotion",
        )
        Verify.equal(
            promoted.map { it.role },
            listOf(MemberRole.ADMIN, MemberRole.ADMIN, MemberRole.MEMBER, MemberRole.MEMBER),
            "roles after a promotion",
        )
    },

    ContractScenario("members.setRole") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val carol = harness.user("Carol")
        val eve = harness.user("Eve")
        val group = alice.makeGroup(joinedBy = listOf(bob, carol))
        Verify.fails(AppError.Forbidden, "a member changes a role") {
            bob.groups.setRole(group.id, carol.id, MemberRole.ADMIN)
        }
        Verify.fails(AppError.Forbidden, "a non-member changes a role") {
            eve.groups.setRole(group.id, carol.id, MemberRole.ADMIN)
        }
        Verify.fails(AppError.NotMember, "role of a non-member") {
            alice.groups.setRole(group.id, eve.id, MemberRole.ADMIN)
        }
        Verify.fails(AppError.LastAdmin, "the only admin demotes themselves") {
            alice.groups.setRole(group.id, alice.id, MemberRole.MEMBER)
        }

        alice.groups.setRole(group.id, bob.id, MemberRole.ADMIN)
        val bobRole = bob.role(group.id)
        Verify.equal(bobRole, MemberRole.ADMIN, "promoted member's role")
        Verify.step("an admin demotes themselves while another admin exists") {
            alice.groups.setRole(group.id, alice.id, MemberRole.MEMBER)
        }
        val aliceRole = alice.role(group.id)
        Verify.equal(aliceRole, MemberRole.MEMBER, "self-demoted admin's role")
        Verify.fails(AppError.Forbidden, "a demoted admin changes a role") {
            alice.groups.setRole(group.id, carol.id, MemberRole.ADMIN)
        }
        Verify.fails(AppError.LastAdmin, "the new last admin demotes themselves") {
            bob.groups.setRole(group.id, bob.id, MemberRole.MEMBER)
        }
        Verify.step("an admin promotes then demotes another admin") {
            bob.groups.setRole(group.id, alice.id, MemberRole.ADMIN)
            bob.groups.setRole(group.id, alice.id, MemberRole.MEMBER)
        }
        val members = carol.groups.members(group.id)
        Verify.equal(members.map { it.user.id }, listOf(bob, alice, carol).map { it.id }, "final member order")
        Verify.equal(
            members.map { it.role }, listOf(MemberRole.ADMIN, MemberRole.MEMBER, MemberRole.MEMBER), "final roles",
        )
    },

    // SQL set_member_role returns before any write when the role does not change.
    ContractScenario("members.noOpRoleChange") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        bob.subscribe(listOf(group.id)).use { probe ->
            val before = alice.lastActivity(group.id)

            val mark = probe.mark()
            Verify.step("set unchanged roles") {
                alice.groups.setRole(group.id, bob.id, MemberRole.MEMBER)
                alice.groups.setRole(group.id, alice.id, MemberRole.ADMIN) // the only admin
            }
            probe.expectNone(mark, "no signal for an unchanged role") {
                it == RealtimeEvent.MembershipsChanged || it == RealtimeEvent.GroupActivity(group.id)
            }
            val after = alice.lastActivity(group.id)
            Verify.equal(after, before, "an unchanged role keeps lastActivityAt")
            val members = bob.groups.members(group.id)
            Verify.equal(members.map { it.role }, listOf(MemberRole.ADMIN, MemberRole.MEMBER), "roles unchanged")
        }
    },

    ContractScenario("members.remove") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val carol = harness.user("Carol")
        val eve = harness.user("Eve")
        val group = alice.makeGroup(joinedBy = listOf(bob, carol))
        val byBob = bob.makeTask(group.id, assignees = listOf(bob, carol))
        val byAlice = alice.makeTask(group.id, assignees = listOf(bob))

        Verify.fails(AppError.Forbidden, "a member removes someone") { bob.groups.removeMember(group.id, carol.id) }
        Verify.fails(AppError.Forbidden, "a non-member removes someone") { eve.groups.removeMember(group.id, carol.id) }
        Verify.fails(AppError.CannotRemoveSelf, "an admin removes themselves") {
            alice.groups.removeMember(group.id, alice.id)
        }
        Verify.fails(AppError.NotMember, "remove a non-member") { alice.groups.removeMember(group.id, eve.id) }

        Verify.step("admin removes bob") { alice.groups.removeMember(group.id, bob.id) }
        val remaining = alice.memberIds(group.id)
        Verify.equal(remaining, listOf(alice.id, carol.id), "members after removal")
        val bobGroups = bob.groups.myGroups()
        Verify.that(bobGroups.none { it.id == group.id }, "a removed member no longer lists the group")
        val kept = alice.tasks.task(byBob.id)
        Verify.equal(kept.createdBy, bob.id, "tasks created by a removed member stay (createdBy kept)")
        Verify.equal(kept.assigneeIds, listOf(carol.id), "the removed member's assignments are deleted")
        val other = alice.tasks.task(byAlice.id)
        Verify.equal(other.assigneeIds, emptyList<UUID>(), "the removed member's assignments are deleted everywhere")
        Verify.fails(AppError.NotFound, "a removed member reads a task of the group") { bob.tasks.task(byBob.id) }

        alice.groups.setRole(group.id, carol.id, MemberRole.ADMIN)
        Verify.step("an admin removes another admin") { alice.groups.removeMember(group.id, carol.id) }
        val alone = alice.memberIds(group.id)
        Verify.equal(alone, listOf(alice.id), "members after removing an admin")
        Verify.fails(AppError.NotMember, "remove someone twice") { alice.groups.removeMember(group.id, carol.id) }
    },

    ContractScenario("members.leave") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val carol = harness.user("Carol")
        val eve = harness.user("Eve")
        val group = alice.makeGroup(joinedBy = listOf(bob, carol))
        val task = bob.makeTask(group.id, assignees = listOf(bob, alice))

        Verify.fails(AppError.LastAdmin, "the only admin leaves while members remain") { alice.groups.leave(group.id) }
        Verify.step("a member leaves") { bob.groups.leave(group.id) }
        val bobGroups = bob.groups.myGroups()
        Verify.that(bobGroups.none { it.id == group.id }, "the group is gone from the leaver's list")
        val members = alice.memberIds(group.id)
        Verify.equal(members, listOf(alice.id, carol.id), "members after leaving")
        val kept = alice.tasks.task(task.id)
        Verify.equal(kept.createdBy, bob.id, "tasks of a leaver stay")
        Verify.equal(kept.assigneeIds, listOf(alice.id), "the leaver's assignments are deleted")

        Verify.fails(AppError.NotMember, "leave twice") { bob.groups.leave(group.id) }
        Verify.fails(AppError.NotMember, "a non-member leaves") { eve.groups.leave(group.id) }
        Verify.fails(AppError.NotMember, "leave an unknown group") { eve.groups.leave(UUID.randomUUID()) }

        alice.groups.setRole(group.id, carol.id, MemberRole.ADMIN)
        Verify.step("an admin leaves once another admin exists") { alice.groups.leave(group.id) }
        val last = carol.groups.members(group.id)
        Verify.equal(last.map { it.user.id }, listOf(carol.id), "members after the admin left")
        Verify.equal(last.map { it.role }, listOf(MemberRole.ADMIN), "the remaining admin")
    },

    ContractScenario("members.lastMemberLeavingDeletesGroup") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup()
        val task = alice.makeTask(group.id, assignees = listOf(alice))
        Verify.step("the last member leaves") { alice.groups.leave(group.id) }
        val groups = alice.groups.myGroups()
        Verify.that(groups.none { it.id == group.id }, "the group is gone")
        Verify.fails(AppError.InvalidCode, "the code of a group deleted by its last member") {
            bob.groups.join(group.code)
        }
        Verify.fails(AppError.NotFound, "a task of the deleted group") { alice.tasks.task(task.id) }
    },
)
