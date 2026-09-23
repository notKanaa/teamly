import Foundation
import TeamTasksCore

// Push topic (docs/CONTRACTS.md §4.1, §7) and account deletion (§2).
extension ContractScenarios {
    static let pushScenarios: [ContractScenario] = [
        ContractScenario("push.topicLifecycle") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let initial = try await alice.push.currentTopic()
            try Verify.equal(initial, nil, "no topic before enabling")

            let topic = try await alice.push.enable()
            try Verify.that(isPushTopic(topic), "topic \(topic) must be equipe- + 24 [a-z0-9]")
            let again = try await alice.push.enable()
            try Verify.equal(again, topic, "enable returns the existing topic")
            let current = try await alice.push.currentTopic()
            try Verify.equal(current, topic, "currentTopic after enabling")

            let bobTopic = try await bob.push.enable()
            try Verify.that(bobTopic != topic, "each user has their own topic")

            try await alice.push.disable()
            let disabled = try await alice.push.currentTopic()
            try Verify.equal(disabled, nil, "no topic after disabling")
            try await Verify.step("disable twice") { try await alice.push.disable() }
            let bobCurrent = try await bob.push.currentTopic()
            try Verify.equal(bobCurrent, bobTopic, "disabling does not affect other users")

            let renewed = try await alice.push.enable()
            try Verify.that(isPushTopic(renewed), "re-enabled topic \(renewed) is well formed")
        },
    ]

    static let accountScenarios: [ContractScenario] = [
        ContractScenario("account.deleteAccount") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let erin = try await harness.user("Erin")

            // Alice is the only admin of `shared` (Bob joined before Carol), alone in `solo`,
            // co-admin of `coAdmin` with Dan, and a plain member of Erin's group.
            let shared = try await alice.makeGroup("Partage", joinedBy: [bob, carol])
            let solo = try await alice.makeGroup("Solo")
            let coAdmin = try await alice.makeGroup("CoAdmin", joinedBy: [dan, erin])
            try await alice.groups.setRole(groupId: coAdmin.id, userId: dan.id, role: .admin)
            let erinGroup = try await erin.makeGroup("Erin", joinedBy: [alice])

            let byAlice = try await alice.makeTask(in: shared.id, assignees: [bob, alice])
            let byBob = try await bob.makeTask(in: shared.id, assignees: [alice])
            _ = try await alice.push.enable()
            let probe = try await bob.subscribe(groups: [shared.id])
            defer { probe.stop() }
            let mark = probe.mark()

            try await Verify.step("delete_my_account") { try await alice.auth.deleteAccount() }

            let current = await alice.auth.currentUser()
            try Verify.that(current == nil, "signed out after deleting the account")
            try await Verify.fails(with: .notAuthenticated, "myGroups after deleting the account") {
                try await alice.groups.myGroups()
            }
            try await Verify.fails(with: .invalidCredentials, "sign in to a deleted account") {
                try await alice.auth.signIn(email: alice.email, password: alice.password)
            }

            // Only admin with other members → the oldest other member becomes admin.
            let sharedMembers = try await bob.groups.members(groupId: shared.id)
            try Verify.equal(sharedMembers.map(\.user.id), [bob.id, carol.id], "members of the shared group")
            try Verify.equal(sharedMembers.map(\.role), [.admin, .member], "the oldest other member was promoted")
            let sharedSummary = try Verify.unwrap(try await bob.summary(of: shared.id), "shared group for bob")
            try Verify.equal(sharedSummary.myRole, .admin, "bob's role")
            try Verify.equal(sharedSummary.group.createdBy, nil, "groups.createdBy becomes NULL")
            try await probe.waitFor("membershipsChanged for the promoted member", after: mark) { $0 == .membershipsChanged }

            // Only member → the group is deleted.
            try await Verify.fails(with: .invalidCode, "the code of the deleted solo group") {
                try await carol.groups.join(code: solo.code)
            }
            // Another admin exists → nobody is promoted.
            let coAdminMembers = try await dan.groups.members(groupId: coAdmin.id)
            try Verify.equal(coAdminMembers.map(\.user.id), [dan.id, erin.id], "members of the co-admin group")
            try Verify.equal(coAdminMembers.map(\.role), [.admin, .member], "no extra promotion")
            // Plain member → just removed.
            let erinMembers = try await erin.memberIDs(of: erinGroup.id)
            try Verify.equal(erinMembers, [erin.id], "members of the group where alice was a member")

            // created_by / assigned_by become NULL; alice's own assignments disappear.
            let aliceTask = try await bob.tasks.task(id: byAlice.id)
            try Verify.equal(aliceTask.createdBy, nil, "tasks.createdBy becomes NULL")
            try Verify.equal(aliceTask.assigneeIds, [bob.id], "the deleted user's assignments are gone")
            let bobTask = try await bob.tasks.task(id: byBob.id)
            try Verify.equal(bobTask.createdBy, bob.id, "other tasks keep their creator")
            try Verify.equal(bobTask.assigneeIds, [], "assignments of the deleted user are gone")
            let events = try await bob.tasks.assignments(since: Fixed.longAgo)
            let event = try Verify.unwrap(events.first { $0.taskId == byAlice.id }, "bob's assignment by alice")
            try Verify.equal(event.assignedBy, nil, "assignedBy becomes NULL and is still reported")
        },
    ]
}
