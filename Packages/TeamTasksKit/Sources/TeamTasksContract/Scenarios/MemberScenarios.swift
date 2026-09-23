import Foundation
import TeamTasksCore

// Membership rules (docs/CONTRACTS.md §2): roles, last admin, removal, leaving.
extension ContractScenarios {
    static let memberScenarios: [ContractScenario] = [
        ContractScenario("members.sortedAdminsFirstThenName") { harness in
            let delta = try await harness.user("Delta")
            let alpha = try await harness.user("Alpha")
            let charlie = try await harness.user("Charlie")
            let bravo = try await harness.user("Bravo")
            let group = try await delta.makeGroup(joinedBy: [alpha, charlie, bravo])
            let initial = try await bravo.memberIDs(of: group.id)
            try Verify.equal(initial, [delta, alpha, bravo, charlie].map(\.id), "admins first, then by display name")

            try await delta.groups.setRole(groupId: group.id, userId: charlie.id, role: .admin)
            let promoted = try await alpha.groups.members(groupId: group.id)
            try Verify.equal(promoted.map(\.user.id), [charlie, delta, alpha, bravo].map(\.id), "order after a promotion")
            try Verify.equal(promoted.map(\.role), [.admin, .admin, .member, .member], "roles after a promotion")
        },

        ContractScenario("members.setRole") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            try await Verify.fails(with: .forbidden, "a member changes a role") {
                try await bob.groups.setRole(groupId: group.id, userId: carol.id, role: .admin)
            }
            try await Verify.fails(with: .forbidden, "a non-member changes a role") {
                try await eve.groups.setRole(groupId: group.id, userId: carol.id, role: .admin)
            }
            try await Verify.fails(with: .notMember, "role of a non-member") {
                try await alice.groups.setRole(groupId: group.id, userId: eve.id, role: .admin)
            }
            try await Verify.fails(with: .lastAdmin, "the only admin demotes themselves") {
                try await alice.groups.setRole(groupId: group.id, userId: alice.id, role: .member)
            }

            try await alice.groups.setRole(groupId: group.id, userId: bob.id, role: .admin)
            let bobRole = try await bob.role(in: group.id)
            try Verify.equal(bobRole, .admin, "promoted member's role")
            try await Verify.step("an admin demotes themselves while another admin exists") {
                try await alice.groups.setRole(groupId: group.id, userId: alice.id, role: .member)
            }
            let aliceRole = try await alice.role(in: group.id)
            try Verify.equal(aliceRole, .member, "self-demoted admin's role")
            try await Verify.fails(with: .forbidden, "a demoted admin changes a role") {
                try await alice.groups.setRole(groupId: group.id, userId: carol.id, role: .admin)
            }
            try await Verify.fails(with: .lastAdmin, "the new last admin demotes themselves") {
                try await bob.groups.setRole(groupId: group.id, userId: bob.id, role: .member)
            }
            try await Verify.step("an admin promotes then demotes another admin") {
                try await bob.groups.setRole(groupId: group.id, userId: alice.id, role: .admin)
                try await bob.groups.setRole(groupId: group.id, userId: alice.id, role: .member)
            }
            let members = try await carol.groups.members(groupId: group.id)
            try Verify.equal(members.map(\.user.id), [bob, alice, carol].map(\.id), "final member order")
            try Verify.equal(members.map(\.role), [.admin, .member, .member], "final roles")
        },

        // SQL set_member_role returns before any write when the role does not change.
        ContractScenario("members.noOpRoleChange") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let probe = try await bob.subscribe(groups: [group.id])
            defer { probe.stop() }
            let before = try await alice.lastActivity(of: group.id)

