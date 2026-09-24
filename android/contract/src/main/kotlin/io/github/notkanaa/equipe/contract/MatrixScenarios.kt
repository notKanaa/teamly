package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.uuidString
import java.util.UUID

/** The five columns of the permission matrix (docs/CONTRACTS.md §2) around one task. */
internal class MatrixFixture(
    val admin: ContractUser,
    val creator: ContractUser,
    val assignee: ContractUser,
    val other: ContractUser,
    val outsider: ContractUser,
    val group: GroupFixture,
    /** Created by [creator], assigned to [assignee]. */
    val task: TaskItem,
) {
    val members: List<ContractUser> get() = listOf(admin, creator, assignee, other)

    companion object {
        suspend fun make(harness: ContractHarness): MatrixFixture {
            val admin = harness.user("Admin")
            val creator = harness.user("Createur")
            val assignee = harness.user("Assigne")
            val other = harness.user("Membre")
            val outsider = harness.user("Externe")
            val group = admin.makeGroup(joinedBy = listOf(creator, assignee, other))
            val task = creator.makeTask(group.id, "Matrice", assignees = listOf(assignee))
            return MatrixFixture(admin, creator, assignee, other, outsider, group, task)
        }
    }
}

// The §2 matrix, one scenario per row, plus per-group rights and the "creator who left" rule.
internal val matrixScenarios: List<ContractScenario> = listOf(
    ContractScenario("matrix.seeGroupMembersAndTasks") { harness ->
        val fixture = MatrixFixture.make(harness)
        for (user in fixture.members) {
            val summary = user.summary(fixture.group.id)
            Verify.that(summary != null, "${user.displayName} lists the group")
            val members = user.memberIds(fixture.group.id)
            Verify.equal(members.size, 4, "${user.displayName} sees every member")
            val tasks = user.tasks.tasks(fixture.group.id, includeOldDone = false)
            Verify.equal(tasks, listOf(fixture.task), "${user.displayName} sees the group's tasks")
            val task = user.tasks.task(fixture.task.id)
            Verify.equal(task, fixture.task, "${user.displayName} reads the task")
        }
        val outsiderGroups = fixture.outsider.groups.myGroups()
        Verify.that(outsiderGroups.isEmpty(), "a non-member lists no group")
        Verify.hidden("members for a non-member") { fixture.outsider.groups.members(fixture.group.id) }
        Verify.hidden("tasks for a non-member") {
            fixture.outsider.tasks.tasks(fixture.group.id, includeOldDone = true)
        }
        Verify.fails(AppError.NotFound, "a task for a non-member") { fixture.outsider.tasks.task(fixture.task.id) }
    },

    ContractScenario("matrix.createTask") { harness ->
        val fixture = MatrixFixture.make(harness)
        for (user in fixture.members) {
            val draft = TaskDraft(title = Unique.name("Nouvelle"), assigneeIds = setOf(user.id, fixture.admin.id))
            val created = Verify.step("${user.displayName} creates a task") {
                user.tasks.create(fixture.group.id, draft)
            }
            Verify.equal(created.createdBy, user.id, "createdBy of a task created by ${user.displayName}")
            val expected = setOf(user.id, fixture.admin.id).sortedBy { it.uuidString }
            Verify.equal(created.assigneeIds, expected, "assignees incl. self")
        }
        Verify.fails(AppError.Forbidden, "a non-member creates a task") {
            fixture.outsider.tasks.create(fixture.group.id, TaskDraft(title = "Intrusion"))
        }
        Verify.fails(AppError.Forbidden, "create a task in an unknown group") {
            fixture.admin.tasks.create(UUID.randomUUID(), TaskDraft(title = "Fantôme"))
        }
        val tasks = fixture.admin.tasks.tasks(fixture.group.id, includeOldDone = true)
        Verify.equal(tasks.size, 5, "four new tasks plus the fixture task")
    },

    ContractScenario("matrix.editTask") { harness ->
        val fixture = MatrixFixture.make(harness)
        val draft = TaskDraft(title = Unique.name("Modif"), assigneeIds = setOf(fixture.other.id))
        Verify.fails(AppError.Forbidden, "the assignee edits the task") {
            fixture.assignee.tasks.update(fixture.task.id, draft)
        }
        Verify.fails(AppError.Forbidden, "another member edits the task") {
            fixture.other.tasks.update(fixture.task.id, draft)
        }
        Verify.fails(AppError.NotFound, "a non-member edits the task") {
            fixture.outsider.tasks.update(fixture.task.id, draft)
        }
        val unchanged = fixture.admin.tasks.task(fixture.task.id)
        Verify.equal(unchanged, fixture.task, "refused edits change nothing")

        val byCreator = Verify.step("the creator edits") { fixture.creator.tasks.update(fixture.task.id, draft) }
        Verify.equal(byCreator.title, draft.title, "title edited by the creator")
        Verify.equal(byCreator.assigneeIds, listOf(fixture.other.id), "assignees edited by the creator")
        val adminDraft = TaskDraft(
            title = Unique.name("Admin"), priority = TaskPriority.HIGH, assigneeIds = setOf(fixture.assignee.id),
        )
        val byAdmin = Verify.step("the admin edits") { fixture.admin.tasks.update(fixture.task.id, adminDraft) }
        Verify.equal(byAdmin.title, adminDraft.title, "title edited by the admin")
        Verify.equal(byAdmin.priority, TaskPriority.HIGH, "priority edited by the admin")
        Verify.equal(byAdmin.createdBy, fixture.creator.id, "createdBy unchanged by an admin edit")
    },

    ContractScenario("matrix.changeStatus") { harness ->
        val fixture = MatrixFixture.make(harness)
        Verify.fails(AppError.Forbidden, "another member changes the status") {
            fixture.other.tasks.setStatus(fixture.task.id, TaskStatus.IN_PROGRESS)
        }
        Verify.fails(AppError.NotFound, "a non-member changes the status") {
            fixture.outsider.tasks.setStatus(fixture.task.id, TaskStatus.IN_PROGRESS)
        }
        val byAssignee = Verify.step("the assignee changes the status") {
            fixture.assignee.tasks.setStatus(fixture.task.id, TaskStatus.IN_PROGRESS)
        }
        Verify.equal(byAssignee.status, TaskStatus.IN_PROGRESS, "status set by the assignee")
        Verify.equal(byAssignee.title, fixture.task.title, "a status change keeps the other fields")
        val byCreator = Verify.step("the creator changes the status") {
            fixture.creator.tasks.setStatus(fixture.task.id, TaskStatus.DONE)
        }
        Verify.equal(byCreator.status, TaskStatus.DONE, "status set by the creator")
        val byAdmin = Verify.step("the admin changes the status") {
            fixture.admin.tasks.setStatus(fixture.task.id, TaskStatus.TODO)
        }
        Verify.equal(byAdmin.status, TaskStatus.TODO, "status set by the admin")

        fixture.creator.reassign(byAdmin, emptyList())
        Verify.fails(AppError.Forbidden, "a former assignee changes the status") {
            fixture.assignee.tasks.setStatus(fixture.task.id, TaskStatus.DONE)
        }
    },

    ContractScenario("matrix.deleteTask") { harness ->
        val fixture = MatrixFixture.make(harness)
        val second = fixture.creator.makeTask(fixture.group.id, assignees = listOf(fixture.assignee))
        Verify.fails(AppError.Forbidden, "the assignee deletes the task") {
            fixture.assignee.tasks.delete(fixture.task.id)
        }
        Verify.fails(AppError.Forbidden, "another member deletes the task") {
            fixture.other.tasks.delete(fixture.task.id)
        }
        Verify.fails(AppError.NotFound, "a non-member deletes the task") {
            fixture.outsider.tasks.delete(fixture.task.id)
        }
        Verify.step("the creator deletes") { fixture.creator.tasks.delete(fixture.task.id) }
        Verify.step("the admin deletes") { fixture.admin.tasks.delete(second.id) }
        for (user in fixture.members) {
            Verify.fails(AppError.NotFound, "${user.displayName} reads a deleted task") {
                user.tasks.task(fixture.task.id)
            }
        }
        Verify.fails(AppError.NotFound, "delete a deleted task") { fixture.creator.tasks.delete(fixture.task.id) }
        val remaining = fixture.admin.tasks.tasks(fixture.group.id, includeOldDone = true)
        Verify.that(remaining.isEmpty(), "both tasks are gone, got $remaining")
    },

    ContractScenario("matrix.groupAdminActions") { harness ->
        val fixture = MatrixFixture.make(harness)
        val groupId = fixture.group.id
        val nonAdmins = listOf(fixture.creator, fixture.assignee, fixture.other)
        for ((index, user) in nonAdmins.withIndex()) {
            val target = nonAdmins[(index + 1) % nonAdmins.size]
            Verify.fails(AppError.Forbidden, "${user.displayName} renames") {
                user.groups.rename(groupId, Unique.name("Pirate"))
            }
            Verify.fails(AppError.Forbidden, "${user.displayName} deletes the group") {
                user.groups.deleteGroup(groupId)
            }
            Verify.fails(AppError.Forbidden, "${user.displayName} reads the invite code") {
                user.groups.inviteCode(groupId)
            }
            Verify.fails(AppError.Forbidden, "${user.displayName} regenerates the invite code") {
                user.groups.regenerateInviteCode(groupId)
            }
            Verify.fails(AppError.Forbidden, "${user.displayName} changes a role") {
                user.groups.setRole(groupId, target.id, MemberRole.ADMIN)
            }
            Verify.fails(AppError.Forbidden, "${user.displayName} removes a member") {
                user.groups.removeMember(groupId, target.id)
            }
        }
        val outsider = fixture.outsider
        Verify.fails(AppError.Forbidden, "a non-member renames") {
            outsider.groups.rename(groupId, Unique.name("Pirate"))
        }
        Verify.fails(AppError.Forbidden, "a non-member deletes the group") { outsider.groups.deleteGroup(groupId) }
        Verify.fails(AppError.Forbidden, "a non-member reads the invite code") { outsider.groups.inviteCode(groupId) }
        Verify.fails(AppError.Forbidden, "a non-member regenerates the invite code") {
            outsider.groups.regenerateInviteCode(groupId)
        }
        Verify.fails(AppError.Forbidden, "a non-member changes a role") {
            outsider.groups.setRole(groupId, fixture.other.id, MemberRole.ADMIN)
        }
        Verify.fails(AppError.Forbidden, "a non-member removes a member") {
            outsider.groups.removeMember(groupId, fixture.other.id)
        }
        val members = fixture.admin.memberIds(groupId)
        Verify.equal(members.size, 4, "refused actions change no membership")

        // Lead decision: on an unknown group these admin RPCs answer forbidden (not "not found").
        val admin = fixture.admin
        val unknown = UUID.randomUUID()
        Verify.fails(AppError.Forbidden, "regenerate the invite code of an unknown group") {
            admin.groups.regenerateInviteCode(unknown)
        }
        Verify.fails(AppError.Forbidden, "change a role in an unknown group") {
            admin.groups.setRole(unknown, fixture.other.id, MemberRole.ADMIN)
        }
        Verify.fails(AppError.Forbidden, "remove a member of an unknown group") {
            admin.groups.removeMember(unknown, fixture.other.id)
        }

        Verify.step("the admin renames, reads and regenerates the code, manages members") {
            admin.groups.rename(groupId, Unique.name("Groupe"))
            admin.groups.inviteCode(groupId)
            admin.groups.regenerateInviteCode(groupId)
            admin.groups.setRole(groupId, fixture.other.id, MemberRole.ADMIN)
            admin.groups.removeMember(groupId, fixture.other.id)
            admin.groups.deleteGroup(groupId)
        }
    },

    ContractScenario("matrix.rightsArePerGroup") { harness ->
        val alice = harness.user("Alice")
        val xavier = harness.user("Xavier")
        val aliceGroup = alice.makeGroup("Alice", joinedBy = listOf(xavier))
        val xavierGroup = xavier.makeGroup("Xavier", joinedBy = listOf(alice))
        val xavierTask = xavier.makeTask(xavierGroup.id, assignees = listOf(xavier))
        val aliceTask = alice.makeTask(aliceGroup.id, assignees = listOf(alice))
        val groupId = xavierGroup.id

        // Admin of her own group, Alice is a plain member of Xavier's group.
        Verify.fails(AppError.Forbidden, "rename another group") {
            alice.groups.rename(groupId, Unique.name("Pirate"))
        }
        Verify.fails(AppError.Forbidden, "read another group's code") { alice.groups.inviteCode(groupId) }
        Verify.fails(AppError.Forbidden, "regenerate another group's code") {
            alice.groups.regenerateInviteCode(groupId)
        }
        Verify.fails(AppError.Forbidden, "delete another group") { alice.groups.deleteGroup(groupId) }
        Verify.fails(AppError.Forbidden, "change a role in another group") {
            alice.groups.setRole(groupId, xavier.id, MemberRole.MEMBER)
        }
        Verify.fails(AppError.Forbidden, "remove a member of another group") {
            alice.groups.removeMember(groupId, xavier.id)
        }
        Verify.fails(AppError.Forbidden, "edit a task of another group") {
            alice.tasks.update(xavierTask.id, TaskDraft(title = "Pirate"))
        }
        Verify.fails(AppError.Forbidden, "change the status of a task of another group") {
            alice.tasks.setStatus(xavierTask.id, TaskStatus.DONE)
        }
        Verify.fails(AppError.Forbidden, "delete a task of another group") { alice.tasks.delete(xavierTask.id) }
        Verify.fails(AppError.Forbidden, "Xavier edits a task of Alice's group") {
            xavier.tasks.update(aliceTask.id, TaskDraft(title = "Pirate"))
        }
        val aliceRole = alice.role(groupId)
        Verify.equal(aliceRole, MemberRole.MEMBER, "Alice's role in Xavier's group")
    },

    ContractScenario("matrix.creatorWhoLeftHasNoRights") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        val task = bob.makeTask(group.id, assignees = listOf(bob))
        Verify.step("the creator edits while a member") {
            bob.tasks.update(task.id, TaskDraft(title = Unique.name("Avant")))
        }
        bob.groups.leave(group.id)

        Verify.fails(AppError.NotFound, "a creator who left reads the task") { bob.tasks.task(task.id) }
        Verify.fails(AppError.NotFound, "a creator who left edits the task") {
            bob.tasks.update(task.id, TaskDraft(title = "Pirate"))
        }
        Verify.fails(AppError.NotFound, "a creator who left changes the status") {
            bob.tasks.setStatus(task.id, TaskStatus.DONE)
        }
        Verify.fails(AppError.NotFound, "a creator who left deletes the task") { bob.tasks.delete(task.id) }
        val kept = alice.tasks.task(task.id)
        Verify.equal(kept.createdBy, bob.id, "createdBy kept after the creator left")
        Verify.equal(kept.assigneeIds, emptyList<UUID>(), "the creator's assignment was deleted")

        val rejoined = bob.join(group)
        Verify.that(!rejoined.alreadyMember, "rejoining is a new membership")
        val role = bob.role(group.id)
        Verify.equal(role, MemberRole.MEMBER, "a rejoining member is a plain member")
        val edited = Verify.step("the creator edits again once a member") {
            bob.tasks.update(task.id, TaskDraft(title = Unique.name("Après")))
        }
        Verify.equal(edited.createdBy, bob.id, "createdBy still the creator")
        Verify.step("the creator deletes again once a member") { bob.tasks.delete(task.id) }
    },
)
