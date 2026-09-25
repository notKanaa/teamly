import Foundation
import TeamTasksContract
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

extension IntegrationTests {
    /// Avatars, onboarding, group appearance and the activity feed against the local stack (docs/CONTRACTS-V2.md §1,
    /// §2, §5, §7, §9, §10).
    @Suite struct V2ProfileGroupIntegrationTests {
        @Test(.timeLimit(.minutes(1)))
        func avatarAndOnboarding() async throws {
            let alice = try await V2IT.user("Alice Avatar")
            let bob = try await V2IT.user("Bob Avatar")
            let group = try await V2IT.group(of: bob, joinedBy: [alice])

            // A new account: automatic color, the initials, not onboarded yet.
            let fresh = try await alice.profiles.myProfile()
            #expect(fresh.id == alice.id && fresh.displayName == "Alice Avatar")
            #expect(fresh.avatarColor == nil && fresh.avatarEmoji == nil)
            #expect(fresh.onboardedAt == nil)
            let createdAt = try #require(fresh.createdAt)
            #expect(abs(createdAt.timeIntervalSinceNow) < 600, "created just now (\(createdAt))")
            #expect(OnboardingPolicy.shouldShow(profile: fresh, now: Date()))

            // The emoji is stored normalized; the PATCH result carries the avatar (not the onboarding fields).
            let updated = try await alice.profiles.updateAvatar(color: .teal, emoji: " 🦊\u{3000}")
            #expect(updated == UserProfile(id: alice.id, displayName: "Alice Avatar", avatarColor: .teal, avatarEmoji: "🦊"))
            let reread = try await alice.profiles.myProfile()
            #expect(reread.avatarColor == .teal && reread.avatarEmoji == "🦊")
            #expect(reread.createdAt == createdAt)
            let seenByBob = try await bob.groups.members(groupId: group.id).first { $0.user.id == alice.id }?.user
            #expect(seenByBob == UserProfile(id: alice.id, displayName: "Alice Avatar", avatarColor: .teal, avatarEmoji: "🦊"))

            // A rename keeps the avatar in its result.
            let renamed = try await alice.profiles.updateDisplayName("Alice Renommée")
            #expect(renamed == UserProfile(id: alice.id, displayName: "Alice Renommée", avatarColor: .teal, avatarEmoji: "🦊"))

            // Invalid emojis are refused (client rules = server rules); nothing changes.
            for invalid in ["a b", "🦊\u{0}", String(repeating: "🦊", count: 17)] {
                await #expect(throws: AppError.invalidAppearance) { try await alice.profiles.updateAvatar(color: .pink, emoji: invalid) }
            }
            // A ZWJ sequence (7 code points): accepted.
            let family = "👨‍👩‍👧‍👦"
            #expect(try await alice.profiles.updateAvatar(color: .pink, emoji: family).avatarEmoji == family)

            // Back to automatic: NULL color, and a blank emoji is no emoji.
            let cleared = try await alice.profiles.updateAvatar(color: nil, emoji: " \u{200B} ")
            #expect(cleared.avatarColor == nil && cleared.avatarEmoji == nil)
            #expect(try await alice.profiles.myProfile().avatarEmoji == nil)

            // Onboarding: set once.
            try await alice.profiles.completeOnboarding()
            let onboarded = try await alice.profiles.myProfile()
            let onboardedAt = try #require(onboarded.onboardedAt)
            #expect(!OnboardingPolicy.shouldShow(profile: onboarded, now: Date()))
            try await alice.profiles.completeOnboarding()
            #expect(try await alice.profiles.myProfile().onboardedAt == onboardedAt, "a second call changes nothing")
        }

