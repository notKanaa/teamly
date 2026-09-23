import Foundation
import TeamTasksCore

// Groups, invite codes and joins (docs/CONTRACTS.md §1, §2, §4.1, §6 bumps).
extension ContractScenarios {
    static let groupScenarios: [ContractScenario] = [
        ContractScenario("group.create") { harness in
            let alice = try await harness.user("Alice")
            let name = Unique.name("Groupe")
            let summary = try await alice.groups.createGroup(name: "  \(name)  ")
            try Verify.equal(summary.group.name, name, "created group name (trimmed)")
            try Verify.equal(summary.myRole, .admin, "creator role")
            try Verify.equal(summary.group.createdBy, alice.id, "createdBy")
            try Verify.that(summary.group.lastActivityAt >= summary.group.createdAt, "lastActivityAt ≥ createdAt")

            let listed = try Verify.unwrap(try await alice.summary(of: summary.id), "new group in myGroups")
            try Verify.equal(listed.myRole, .admin, "role in myGroups")
            try Verify.equal(listed.group.name, name, "name in myGroups")

            let members = try await alice.groups.members(groupId: summary.id)
            try Verify.equal(members.count, 1, "member count of a new group")
            try Verify.equal(members.first?.user, UserProfile(id: alice.id, displayName: alice.displayName), "creator profile")
            try Verify.equal(members.first?.role, .admin, "creator is admin")
            try Verify.equal(members.first?.groupId, summary.id, "membership groupId")

            let code = try await alice.groups.inviteCode(groupId: summary.id)
            try Verify.that(isWellFormedCode(code), "invite code \(code.value) must be 8 chars of the invite alphabet")
            let other = try await alice.groups.createGroup(name: Unique.name("Groupe"))
            let otherCode = try await alice.groups.inviteCode(groupId: other.id)
            try Verify.that(otherCode != code, "each group has its own invite code")
        },

        ContractScenario("group.createValidation") { harness in
            let alice = try await harness.user("Alice")
            for invalid in ["", "   ", Fixed.text(61), "x\u{0}y"] {
                try await Verify.fails(with: .invalidName, "group name \(invalid.debugDescription)") {
                    try await alice.groups.createGroup(name: invalid)
                }
            }
            let none = try await alice.groups.myGroups()
            try Verify.that(none.isEmpty, "failed creations must not create groups, got \(none)")
            let longest = Fixed.text(60)
            let created = try await alice.groups.createGroup(name: longest)
            try Verify.equal(created.group.name, longest, "60-character group name accepted")
        },

        ContractScenario("group.joinByCode") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup()
            let result = try await bob.groups.join(code: group.code)
            try Verify.equal(
                result, JoinResult(groupId: group.id, groupName: group.name, alreadyMember: false), "join result"
            )
            let summary = try Verify.unwrap(try await bob.summary(of: group.id), "joined group in myGroups")
            try Verify.equal(summary.myRole, .member, "role of a new member")
            try Verify.equal(summary.group.name, group.name, "group name seen by the new member")
            try Verify.equal(summary.group.createdBy, alice.id, "createdBy seen by the new member")

            let members = try await alice.groups.members(groupId: group.id)
            try Verify.equal(members.map(\.user.id), [alice.id, bob.id], "members (admin first)")
            try Verify.equal(members.map(\.role), [.admin, .member], "member roles")
            try Verify.that(members[1].joinedAt >= members[0].joinedAt, "joinedAt of the new member")
            let seenByBob = try await bob.groups.members(groupId: group.id)
            try Verify.equal(seenByBob, members, "every member sees the same member list")
        },

        ContractScenario("group.joinNormalizesCode") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup()
            let dashed = " \(group.code.formatted.lowercased()) "
            let parsed = try Verify.unwrap(InviteCode(dashed), "InviteCode(\"\(dashed)\")")
            try Verify.equal(parsed, group.code, "normalized dashed input")
            let bobResult = try await bob.groups.join(code: parsed)
            try Verify.equal(bobResult.groupId, group.id, "join with a lowercased dashed code")
            try Verify.that(!bobResult.alreadyMember, "bob is a new member")

