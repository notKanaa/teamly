import Foundation
import TeamTasksCore

/// The five columns of the permission matrix (docs/CONTRACTS.md §2) around one task.
struct MatrixFixture: Sendable {
    let admin: ContractUser
    let creator: ContractUser
    let assignee: ContractUser
    let other: ContractUser
    let outsider: ContractUser
    let group: GroupFixture
    /// Created by `creator`, assigned to `assignee`.
    let task: TaskItem

    var members: [ContractUser] { [admin, creator, assignee, other] }

    static func make(_ harness: any ContractHarness) async throws -> MatrixFixture {
        let admin = try await harness.user("Admin")
        let creator = try await harness.user("Createur")
        let assignee = try await harness.user("Assigne")
        let other = try await harness.user("Membre")
        let outsider = try await harness.user("Externe")
        let group = try await admin.makeGroup(joinedBy: [creator, assignee, other])
        let task = try await creator.makeTask(in: group.id, "Matrice", assignees: [assignee])
        return MatrixFixture(
            admin: admin, creator: creator, assignee: assignee, other: other, outsider: outsider, group: group, task: task
        )
    }
}

// The §2 matrix, one scenario per row, plus per-group rights and the "creator who left" rule.
extension ContractScenarios {
    static let matrixScenarios: [ContractScenario] = [
        ContractScenario("matrix.seeGroupMembersAndTasks") { harness in
            let fixture = try await MatrixFixture.make(harness)
            for user in fixture.members {
                let summary = try await user.summary(of: fixture.group.id)
                try Verify.that(summary != nil, "\(user.displayName) lists the group")
                let members = try await user.memberIDs(of: fixture.group.id)
                try Verify.equal(members.count, 4, "\(user.displayName) sees every member")
                let tasks = try await user.tasks.tasks(groupId: fixture.group.id, includeOldDone: false)
                try Verify.equal(tasks, [fixture.task], "\(user.displayName) sees the group's tasks")
                let task = try await user.tasks.task(id: fixture.task.id)
                try Verify.equal(task, fixture.task, "\(user.displayName) reads the task")
            }
            let outsiderGroups = try await fixture.outsider.groups.myGroups()
            try Verify.that(outsiderGroups.isEmpty, "a non-member lists no group")
            try await Verify.hidden("members for a non-member") {
                try await fixture.outsider.groups.members(groupId: fixture.group.id)
            }
            try await Verify.hidden("tasks for a non-member") {
                try await fixture.outsider.tasks.tasks(groupId: fixture.group.id, includeOldDone: true)
            }
            try await Verify.fails(with: .notFound, "a task for a non-member") {
                try await fixture.outsider.tasks.task(id: fixture.task.id)
            }
        },

        ContractScenario("matrix.createTask") { harness in
            let fixture = try await MatrixFixture.make(harness)
            for user in fixture.members {
                let draft = TaskDraft(title: Unique.name("Nouvelle"), assigneeIds: [user.id, fixture.admin.id])
                let created = try await Verify.step("\(user.displayName) creates a task") {
                    try await user.tasks.create(groupId: fixture.group.id, draft: draft)
                }
                try Verify.equal(created.createdBy, user.id, "createdBy of a task created by \(user.displayName)")
                let expected = Set([user.id, fixture.admin.id]).sorted { $0.uuidString < $1.uuidString }
                try Verify.equal(created.assigneeIds, expected, "assignees incl. self")
            }
            try await Verify.fails(with: .forbidden, "a non-member creates a task") {
                try await fixture.outsider.tasks.create(groupId: fixture.group.id, draft: TaskDraft(title: "Intrusion"))
            }
            try await Verify.fails(with: .forbidden, "create a task in an unknown group") {
                try await fixture.admin.tasks.create(groupId: UUID(), draft: TaskDraft(title: "Fantôme"))
            }
            let tasks = try await fixture.admin.tasks.tasks(groupId: fixture.group.id, includeOldDone: true)
            try Verify.equal(tasks.count, 5, "four new tasks plus the fixture task")
        },

        ContractScenario("matrix.editTask") { harness in
            let fixture = try await MatrixFixture.make(harness)
            let draft = TaskDraft(title: Unique.name("Modif"), assigneeIds: [fixture.other.id])
            try await Verify.fails(with: .forbidden, "the assignee edits the task") {
                try await fixture.assignee.tasks.update(taskId: fixture.task.id, draft: draft)
            }
            try await Verify.fails(with: .forbidden, "another member edits the task") {
                try await fixture.other.tasks.update(taskId: fixture.task.id, draft: draft)
            }
            try await Verify.fails(with: .notFound, "a non-member edits the task") {
                try await fixture.outsider.tasks.update(taskId: fixture.task.id, draft: draft)
            }
            let unchanged = try await fixture.admin.tasks.task(id: fixture.task.id)
            try Verify.equal(unchanged, fixture.task, "refused edits change nothing")

            let byCreator = try await Verify.step("the creator edits") {
                try await fixture.creator.tasks.update(taskId: fixture.task.id, draft: draft)
            }
            try Verify.equal(byCreator.title, draft.title, "title edited by the creator")
            try Verify.equal(byCreator.assigneeIds, [fixture.other.id], "assignees edited by the creator")
            let adminDraft = TaskDraft(title: Unique.name("Admin"), priority: .high, assigneeIds: [fixture.assignee.id])
            let byAdmin = try await Verify.step("the admin edits") {
                try await fixture.admin.tasks.update(taskId: fixture.task.id, draft: adminDraft)
            }
            try Verify.equal(byAdmin.title, adminDraft.title, "title edited by the admin")
            try Verify.equal(byAdmin.priority, .high, "priority edited by the admin")
            try Verify.equal(byAdmin.createdBy, fixture.creator.id, "createdBy unchanged by an admin edit")
        },

        ContractScenario("matrix.changeStatus") { harness in
            let fixture = try await MatrixFixture.make(harness)
            try await Verify.fails(with: .forbidden, "another member changes the status") {
                try await fixture.other.tasks.setStatus(taskId: fixture.task.id, status: .inProgress)
            }
            try await Verify.fails(with: .notFound, "a non-member changes the status") {
                try await fixture.outsider.tasks.setStatus(taskId: fixture.task.id, status: .inProgress)
            }
            let byAssignee = try await Verify.step("the assignee changes the status") {
                try await fixture.assignee.tasks.setStatus(taskId: fixture.task.id, status: .inProgress)
            }
            try Verify.equal(byAssignee.status, .inProgress, "status set by the assignee")
            try Verify.equal(byAssignee.title, fixture.task.title, "a status change keeps the other fields")
            let byCreator = try await Verify.step("the creator changes the status") {
                try await fixture.creator.tasks.setStatus(taskId: fixture.task.id, status: .done)
            }
            try Verify.equal(byCreator.status, .done, "status set by the creator")
            let byAdmin = try await Verify.step("the admin changes the status") {
                try await fixture.admin.tasks.setStatus(taskId: fixture.task.id, status: .todo)
            }
            try Verify.equal(byAdmin.status, .todo, "status set by the admin")

            _ = try await fixture.creator.reassign(byAdmin, to: [])
            try await Verify.fails(with: .forbidden, "a former assignee changes the status") {
                try await fixture.assignee.tasks.setStatus(taskId: fixture.task.id, status: .done)
            }
        },

        ContractScenario("matrix.deleteTask") { harness in
            let fixture = try await MatrixFixture.make(harness)
            let second = try await fixture.creator.makeTask(in: fixture.group.id, assignees: [fixture.assignee])
            try await Verify.fails(with: .forbidden, "the assignee deletes the task") {
                try await fixture.assignee.tasks.delete(taskId: fixture.task.id)
            }
            try await Verify.fails(with: .forbidden, "another member deletes the task") {
                try await fixture.other.tasks.delete(taskId: fixture.task.id)
            }
            try await Verify.fails(with: .notFound, "a non-member deletes the task") {
                try await fixture.outsider.tasks.delete(taskId: fixture.task.id)
            }
            try await Verify.step("the creator deletes") { try await fixture.creator.tasks.delete(taskId: fixture.task.id) }
            try await Verify.step("the admin deletes") { try await fixture.admin.tasks.delete(taskId: second.id) }
            for user in fixture.members {
                try await Verify.fails(with: .notFound, "\(user.displayName) reads a deleted task") {
                    try await user.tasks.task(id: fixture.task.id)
                }
            }
            try await Verify.fails(with: .notFound, "delete a deleted task") {
                try await fixture.creator.tasks.delete(taskId: fixture.task.id)
            }
            let remaining = try await fixture.admin.tasks.tasks(groupId: fixture.group.id, includeOldDone: true)
            try Verify.that(remaining.isEmpty, "both tasks are gone, got \(remaining)")
        },

        ContractScenario("matrix.groupAdminActions") { harness in
            let fixture = try await MatrixFixture.make(harness)
            let groupId = fixture.group.id
            let nonAdmins = [fixture.creator, fixture.assignee, fixture.other]
            for (index, user) in nonAdmins.enumerated() {
                let target = nonAdmins[(index + 1) % nonAdmins.count]
                try await Verify.fails(with: .forbidden, "\(user.displayName) renames") {
                    try await user.groups.rename(groupId: groupId, name: Unique.name("Pirate"))
                }
                try await Verify.fails(with: .forbidden, "\(user.displayName) deletes the group") {
                    try await user.groups.deleteGroup(groupId: groupId)
                }
                try await Verify.fails(with: .forbidden, "\(user.displayName) reads the invite code") {
                    try await user.groups.inviteCode(groupId: groupId)
                }
                try await Verify.fails(with: .forbidden, "\(user.displayName) regenerates the invite code") {
                    try await user.groups.regenerateInviteCode(groupId: groupId)
                }
                try await Verify.fails(with: .forbidden, "\(user.displayName) changes a role") {
                    try await user.groups.setRole(groupId: groupId, userId: target.id, role: .admin)
                }
                try await Verify.fails(with: .forbidden, "\(user.displayName) removes a member") {
                    try await user.groups.removeMember(groupId: groupId, userId: target.id)
                }
            }
            let outsider = fixture.outsider
            try await Verify.fails(withAnyOf: [.forbidden, .notFound], "a non-member renames") {
                try await outsider.groups.rename(groupId: groupId, name: Unique.name("Pirate"))
            }
            try await Verify.fails(withAnyOf: [.forbidden, .notFound], "a non-member deletes the group") {
                try await outsider.groups.deleteGroup(groupId: groupId)
            }
            try await Verify.fails(with: .forbidden, "a non-member reads the invite code") {
                try await outsider.groups.inviteCode(groupId: groupId)
            }
            try await Verify.fails(with: .forbidden, "a non-member regenerates the invite code") {
                try await outsider.groups.regenerateInviteCode(groupId: groupId)
            }
            try await Verify.fails(with: .forbidden, "a non-member changes a role") {
                try await outsider.groups.setRole(groupId: groupId, userId: fixture.other.id, role: .admin)
            }
            try await Verify.fails(with: .forbidden, "a non-member removes a member") {
                try await outsider.groups.removeMember(groupId: groupId, userId: fixture.other.id)
            }
            let members = try await fixture.admin.memberIDs(of: groupId)
            try Verify.equal(members.count, 4, "refused actions change no membership")

            let admin = fixture.admin
            try await Verify.step("the admin renames, reads and regenerates the code, manages members") {
                _ = try await admin.groups.rename(groupId: groupId, name: Unique.name("Groupe"))
                _ = try await admin.groups.inviteCode(groupId: groupId)
                _ = try await admin.groups.regenerateInviteCode(groupId: groupId)
                try await admin.groups.setRole(groupId: groupId, userId: fixture.other.id, role: .admin)
                try await admin.groups.removeMember(groupId: groupId, userId: fixture.other.id)
                try await admin.groups.deleteGroup(groupId: groupId)
            }
        },

        ContractScenario("matrix.rightsArePerGroup") { harness in
            let alice = try await harness.user("Alice")
            let xavier = try await harness.user("Xavier")
            let aliceGroup = try await alice.makeGroup("Alice", joinedBy: [xavier])
            let xavierGroup = try await xavier.makeGroup("Xavier", joinedBy: [alice])
            let xavierTask = try await xavier.makeTask(in: xavierGroup.id, assignees: [xavier])
            let aliceTask = try await alice.makeTask(in: aliceGroup.id, assignees: [alice])
            let groupId = xavierGroup.id

            // Admin of her own group, Alice is a plain member of Xavier's group.
            try await Verify.fails(with: .forbidden, "rename another group") {
                try await alice.groups.rename(groupId: groupId, name: Unique.name("Pirate"))
            }
            try await Verify.fails(with: .forbidden, "read another group's code") {
                try await alice.groups.inviteCode(groupId: groupId)
            }
            try await Verify.fails(with: .forbidden, "regenerate another group's code") {
                try await alice.groups.regenerateInviteCode(groupId: groupId)
            }
            try await Verify.fails(with: .forbidden, "delete another group") {
                try await alice.groups.deleteGroup(groupId: groupId)
            }
            try await Verify.fails(with: .forbidden, "change a role in another group") {
                try await alice.groups.setRole(groupId: groupId, userId: xavier.id, role: .member)
            }
            try await Verify.fails(with: .forbidden, "remove a member of another group") {
                try await alice.groups.removeMember(groupId: groupId, userId: xavier.id)
            }
            try await Verify.fails(with: .forbidden, "edit a task of another group") {
                try await alice.tasks.update(taskId: xavierTask.id, draft: TaskDraft(title: "Pirate"))
            }
            try await Verify.fails(with: .forbidden, "change the status of a task of another group") {
                try await alice.tasks.setStatus(taskId: xavierTask.id, status: .done)
            }
            try await Verify.fails(with: .forbidden, "delete a task of another group") {
                try await alice.tasks.delete(taskId: xavierTask.id)
            }
            try await Verify.fails(with: .forbidden, "Xavier edits a task of Alice's group") {
                try await xavier.tasks.update(taskId: aliceTask.id, draft: TaskDraft(title: "Pirate"))
            }
            let aliceRole = try await alice.role(in: groupId)
            try Verify.equal(aliceRole, .member, "Alice's role in Xavier's group")
        },

        ContractScenario("matrix.creatorWhoLeftHasNoRights") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let task = try await bob.makeTask(in: group.id, assignees: [bob])
            _ = try await Verify.step("the creator edits while a member") {
                try await bob.tasks.update(taskId: task.id, draft: TaskDraft(title: Unique.name("Avant")))
            }
            try await bob.groups.leave(groupId: group.id)

            try await Verify.fails(with: .notFound, "a creator who left reads the task") {
                try await bob.tasks.task(id: task.id)
            }
            try await Verify.fails(with: .notFound, "a creator who left edits the task") {
                try await bob.tasks.update(taskId: task.id, draft: TaskDraft(title: "Pirate"))
            }
            try await Verify.fails(with: .notFound, "a creator who left changes the status") {
                try await bob.tasks.setStatus(taskId: task.id, status: .done)
            }
            try await Verify.fails(with: .notFound, "a creator who left deletes the task") {
                try await bob.tasks.delete(taskId: task.id)
            }
            let kept = try await alice.tasks.task(id: task.id)
            try Verify.equal(kept.createdBy, bob.id, "createdBy kept after the creator left")
            try Verify.equal(kept.assigneeIds, [], "the creator's assignment was deleted")

            let rejoined = try await bob.join(group)
            try Verify.that(!rejoined.alreadyMember, "rejoining is a new membership")
            let role = try await bob.role(in: group.id)
            try Verify.equal(role, .member, "a rejoining member is a plain member")
            let edited = try await Verify.step("the creator edits again once a member") {
                try await bob.tasks.update(taskId: task.id, draft: TaskDraft(title: Unique.name("Après")))
            }
            try Verify.equal(edited.createdBy, bob.id, "createdBy still the creator")
            try await Verify.step("the creator deletes again once a member") { try await bob.tasks.delete(taskId: task.id) }
        },
    ]
}