        /// An actual avatar change bumps every group of the user (co-members reload the members); identical values and
        /// the onboarding do not (docs/CONTRACTS-V2.md §2).
        @Test(.timeLimit(.minutes(1)))
        func avatarChangesBumpTheGroups() async throws {
            let alice = try await V2IT.user("Alice Signal")
            let bob = try await V2IT.user("Bob Signal")
            let group = try await V2IT.group(of: bob, joinedBy: [alice])
            let before = try await V2IT.listed(group.id, by: bob).group.lastActivityAt
            _ = try await alice.profiles.updateAvatar(color: .amber, emoji: "🌻")
            let bumped = try await V2IT.listed(group.id, by: bob).group.lastActivityAt
            #expect(bumped > before)
            _ = try await alice.profiles.updateAvatar(color: .amber, emoji: " 🌻 ")
            try await alice.profiles.completeOnboarding()
            #expect(try await V2IT.listed(group.id, by: bob).group.lastActivityAt == bumped)
        }

        @Test(.timeLimit(.minutes(1)))
        func createGroupWithAppearance() async throws {
            let alice = try await V2IT.user("Alice Apparence")
            let bob = try await V2IT.user("Bob Apparence")
            let summary = try await alice.groups.createGroup(name: " Coloc ", color: .coral, emoji: " 🏠 ")
            #expect(summary.myRole == .admin)
            #expect(summary.group.name == "Coloc")
            #expect(summary.group.color == .coral)
            #expect(summary.group.emoji == "🏠")
            #expect(summary.group.createdBy == alice.id)
            #expect(try await V2IT.listed(summary.id, by: alice).group == summary.group)
            let code = try await alice.groups.inviteCode(groupId: summary.id)
            _ = try await bob.groups.join(code: code)
            let seenByBob = try await V2IT.listed(summary.id, by: bob)
            #expect(seenByBob.group.color == .coral && seenByBob.group.emoji == "🏠")

            let plain = try await alice.groups.createGroup(name: "Sans apparence", color: nil, emoji: "  ")
            #expect(plain.group.color == nil && plain.group.emoji == nil)
            #expect(plain.group.resolvedColor == ColorKey.automatic(for: plain.id))
            let v1 = try await alice.groups.createGroup(name: "Comme en v1")
            #expect(v1.group.color == nil && v1.group.emoji == nil)

            let count = try await alice.groups.myGroups().count
            await #expect(throws: AppError.invalidName) { try await alice.groups.createGroup(name: "  ", color: .coral, emoji: "a b") }
            await #expect(throws: AppError.invalidAppearance) { try await alice.groups.createGroup(name: "Groupe", color: .coral, emoji: "a b") }
            #expect(try await alice.groups.myGroups().count == count, "refused creations create nothing")
        }

        /// Admins only; unknown group → `.notFound`, others → `.forbidden`; both values replaced; the group is bumped.
        @Test(.timeLimit(.minutes(1)))
        func setAppearance() async throws {
            let alice = try await V2IT.user("Alice Admin")
            let bob = try await V2IT.user("Bob Membre")
            let eve = try await V2IT.user("Eve Externe")
            let group = try await V2IT.group(of: alice, color: .coral, emoji: "🏠", joinedBy: [bob])
            let before = try await V2IT.listed(group.id, by: bob).group.lastActivityAt

            let updated = try await alice.groups.setAppearance(groupId: group.id, color: .green, emoji: "\u{26BD}")
            #expect(updated.id == group.id && updated.name == group.group.name)
            #expect(updated.color == .green && updated.emoji == "\u{26BD}")
            #expect(updated.lastActivityAt > before)
            #expect(try await V2IT.listed(group.id, by: bob).group == updated)

            await #expect(throws: AppError.forbidden) { try await bob.groups.setAppearance(groupId: group.id, color: .pink, emoji: nil) }
            await #expect(throws: AppError.forbidden) { try await eve.groups.setAppearance(groupId: group.id, color: .pink, emoji: nil) }
            await #expect(throws: AppError.notFound) { try await alice.groups.setAppearance(groupId: UUID(), color: .pink, emoji: nil) }
            await #expect(throws: AppError.invalidAppearance) {
                try await alice.groups.setAppearance(groupId: group.id, color: .pink, emoji: String(repeating: "⚽", count: 17))
            }
            // The server's order (§3): the group, then the rights, then the emoji (U+0000 included).
            await #expect(throws: AppError.forbidden) { try await bob.groups.setAppearance(groupId: group.id, color: .pink, emoji: "a b") }
            await #expect(throws: AppError.forbidden) { try await eve.groups.setAppearance(groupId: group.id, color: .pink, emoji: "\u{0}") }
            await #expect(throws: AppError.notFound) { try await alice.groups.setAppearance(groupId: UUID(), color: .pink, emoji: "a b") }
            await #expect(throws: AppError.invalidAppearance) {
                try await alice.groups.setAppearance(groupId: group.id, color: .pink, emoji: "⚽\u{0}")
            }
            #expect(try await V2IT.listed(group.id, by: alice).group == updated, "refused changes keep the appearance (no bump)")

