package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.UserProfile
import java.util.UUID

// Groups, invite codes and joins (docs/CONTRACTS.md §1, §2, §4.1, §6 bumps).
internal val groupScenarios: List<ContractScenario> = listOf(
    ContractScenario("group.create") { harness ->
        val alice = harness.user("Alice")
        val name = Unique.name("Groupe")
        val summary = alice.groups.createGroup("  $name  ")
        Verify.equal(summary.group.name, name, "created group name (trimmed)")
        Verify.equal(summary.myRole, MemberRole.ADMIN, "creator role")
        Verify.equal(summary.group.createdBy, alice.id, "createdBy")
        Verify.that(summary.group.lastActivityAt >= summary.group.createdAt, "lastActivityAt ≥ createdAt")

        val listed = Verify.unwrap(alice.summary(summary.id), "new group in myGroups")
        Verify.equal(listed.myRole, MemberRole.ADMIN, "role in myGroups")
        Verify.equal(listed.group.name, name, "name in myGroups")

        val members = alice.groups.members(summary.id)
        Verify.equal(members.size, 1, "member count of a new group")
        Verify.equal(members.firstOrNull()?.user, UserProfile(alice.id, alice.displayName), "creator profile")
        Verify.equal(members.firstOrNull()?.role, MemberRole.ADMIN, "creator is admin")
        Verify.equal(members.firstOrNull()?.groupId, summary.id, "membership groupId")

        val code = alice.groups.inviteCode(summary.id)
        Verify.that(isWellFormedCode(code), "invite code ${code.value} must be 8 chars of the invite alphabet")
        val other = alice.groups.createGroup(Unique.name("Groupe"))
        val otherCode = alice.groups.inviteCode(other.id)
        Verify.that(otherCode != code, "each group has its own invite code")
    },

    ContractScenario("group.createValidation") { harness ->
        val alice = harness.user("Alice")
        for (invalid in listOf("", "   ", Fixed.text(61), "x\u0000y")) {
            Verify.fails(AppError.InvalidName, "group name ${debugDescription(invalid)}") {
                alice.groups.createGroup(invalid)
            }
        }
        val none = alice.groups.myGroups()
        Verify.that(none.isEmpty(), "failed creations must not create groups, got $none")
        val longest = Fixed.text(60)
        val created = alice.groups.createGroup(longest)
        Verify.equal(created.group.name, longest, "60-character group name accepted")
    },

    ContractScenario("group.joinByCode") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup()
        val result = bob.groups.join(group.code)
        Verify.equal(result, JoinResult(group.id, group.name, alreadyMember = false), "join result")
        val summary = Verify.unwrap(bob.summary(group.id), "joined group in myGroups")
        Verify.equal(summary.myRole, MemberRole.MEMBER, "role of a new member")
        Verify.equal(summary.group.name, group.name, "group name seen by the new member")
        Verify.equal(summary.group.createdBy, alice.id, "createdBy seen by the new member")

        val members = alice.groups.members(group.id)
        Verify.equal(members.map { it.user.id }, listOf(alice.id, bob.id), "members (admin first)")
        Verify.equal(members.map { it.role }, listOf(MemberRole.ADMIN, MemberRole.MEMBER), "member roles")
        Verify.that(members[1].joinedAt >= members[0].joinedAt, "joinedAt of the new member")
        val seenByBob = bob.groups.members(group.id)
        Verify.equal(seenByBob, members, "every member sees the same member list")
    },

    ContractScenario("group.joinNormalizesCode") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val carol = harness.user("Carol")
        val group = alice.makeGroup()
        val dashed = " ${group.code.formatted.lowercase()} "
        val parsed = Verify.unwrap(InviteCode.parse(dashed), "InviteCode.parse(\"$dashed\")")
        Verify.equal(parsed, group.code, "normalized dashed input")
        val bobResult = bob.groups.join(parsed)
        Verify.equal(bobResult.groupId, group.id, "join with a lowercased dashed code")
        Verify.that(!bobResult.alreadyMember, "bob is a new member")

        val spaced = "${group.code.value.take(4).lowercase()} ${group.code.value.takeLast(4)}"
        val carolCode = Verify.unwrap(InviteCode.parse(spaced), "InviteCode.parse(\"$spaced\")")
        val carolResult = carol.groups.join(carolCode)
        Verify.equal(carolResult.groupId, group.id, "join with a spaced mixed-case code")
    },

    ContractScenario("group.joinAlreadyMember") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        val adminAgain = alice.groups.join(group.code)
        Verify.equal(
            adminAgain, JoinResult(group.id, group.name, alreadyMember = true), "the admin joining their own group",
        )
        val bobAgain = bob.groups.join(group.code)
        Verify.equal(bobAgain, JoinResult(group.id, group.name, alreadyMember = true), "joining twice")
        val aliceRole = alice.role(group.id)
        Verify.equal(aliceRole, MemberRole.ADMIN, "role unchanged by joining again")
        val members = alice.memberIds(group.id)
        Verify.equal(members, listOf(alice.id, bob.id), "no duplicate membership")
    },

    ContractScenario("group.joinInvalidCode") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup()
        Verify.fails(AppError.InvalidCode, "join with an unknown code") { bob.groups.join(Unique.inviteCode()) }
        val none = bob.groups.myGroups()
        Verify.that(none.isEmpty(), "an invalid code joins nothing, got $none")
        val result = bob.groups.join(group.code)
        Verify.that(!result.alreadyMember && result.groupId == group.id, "a valid code still works after a failure")
    },

    ContractScenario("group.inviteCodeAdminOnly") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val eve = harness.user("Eve")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        val code = alice.groups.inviteCode(group.id)
        Verify.equal(code, group.code, "the invite code is stable")
        Verify.fails(AppError.Forbidden, "a member reads the invite code") { bob.groups.inviteCode(group.id) }
        Verify.fails(AppError.Forbidden, "a non-member reads the invite code") { eve.groups.inviteCode(group.id) }
        Verify.fails(AppError.Forbidden, "invite code of an unknown group") {
            alice.groups.inviteCode(UUID.randomUUID())
        }
        alice.groups.setRole(group.id, bob.id, MemberRole.ADMIN)
        val promotedView = bob.groups.inviteCode(group.id)
        Verify.equal(promotedView, code, "a promoted admin reads the invite code")
    },

    ContractScenario("group.regenerateInviteCode") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val eve = harness.user("Eve")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        Verify.fails(AppError.Forbidden, "a member regenerates the code") { bob.groups.regenerateInviteCode(group.id) }
        Verify.fails(AppError.Forbidden, "a non-member regenerates the code") {
            eve.groups.regenerateInviteCode(group.id)
        }
        val unchanged = alice.groups.inviteCode(group.id)
        Verify.equal(unchanged, group.code, "refused regenerations keep the code")

        val fresh = alice.groups.regenerateInviteCode(group.id)
        Verify.that(fresh != group.code, "regenerated code must differ from the old one")
        Verify.that(isWellFormedCode(fresh), "regenerated code ${fresh.value} must be well formed")
        val current = alice.groups.inviteCode(group.id)
        Verify.equal(current, fresh, "inviteCode returns the regenerated code")
        Verify.fails(AppError.InvalidCode, "the old code stops working") { eve.groups.join(group.code) }
        val joined = eve.groups.join(fresh)
        Verify.equal(joined.groupId, group.id, "the new code works")
    },

    ContractScenario("group.rename") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val eve = harness.user("Eve")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        val newName = Unique.name("Renommé")
        val renamed = alice.groups.rename(group.id, "  $newName  ")
        Verify.equal(renamed.id, group.id, "renamed group id")
        Verify.equal(renamed.name, newName, "renamed group name (trimmed)")
        Verify.equal(renamed.createdBy, alice.id, "createdBy kept")
        val seenByBob = Verify.unwrap(bob.summary(group.id), "group in bob's list")
        Verify.equal(seenByBob.group.name, newName, "members see the new name")

        for (invalid in listOf("", "   ", Fixed.text(61))) {
            Verify.fails(AppError.InvalidName, "rename to ${invalid.length} characters") {
                alice.groups.rename(group.id, invalid)
            }
        }
        Verify.fails(AppError.Forbidden, "a member renames") { bob.groups.rename(group.id, Unique.name("Pirate")) }
        // Lead decision: existing group + non-admin (incl. non-member) → forbidden; unknown group → not found.
        Verify.fails(AppError.Forbidden, "a non-member renames") { eve.groups.rename(group.id, Unique.name("Pirate")) }
        Verify.fails(AppError.NotFound, "rename an unknown group") {
            alice.groups.rename(UUID.randomUUID(), Unique.name("Fantôme"))
        }
        val final = Verify.unwrap(alice.summary(group.id), "group in alice's list")
        Verify.equal(final.group.name, newName, "refused renames keep the name")
    },

    ContractScenario("group.delete") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val eve = harness.user("Eve")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        val task = bob.makeTask(group.id, assignees = listOf(bob))
        Verify.fails(AppError.Forbidden, "a member deletes the group") { bob.groups.deleteGroup(group.id) }
        Verify.fails(AppError.Forbidden, "a non-member deletes the group") { eve.groups.deleteGroup(group.id) }
        Verify.fails(AppError.NotFound, "delete an unknown group") { alice.groups.deleteGroup(UUID.randomUUID()) }
        val stillThere = bob.tasks.task(task.id)
        Verify.equal(stillThere.id, task.id, "refused deletions keep the group")

        Verify.step("admin deletes the group") { alice.groups.deleteGroup(group.id) }
        val aliceGroups = alice.groups.myGroups()
        Verify.that(aliceGroups.none { it.id == group.id }, "deleted group gone for the admin")
        val bobGroups = bob.groups.myGroups()
        Verify.that(bobGroups.none { it.id == group.id }, "deleted group gone for members")
        Verify.fails(AppError.NotFound, "tasks of a deleted group") { bob.tasks.task(task.id) }
        val bobTasks = bob.tasks.myTasks(includeDone = true)
        Verify.that(bobTasks.none { it.id == task.id }, "myTasks drops tasks of a deleted group")
        Verify.hidden("members of a deleted group") { alice.groups.members(group.id) }
        Verify.hidden("tasks of a deleted group") { alice.tasks.tasks(group.id, includeOldDone = true) }
        Verify.fails(AppError.InvalidCode, "code of a deleted group") { eve.groups.join(group.code) }
        Verify.fails(AppError.NotFound, "delete an already deleted group") { alice.groups.deleteGroup(group.id) }
    },

    ContractScenario("group.myGroupsSortedByActivity") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val first = alice.makeGroup("Un")
        val second = alice.makeGroup("Deux")
        val third = alice.makeGroup("Trois")
        alice.expectGroupOrder(listOf(third, second, first), "after creation")
        alice.makeTask(first.id)
        alice.expectGroupOrder(listOf(first, third, second), "after a task in the first group")
        alice.groups.rename(second.id, Unique.name("Deux"))
        alice.expectGroupOrder(listOf(second, first, third), "after renaming the second group")
        bob.join(third)
        alice.expectGroupOrder(listOf(third, second, first), "after someone joined the third group")
        val bobGroups = bob.groups.myGroups()
        Verify.equal(bobGroups.map { it.id }, listOf(third.id), "bob only sees the group he joined")
    },

    ContractScenario("group.activityBumps") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val carol = harness.user("Carol")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        var last = alice.lastActivity(group.id)

        val task = bob.makeTask(group.id, assignees = listOf(bob))
        last = alice.checkBumped(group.id, last, "create_task")
        bob.tasks.update(task.id, TaskDraft(title = "Modifiée", assigneeIds = setOf(bob.id, alice.id)))
        last = alice.checkBumped(group.id, last, "update_task")
        bob.tasks.setStatus(task.id, TaskStatus.DONE)
        last = alice.checkBumped(group.id, last, "set_task_status")
        bob.tasks.delete(task.id)
        last = alice.checkBumped(group.id, last, "delete_task")
        carol.join(group)
        last = alice.checkBumped(group.id, last, "join_group_by_code")
        alice.groups.setRole(group.id, carol.id, MemberRole.ADMIN)
        last = alice.checkBumped(group.id, last, "set_member_role")
        alice.groups.removeMember(group.id, carol.id)
        last = alice.checkBumped(group.id, last, "remove_member")
        bob.groups.leave(group.id)
        last = alice.checkBumped(group.id, last, "leave_group")
        alice.groups.rename(group.id, Unique.name("Groupe"))
        alice.checkBumped(group.id, last, "rename_group")
    },

    ContractScenario("group.nonMemberSeesNothing") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val eve = harness.user("Eve")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        val task = bob.makeTask(group.id, assignees = listOf(bob))
        val eveGroups = eve.groups.myGroups()
        Verify.that(eveGroups.none { it.id == group.id }, "a non-member does not list the group")
        Verify.hidden("members for a non-member") { eve.groups.members(group.id) }
        Verify.hidden("tasks for a non-member") { eve.tasks.tasks(group.id, includeOldDone = false) }
        Verify.hidden("all tasks for a non-member") { eve.tasks.tasks(group.id, includeOldDone = true) }
        Verify.fails(AppError.NotFound, "one task for a non-member") { eve.tasks.task(task.id) }
        val eveTasks = eve.tasks.myTasks(includeDone = true)
        Verify.that(eveTasks.isEmpty(), "a non-member has no tasks, got $eveTasks")
    },
)

/** Checks the relative order of [expected] in `myGroups()` and that the whole list is sorted by activity. */
internal suspend fun ContractUser.expectGroupOrder(expected: List<GroupFixture>, context: String) {
    val list = groups.myGroups()
    val wanted = expected.map { it.id }.toSet()
    Verify.equal(list.map { it.id }.filter { it in wanted }, expected.map { it.id }, "myGroups order $context")
    for ((newer, older) in list.zipWithNext()) {
        Verify.that(
            newer.group.lastActivityAt >= older.group.lastActivityAt,
            "myGroups must be sorted by lastActivityAt desc $context",
        )
    }
}
