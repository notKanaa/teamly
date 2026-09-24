package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.RealtimeEvent
import java.util.UUID

// Push topic (docs/CONTRACTS.md §4.1, §7) and account deletion (§2).
internal val pushScenarios: List<ContractScenario> = listOf(
    ContractScenario("push.topicLifecycle") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val initial = alice.push.currentTopic()
        Verify.equal(initial, null, "no topic before enabling")

        val topic = alice.push.enable()
        Verify.that(isPushTopic(topic), "topic $topic must be equipe- + 24 [a-z0-9]")
        val again = alice.push.enable()
        Verify.equal(again, topic, "enable returns the existing topic")
        val current = alice.push.currentTopic()
        Verify.equal(current, topic, "currentTopic after enabling")

        val bobTopic = bob.push.enable()
        Verify.that(bobTopic != topic, "each user has their own topic")

        alice.push.disable()
        val disabled = alice.push.currentTopic()
        Verify.equal(disabled, null, "no topic after disabling")
        Verify.step("disable twice") { alice.push.disable() }
        val bobCurrent = bob.push.currentTopic()
        Verify.equal(bobCurrent, bobTopic, "disabling does not affect other users")

        val renewed = alice.push.enable()
        Verify.that(isPushTopic(renewed), "re-enabled topic $renewed is well formed")
    },
)

internal val accountScenarios: List<ContractScenario> = listOf(
    ContractScenario("account.deleteAccount") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val carol = harness.user("Carol")
        val dan = harness.user("Dan")
        val erin = harness.user("Erin")

        // Alice is the only admin of `shared` (Bob joined before Carol), alone in `solo`, co-admin of `coAdmin` with
        // Dan, and a plain member of Erin's group.
        val shared = alice.makeGroup("Partage", joinedBy = listOf(bob, carol))
        val solo = alice.makeGroup("Solo")
        val coAdmin = alice.makeGroup("CoAdmin", joinedBy = listOf(dan, erin))
        alice.groups.setRole(coAdmin.id, dan.id, MemberRole.ADMIN)
        val erinGroup = erin.makeGroup("Erin", joinedBy = listOf(alice))

        val byAlice = alice.makeTask(shared.id, assignees = listOf(bob, alice))
        val byBob = bob.makeTask(shared.id, assignees = listOf(alice))
        alice.push.enable()
        bob.subscribe(listOf(shared.id)).use { probe ->
            val mark = probe.mark()

            Verify.step("delete_my_account") { alice.auth.deleteAccount() }

            val current = alice.auth.currentUser()
            Verify.that(current == null, "signed out after deleting the account")
            Verify.fails(AppError.NotAuthenticated, "myGroups after deleting the account") { alice.groups.myGroups() }
            Verify.fails(AppError.InvalidCredentials, "sign in to a deleted account") {
                alice.auth.signIn(alice.email, alice.password)
            }

            // Only admin with other members → the oldest other member becomes admin.
            val sharedMembers = bob.groups.members(shared.id)
            Verify.equal(sharedMembers.map { it.user.id }, listOf(bob.id, carol.id), "members of the shared group")
            Verify.equal(
                sharedMembers.map { it.role }, listOf(MemberRole.ADMIN, MemberRole.MEMBER),
                "the oldest other member was promoted",
            )
            val sharedSummary = Verify.unwrap(bob.summary(shared.id), "shared group for bob")
            Verify.equal(sharedSummary.myRole, MemberRole.ADMIN, "bob's role")
            Verify.equal(sharedSummary.group.createdBy, null, "groups.createdBy becomes NULL")
            probe.waitFor("membershipsChanged for the promoted member", after = mark) {
                it == RealtimeEvent.MembershipsChanged
            }

            // Only member → the group is deleted.
            Verify.fails(AppError.InvalidCode, "the code of the deleted solo group") { carol.groups.join(solo.code) }
            // Another admin exists → nobody is promoted.
            val coAdminMembers = dan.groups.members(coAdmin.id)
            Verify.equal(coAdminMembers.map { it.user.id }, listOf(dan.id, erin.id), "members of the co-admin group")
            Verify.equal(
                coAdminMembers.map { it.role }, listOf(MemberRole.ADMIN, MemberRole.MEMBER), "no extra promotion",
            )
            // Plain member → just removed.
            val erinMembers = erin.memberIds(erinGroup.id)
            Verify.equal(erinMembers, listOf(erin.id), "members of the group where alice was a member")

            // created_by / assigned_by become NULL; alice's own assignments disappear.
            val aliceTask = bob.tasks.task(byAlice.id)
            Verify.equal(aliceTask.createdBy, null, "tasks.createdBy becomes NULL")
            Verify.equal(aliceTask.updatedAt, byAlice.updatedAt, "updatedAt kept (no editable field changed)")
            Verify.equal(aliceTask.assigneeIds, listOf(bob.id), "the deleted user's assignments are gone")
            val bobTask = bob.tasks.task(byBob.id)
            Verify.equal(bobTask.createdBy, bob.id, "other tasks keep their creator")
            Verify.equal(bobTask.assigneeIds, emptyList<UUID>(), "assignments of the deleted user are gone")
            val events = bob.tasks.assignments(Fixed.longAgo)
            val event = Verify.unwrap(events.firstOrNull { it.taskId == byAlice.id }, "bob's assignment by alice")
            Verify.equal(event.assignedBy, null, "assignedBy becomes NULL and is still reported")
        }
    },
)