            // Sent as typed, stored normalized.
            let trimmed = try await alice.groups.setAppearance(groupId: group.id, color: .teal, emoji: " \u{26BD}\u{3000}")
            #expect(trimmed.color == .teal && trimmed.emoji == "\u{26BD}")
            let blank = try await alice.groups.setAppearance(groupId: group.id, color: .teal, emoji: " \u{200B} ")
            #expect(blank.emoji == nil, "a blank emoji is no emoji")

            let cleared = try await alice.groups.setAppearance(groupId: group.id, color: nil, emoji: nil)
            #expect(cleared.color == nil && cleared.emoji == nil)
        }

        /// Every kind of event, newest first, with its actor, subject and title snapshots; non-members read nothing.
        @Test(.timeLimit(.minutes(2)))
        func activityFeed() async throws {
            let alice = try await V2IT.user("Alice Fil")
            let bob = try await V2IT.user("Bob Fil")
            let carol = try await V2IT.user("Carol Fil")
            let eve = try await V2IT.user("Eve Fil")
            let group = try await V2IT.group(of: alice, joinedBy: [bob])
            let task = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                title: "Vaisselle", dueAt: V2IT.monday, recurrence: V2IT.weekly, rotation: [bob.id, alice.id], checklist: ["Laver"]
            ))
            let item = try #require(task.checklist.first)
            _ = try await bob.tasks.setChecklistItemDone(itemId: item.id, done: true)
            _ = try await bob.tasks.setChecklistItemDone(itemId: item.id, done: true) // no-op: no event
            let done = try await bob.tasks.setStatus(taskId: task.id, status: .done)
            let next = try #require(done.nextOccurrenceId)
            // Titles are snapshots: a later rename does not change them.
            let completed = try await alice.tasks.task(id: task.id)
            _ = try await alice.tasks.update(taskId: task.id, draft: TaskDraft(task: completed).renamed("Plus la vaisselle"))
            let code = try await alice.groups.inviteCode(groupId: group.id)
            _ = try await carol.groups.join(code: code)
            try await carol.groups.leave(groupId: group.id)

            let feed = try await bob.groups.activity(groupId: group.id)
            #expect(feed.map(\.kind) == [
                .memberLeft, .memberJoined, .turnStarted, .taskCompleted, .checklistItemDone, .taskCreated, .memberJoined,
            ])
            #expect(zip(feed, feed.dropFirst()).allSatisfy { $0.id > $1.id && $0.createdAt >= $1.createdAt })
            #expect(feed[0].actorId == carol.id && feed[0].subjectId == carol.id)
            #expect(feed[1].actorId == carol.id && feed[1].subjectId == carol.id)
            #expect(feed[2].actorId == nil && feed[2].subjectId == alice.id && feed[2].taskId == next)
            #expect(feed[3].actorId == bob.id && feed[3].taskId == task.id && feed[3].taskTitle == "Vaisselle")
            #expect(feed[4].actorId == bob.id && feed[4].taskId == task.id && feed[4].itemTitle == "Laver")
            #expect(feed[4].taskTitle == "Vaisselle")
            #expect(feed[5].actorId == alice.id && feed[5].taskTitle == "Vaisselle")
            #expect(feed[6].actorId == bob.id && feed[6].subjectId == bob.id)
            #expect(try await alice.groups.activity(groupId: group.id) == feed, "every member reads the same feed")
            #expect(try await eve.groups.activity(groupId: group.id).isEmpty, "non-members read nothing")
            #expect(try await carol.groups.activity(groupId: group.id).isEmpty, "a member who left reads nothing")
        }

        /// The feed is the newest `Limits.activityFeedMax` events.
        @Test(.timeLimit(.minutes(2)))
        func activityFeedIsTheNewestFifty() async throws {
            let alice = try await V2IT.user("Alice Cinquante")
            let group = try await V2IT.group(of: alice)
            var last: TaskItem?
            for index in 1...(Limits.activityFeedMax + 1) {
                last = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(title: "Tâche \(index)"))
            }
            let feed = try await alice.groups.activity(groupId: group.id)
            #expect(feed.count == Limits.activityFeedMax)
            #expect(feed.allSatisfy { $0.kind == .taskCreated })
            #expect(feed.first?.taskId == last?.id)
            #expect(feed.last?.taskTitle == "Tâche 2", "the oldest event is not read")
        }

        /// A newer server (a color or an event kind this client does not know, played by rewriting the real answers):
        /// the color reads as automatic, the event is left out, nothing else changes.
        @Test(.timeLimit(.minutes(1)))
        func unknownColorsAndKindsAreTolerated() async throws {
            let newer = RewritingTransport(replacements: [
                (#""color":\s*"coral""#, #""color": "magenta""#),
                (#""avatar_color":\s*"coral""#, #""avatar_color": "magenta""#),
                (#""kind":\s*"member_joined""#, #""kind": "member_promoted""#),
            ])
            let alice = try await SupabaseHarness.signUp(
                displayName: "Alice Future", services: try IntegrationEnvironment.makeServices(transport: newer)
            )
            let bob = try await V2IT.user("Bob Future")
            let group = try await V2IT.group(of: alice, color: .coral, emoji: "🏠", joinedBy: [bob])
            #expect(group.group.color == nil, "the create_group row is read by the newer client too")
            #expect(group.group.emoji == "🏠")
            _ = try await alice.profiles.updateAvatar(color: .coral, emoji: "🦊")
            _ = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(title: "Courses", assigneeIds: [alice.id]))

            let listed = try await V2IT.listed(group.id, by: alice)
            #expect(listed.group.color == nil && listed.group.emoji == "🏠")
            #expect(listed.group.resolvedColor == ColorKey.automatic(for: group.id))
            let mine = try await alice.tasks.myTasks(includeDone: true)
            #expect(mine.count == 1)
            #expect(mine.first?.groupColor == nil && mine.first?.groupEmoji == "🏠")
            let me = try await alice.profiles.myProfile()
            #expect(me.avatarColor == nil && me.avatarEmoji == "🦊")
            let members = try await alice.groups.members(groupId: group.id)
            #expect(members.map(\.user.id) == [alice.id, bob.id])
            #expect(members.first?.user.avatarColor == nil)

            let feed = try await alice.groups.activity(groupId: group.id)
            #expect(feed.map(\.kind) == [.taskCreated], "member_joined events left out")
            // The same data read by this client version.
            #expect(try await bob.groups.activity(groupId: group.id).map(\.kind) == [.taskCreated, .memberJoined])
            #expect(try await V2IT.listed(group.id, by: bob).group.color == .coral)
            #expect(try await bob.groups.members(groupId: group.id).first?.user.avatarColor == .coral)
        }
    }
}

extension TaskDraft {
    /// The same draft with another title.
    func renamed(_ title: String) -> TaskDraft {
        var draft = self
        draft.title = title
        return draft
    }
}