            let spaced = "\(group.code.value.prefix(4).lowercased()) \(group.code.value.suffix(4))"
            let carolCode = try Verify.unwrap(InviteCode(spaced), "InviteCode(\"\(spaced)\")")
            let carolResult = try await carol.groups.join(code: carolCode)
            try Verify.equal(carolResult.groupId, group.id, "join with a spaced mixed-case code")
        },

        ContractScenario("group.joinAlreadyMember") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let adminAgain = try await alice.groups.join(code: group.code)
            try Verify.equal(
                adminAgain, JoinResult(groupId: group.id, groupName: group.name, alreadyMember: true),
                "the admin joining their own group"
            )
            let bobAgain = try await bob.groups.join(code: group.code)
            try Verify.equal(
                bobAgain, JoinResult(groupId: group.id, groupName: group.name, alreadyMember: true), "joining twice"
            )
            let aliceRole = try await alice.role(in: group.id)
            try Verify.equal(aliceRole, .admin, "role unchanged by joining again")
            let members = try await alice.memberIDs(of: group.id)
            try Verify.equal(members, [alice.id, bob.id], "no duplicate membership")
        },

        ContractScenario("group.joinInvalidCode") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup()
            try await Verify.fails(with: .invalidCode, "join with an unknown code") {
                try await bob.groups.join(code: Unique.inviteCode())
            }
            let none = try await bob.groups.myGroups()
            try Verify.that(none.isEmpty, "an invalid code joins nothing, got \(none)")
            let result = try await bob.groups.join(code: group.code)
            try Verify.that(!result.alreadyMember && result.groupId == group.id, "a valid code still works after a failure")
        },

        ContractScenario("group.inviteCodeAdminOnly") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let code = try await alice.groups.inviteCode(groupId: group.id)
            try Verify.equal(code, group.code, "the invite code is stable")
            try await Verify.fails(with: .forbidden, "a member reads the invite code") {
                try await bob.groups.inviteCode(groupId: group.id)
            }
            try await Verify.fails(with: .forbidden, "a non-member reads the invite code") {
                try await eve.groups.inviteCode(groupId: group.id)
            }
            try await Verify.fails(with: .forbidden, "invite code of an unknown group") {
                try await alice.groups.inviteCode(groupId: UUID())
            }
            try await alice.groups.setRole(groupId: group.id, userId: bob.id, role: .admin)
            let promotedView = try await bob.groups.inviteCode(groupId: group.id)
            try Verify.equal(promotedView, code, "a promoted admin reads the invite code")
        },

        ContractScenario("group.regenerateInviteCode") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob])
            try await Verify.fails(with: .forbidden, "a member regenerates the code") {
                try await bob.groups.regenerateInviteCode(groupId: group.id)
            }
            try await Verify.fails(with: .forbidden, "a non-member regenerates the code") {
                try await eve.groups.regenerateInviteCode(groupId: group.id)
            }
            let unchanged = try await alice.groups.inviteCode(groupId: group.id)
            try Verify.equal(unchanged, group.code, "refused regenerations keep the code")

            let fresh = try await alice.groups.regenerateInviteCode(groupId: group.id)
            try Verify.that(fresh != group.code, "regenerated code must differ from the old one")
            try Verify.that(isWellFormedCode(fresh), "regenerated code \(fresh.value) must be well formed")
            let current = try await alice.groups.inviteCode(groupId: group.id)
            try Verify.equal(current, fresh, "inviteCode returns the regenerated code")
            try await Verify.fails(with: .invalidCode, "the old code stops working") {
                try await eve.groups.join(code: group.code)
            }
            let joined = try await eve.groups.join(code: fresh)
            try Verify.equal(joined.groupId, group.id, "the new code works")
        },

        ContractScenario("group.rename") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let newName = Unique.name("Renommé")
            let renamed = try await alice.groups.rename(groupId: group.id, name: "  \(newName)  ")
            try Verify.equal(renamed.id, group.id, "renamed group id")
            try Verify.equal(renamed.name, newName, "renamed group name (trimmed)")
            try Verify.equal(renamed.createdBy, alice.id, "createdBy kept")
            let seenByBob = try Verify.unwrap(try await bob.summary(of: group.id), "group in bob's list")
            try Verify.equal(seenByBob.group.name, newName, "members see the new name")

            for invalid in ["", "   ", Fixed.text(61)] {
                try await Verify.fails(with: .invalidName, "rename to \(invalid.count) characters") {
                    try await alice.groups.rename(groupId: group.id, name: invalid)
                }
            }
            try await Verify.fails(with: .forbidden, "a member renames") {
                try await bob.groups.rename(groupId: group.id, name: Unique.name("Pirate"))
            }
            // Lead decision: existing group + non-admin (incl. non-member) → forbidden; unknown group → not found.
            try await Verify.fails(with: .forbidden, "a non-member renames") {
                try await eve.groups.rename(groupId: group.id, name: Unique.name("Pirate"))
            }
            try await Verify.fails(with: .notFound, "rename an unknown group") {
                try await alice.groups.rename(groupId: UUID(), name: Unique.name("Fantôme"))
            }
            let final = try Verify.unwrap(try await alice.summary(of: group.id), "group in alice's list")
            try Verify.equal(final.group.name, newName, "refused renames keep the name")
        },

        ContractScenario("group.delete") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let task = try await bob.makeTask(in: group.id, assignees: [bob])
            try await Verify.fails(with: .forbidden, "a member deletes the group") {
                try await bob.groups.deleteGroup(groupId: group.id)
            }
            try await Verify.fails(with: .forbidden, "a non-member deletes the group") {
                try await eve.groups.deleteGroup(groupId: group.id)
            }
            try await Verify.fails(with: .notFound, "delete an unknown group") {
                try await alice.groups.deleteGroup(groupId: UUID())
            }
            let stillThere = try await bob.tasks.task(id: task.id)
            try Verify.equal(stillThere.id, task.id, "refused deletions keep the group")

            try await Verify.step("admin deletes the group") { try await alice.groups.deleteGroup(groupId: group.id) }
            let aliceGroups = try await alice.groups.myGroups()
            try Verify.that(!aliceGroups.contains { $0.id == group.id }, "deleted group gone for the admin")
            let bobGroups = try await bob.groups.myGroups()
            try Verify.that(!bobGroups.contains { $0.id == group.id }, "deleted group gone for members")
            try await Verify.fails(with: .notFound, "tasks of a deleted group") {
                try await bob.tasks.task(id: task.id)
            }
            let bobTasks = try await bob.tasks.myTasks(includeDone: true)
            try Verify.that(!bobTasks.contains { $0.id == task.id }, "myTasks drops tasks of a deleted group")
            try await Verify.hidden("members of a deleted group") { try await alice.groups.members(groupId: group.id) }
            try await Verify.hidden("tasks of a deleted group") {
                try await alice.tasks.tasks(groupId: group.id, includeOldDone: true)
            }
            try await Verify.fails(with: .invalidCode, "code of a deleted group") {
                try await eve.groups.join(code: group.code)
            }
            try await Verify.fails(with: .notFound, "delete an already deleted group") {
                try await alice.groups.deleteGroup(groupId: group.id)
            }
        },

        ContractScenario("group.myGroupsSortedByActivity") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let first = try await alice.makeGroup("Un")
            let second = try await alice.makeGroup("Deux")
            let third = try await alice.makeGroup("Trois")
            try await alice.expectGroupOrder([third, second, first], "after creation")
            _ = try await alice.makeTask(in: first.id)
            try await alice.expectGroupOrder([first, third, second], "after a task in the first group")
            _ = try await alice.groups.rename(groupId: second.id, name: Unique.name("Deux"))
            try await alice.expectGroupOrder([second, first, third], "after renaming the second group")
            _ = try await bob.join(third)
            try await alice.expectGroupOrder([third, second, first], "after someone joined the third group")
            let bobGroups = try await bob.groups.myGroups()
            try Verify.equal(bobGroups.map(\.id), [third.id], "bob only sees the group he joined")
        },

        ContractScenario("group.activityBumps") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [bob])
            var last = try await alice.lastActivity(of: group.id)

            let task = try await bob.makeTask(in: group.id, assignees: [bob])
            last = try await alice.checkBumped(group.id, since: last, "create_task")
            _ = try await bob.tasks.update(taskId: task.id, draft: TaskDraft(title: "Modifiée", assigneeIds: [bob.id, alice.id]))
            last = try await alice.checkBumped(group.id, since: last, "update_task")
            _ = try await bob.tasks.setStatus(taskId: task.id, status: .done)
            last = try await alice.checkBumped(group.id, since: last, "set_task_status")
            try await bob.tasks.delete(taskId: task.id)
            last = try await alice.checkBumped(group.id, since: last, "delete_task")
            _ = try await carol.join(group)
            last = try await alice.checkBumped(group.id, since: last, "join_group_by_code")
            try await alice.groups.setRole(groupId: group.id, userId: carol.id, role: .admin)
            last = try await alice.checkBumped(group.id, since: last, "set_member_role")
            try await alice.groups.removeMember(groupId: group.id, userId: carol.id)
            last = try await alice.checkBumped(group.id, since: last, "remove_member")
            try await bob.groups.leave(groupId: group.id)
            last = try await alice.checkBumped(group.id, since: last, "leave_group")
            _ = try await alice.groups.rename(groupId: group.id, name: Unique.name("Groupe"))
            _ = try await alice.checkBumped(group.id, since: last, "rename_group")
        },

        ContractScenario("group.nonMemberSeesNothing") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let task = try await bob.makeTask(in: group.id, assignees: [bob])
            let eveGroups = try await eve.groups.myGroups()
            try Verify.that(!eveGroups.contains { $0.id == group.id }, "a non-member does not list the group")
            try await Verify.hidden("members for a non-member") { try await eve.groups.members(groupId: group.id) }
            try await Verify.hidden("tasks for a non-member") {
                try await eve.tasks.tasks(groupId: group.id, includeOldDone: false)
            }
            try await Verify.hidden("all tasks for a non-member") {
                try await eve.tasks.tasks(groupId: group.id, includeOldDone: true)
            }
            try await Verify.fails(with: .notFound, "one task for a non-member") {
                try await eve.tasks.task(id: task.id)
            }
            let eveTasks = try await eve.tasks.myTasks(includeDone: true)
            try Verify.that(eveTasks.isEmpty, "a non-member has no tasks, got \(eveTasks)")
        },
    ]
}

extension ContractUser {
    /// Checks the relative order of `expected` in `myGroups()` and that the whole list is sorted by activity.
    func expectGroupOrder(_ expected: [GroupFixture], _ context: String) async throws {
        let list = try await groups.myGroups()
        let wanted = Set(expected.map(\.id))
        try Verify.equal(list.map(\.id).filter(wanted.contains), expected.map(\.id), "myGroups order \(context)")
        for (newer, older) in zip(list, list.dropFirst()) {
            try Verify.that(
                newer.group.lastActivityAt >= older.group.lastActivityAt,
                "myGroups must be sorted by lastActivityAt desc \(context)"
            )
        }
    }
}