            let mark = probe.mark()
            try await Verify.step("set unchanged roles") {
                try await alice.groups.setRole(groupId: group.id, userId: bob.id, role: .member)
                try await alice.groups.setRole(groupId: group.id, userId: alice.id, role: .admin) // the only admin
            }
            try await probe.expectNone(since: mark, "no signal for an unchanged role") {
                $0 == .membershipsChanged || $0 == .groupActivity(groupId: group.id)
            }
            let after = try await alice.lastActivity(of: group.id)
            try Verify.equal(after, before, "an unchanged role keeps lastActivityAt")
            let members = try await bob.groups.members(groupId: group.id)
            try Verify.equal(members.map(\.role), [.admin, .member], "roles unchanged")
        },

        ContractScenario("members.remove") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let byBob = try await bob.makeTask(in: group.id, assignees: [bob, carol])
            let byAlice = try await alice.makeTask(in: group.id, assignees: [bob])

            try await Verify.fails(with: .forbidden, "a member removes someone") {
                try await bob.groups.removeMember(groupId: group.id, userId: carol.id)
            }
            try await Verify.fails(with: .forbidden, "a non-member removes someone") {
                try await eve.groups.removeMember(groupId: group.id, userId: carol.id)
            }
            try await Verify.fails(with: .cannotRemoveSelf, "an admin removes themselves") {
                try await alice.groups.removeMember(groupId: group.id, userId: alice.id)
            }
            try await Verify.fails(with: .notMember, "remove a non-member") {
                try await alice.groups.removeMember(groupId: group.id, userId: eve.id)
            }

            try await Verify.step("admin removes bob") {
                try await alice.groups.removeMember(groupId: group.id, userId: bob.id)
            }
            let remaining = try await alice.memberIDs(of: group.id)
            try Verify.equal(remaining, [alice.id, carol.id], "members after removal")
            let bobGroups = try await bob.groups.myGroups()
            try Verify.that(!bobGroups.contains { $0.id == group.id }, "a removed member no longer lists the group")
            let kept = try await alice.tasks.task(id: byBob.id)
            try Verify.equal(kept.createdBy, bob.id, "tasks created by a removed member stay (createdBy kept)")
            try Verify.equal(kept.assigneeIds, [carol.id], "the removed member's assignments are deleted")
            let other = try await alice.tasks.task(id: byAlice.id)
            try Verify.equal(other.assigneeIds, [], "the removed member's assignments are deleted everywhere")
            try await Verify.fails(with: .notFound, "a removed member reads a task of the group") {
                try await bob.tasks.task(id: byBob.id)
            }

            try await alice.groups.setRole(groupId: group.id, userId: carol.id, role: .admin)
            try await Verify.step("an admin removes another admin") {
                try await alice.groups.removeMember(groupId: group.id, userId: carol.id)
            }
            let alone = try await alice.memberIDs(of: group.id)
            try Verify.equal(alone, [alice.id], "members after removing an admin")
            try await Verify.fails(with: .notMember, "remove someone twice") {
                try await alice.groups.removeMember(groupId: group.id, userId: carol.id)
            }
        },

        ContractScenario("members.leave") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let task = try await bob.makeTask(in: group.id, assignees: [bob, alice])

            try await Verify.fails(with: .lastAdmin, "the only admin leaves while members remain") {
                try await alice.groups.leave(groupId: group.id)
            }
            try await Verify.step("a member leaves") { try await bob.groups.leave(groupId: group.id) }
            let bobGroups = try await bob.groups.myGroups()
            try Verify.that(!bobGroups.contains { $0.id == group.id }, "the group is gone from the leaver's list")
            let members = try await alice.memberIDs(of: group.id)
            try Verify.equal(members, [alice.id, carol.id], "members after leaving")
            let kept = try await alice.tasks.task(id: task.id)
            try Verify.equal(kept.createdBy, bob.id, "tasks of a leaver stay")
            try Verify.equal(kept.assigneeIds, [alice.id], "the leaver's assignments are deleted")

            try await Verify.fails(with: .notMember, "leave twice") { try await bob.groups.leave(groupId: group.id) }
            try await Verify.fails(with: .notMember, "a non-member leaves") { try await eve.groups.leave(groupId: group.id) }
            try await Verify.fails(with: .notMember, "leave an unknown group") { try await eve.groups.leave(groupId: UUID()) }

            try await alice.groups.setRole(groupId: group.id, userId: carol.id, role: .admin)
            try await Verify.step("an admin leaves once another admin exists") {
                try await alice.groups.leave(groupId: group.id)
            }
            let last = try await carol.groups.members(groupId: group.id)
            try Verify.equal(last.map(\.user.id), [carol.id], "members after the admin left")
            try Verify.equal(last.map(\.role), [.admin], "the remaining admin")
        },

        ContractScenario("members.lastMemberLeavingDeletesGroup") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup()
            let task = try await alice.makeTask(in: group.id, assignees: [alice])
            try await Verify.step("the last member leaves") { try await alice.groups.leave(groupId: group.id) }
            let groups = try await alice.groups.myGroups()
            try Verify.that(!groups.contains { $0.id == group.id }, "the group is gone")
            try await Verify.fails(with: .invalidCode, "the code of a group deleted by its last member") {
                try await bob.groups.join(code: group.code)
            }
            try await Verify.fails(with: .notFound, "a task of the deleted group") {
                try await alice.tasks.task(id: task.id)
            }
        },
    ]
}
