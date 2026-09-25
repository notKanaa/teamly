import Foundation
import TeamTasksCore

// v2 appearance and onboarding (docs/CONTRACTS-V2.md §1–§3, §5, §9). A `ColorKey` is typed, so `invalid_color` cannot
// be sent through the Swift API: the color checks of §3 are covered by pgTAP, the emoji checks here.
extension ContractScenarios {
    static let appearanceScenarios: [ContractScenario] = [
        ContractScenario("appearance.createGroup") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let name = Unique.name("Coloc")
            let created = try await alice.groups.createGroup(name: "  \(name)  ", color: .coral, emoji: " 🏠 ")
            try Verify.equal(created.group.name, name, "the name (trimmed)")
            try Verify.equal(created.group.color, .coral, "the color")
            try Verify.equal(created.group.emoji, "🏠", "the emoji (trimmed)")
            try Verify.equal(created.group.createdBy, alice.id, "createdBy")
            try Verify.equal(created.myRole, .admin, "the creator's role")
            let listed = try Verify.unwrap(try await alice.summary(of: created.id), "the new group in myGroups")
            try Verify.equal(listed, created, "myGroups returns what createGroup returned")

            let code = try await alice.groups.inviteCode(groupId: created.id)
            _ = try await bob.join(GroupFixture(id: created.id, name: name, code: code))
            let seenByBob = try Verify.unwrap(try await bob.summary(of: created.id), "the group in bob's list")
            try Verify.equal(seenByBob.group, created.group.withLastActivity(of: seenByBob.group), "members read the appearance")

            // The v1 call: an automatic color and no emoji.
            let plain = try await alice.groups.createGroup(name: Unique.name("Groupe"))
            try Verify.equal(plain.group.color, nil, "createGroup(name:): an automatic color")
            try Verify.equal(plain.group.emoji, nil, "createGroup(name:): no emoji")

            // One emoji may have several code points (ZWJ sequence, flag, keycap), 16 at most; a blank one is none.
            for emoji in ["👨‍👩‍👧‍👦", "🇫🇷", "1️⃣", String(repeating: "😀", count: Limits.emojiCodePointsMax)] {
                let group = try await Verify.step("create a group with the emoji \(emoji)") {
                    try await alice.groups.createGroup(name: Unique.name("Emoji"), color: .violet, emoji: emoji)
                }
                try Verify.equal(group.group.emoji, emoji, "the emoji \(emoji) is stored as is")
            }
            let blank = try await alice.groups.createGroup(name: Unique.name("Vide"), color: nil, emoji: " \u{200B}\u{3000} ")
            try Verify.equal(blank.group.emoji, nil, "a blank emoji is stored as no emoji")
            try Verify.equal(blank.group.color, nil, "nil = an automatic color")
        },

        ContractScenario("appearance.createGroupValidation") { harness in
            let alice = try await harness.user("Alice")
            let invalidEmojis = [
                String(repeating: "😀", count: Limits.emojiCodePointsMax + 1), "😀 😀", "😀\u{00A0}😀", "😀\u{200B}😀",
                "😀\u{07}", "😀\u{85}😀", "😀\u{1F}",
            ]
            for emoji in invalidEmojis {
                try await Verify.fails(with: .invalidAppearance, "the emoji \(emoji.unicodeScalars.map(\.value))") {
                    try await alice.groups.createGroup(name: Unique.name("Groupe"), color: .blue, emoji: emoji)
                }
            }
            // Order (§3): the name, then the color, then the emoji.
            try await Verify.fails(with: .invalidName, "the name is checked before the emoji") {
                try await alice.groups.createGroup(name: "   ", color: .teal, emoji: "x y")
            }
            let none = try await alice.groups.myGroups()
            try Verify.that(none.isEmpty, "refused creations create nothing, got \(none)")
        },

        ContractScenario("appearance.setGroupAppearance") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let before = try Verify.unwrap(try await alice.summary(of: group.id), "the group").group

            // Order (§3): group_not_found → forbidden → color → emoji.
            try await Verify.fails(with: .forbidden, "a member sets the appearance") {
                try await bob.groups.setAppearance(groupId: group.id, color: .blue, emoji: nil)
            }
            try await Verify.fails(with: .forbidden, "a member with an invalid emoji: the permission first") {
                try await bob.groups.setAppearance(groupId: group.id, color: .blue, emoji: "x y")
            }
            try await Verify.fails(with: .forbidden, "a non-member sets the appearance") {
                try await eve.groups.setAppearance(groupId: group.id, color: .blue, emoji: nil)
            }
            try await Verify.fails(with: .notFound, "an unknown group") {
                try await alice.groups.setAppearance(groupId: UUID(), color: .blue, emoji: nil)
            }
            try await Verify.fails(with: .notFound, "an unknown group with an invalid emoji: the group first") {
                try await alice.groups.setAppearance(groupId: UUID(), color: .blue, emoji: "x y")
            }
            try await Verify.fails(with: .invalidAppearance, "the admin with an invalid emoji") {
                try await alice.groups.setAppearance(groupId: group.id, color: .teal, emoji: "a\u{07}")
            }
            let unchanged = try Verify.unwrap(try await alice.summary(of: group.id), "the group").group
            try Verify.equal(unchanged, before, "refused calls change nothing (no bump either)")

            let decorated = try await alice.groups.setAppearance(groupId: group.id, color: .teal, emoji: " ⚽ ")
            try Verify.equal(decorated.id, group.id, "the group")
            try Verify.equal(decorated.name, group.name, "the name is kept")
            try Verify.equal(decorated.createdBy, alice.id, "createdBy is kept")
            try Verify.equal(decorated.color, .teal, "the new color")
            try Verify.equal(decorated.emoji, "⚽", "the new emoji (trimmed)")
            try Verify.that(decorated.lastActivityAt > before.lastActivityAt, "setAppearance bumps lastActivityAt")
            let seenByBob = try Verify.unwrap(try await bob.summary(of: group.id), "the group in bob's list")
            try Verify.equal(seenByBob.group, decorated, "members read what setAppearance returned")

            let cleared = try await alice.groups.setAppearance(groupId: group.id, color: nil, emoji: "   ")
            try Verify.equal(cleared.color, nil, "nil = an automatic color")
            try Verify.equal(cleared.emoji, nil, "a blank emoji = no emoji")

            try await alice.groups.setRole(groupId: group.id, userId: bob.id, role: .admin)
            let byBob = try await bob.groups.setAppearance(groupId: group.id, color: .pink, emoji: "🎉")
            try Verify.equal(byBob.color, .pink, "a promoted admin sets the color")
            try Verify.equal(byBob.emoji, "🎉", "a promoted admin sets the emoji")
            // A v1 RPC returns the v2 columns too.
            let renamed = try await alice.groups.rename(groupId: group.id, name: Unique.name("Renommé"))
            try Verify.equal(renamed.color, .pink, "rename_group keeps and returns the color")
            try Verify.equal(renamed.emoji, "🎉", "rename_group keeps and returns the emoji")
        },

        ContractScenario("appearance.avatar") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let initial = try await alice.profiles.myProfile()

            // The result has the avatar; `onboardedAt` and `createdAt` are only read by `myProfile()`.
            let updated = try await alice.profiles.updateAvatar(color: .violet, emoji: " 🦊\n")
            let avatar = UserProfile(id: alice.id, displayName: alice.displayName, avatarColor: .violet, avatarEmoji: "🦊")
            try Verify.equal(updated, avatar, "the returned profile (the emoji trimmed)")
            let reread = try await alice.profiles.myProfile()
            var expected = avatar
            expected.onboardedAt = initial.onboardedAt
            expected.createdAt = initial.createdAt
            try Verify.equal(reread, expected, "myProfile after updateAvatar")
            let members = try await bob.groups.members(groupId: group.id)
            let seen = try Verify.unwrap(members.first { $0.user.id == alice.id }, "alice among the members")
            try Verify.equal(seen.user, avatar, "co-members read the avatar (the members list has no onboarding fields)")

            for emoji in [String(repeating: "🦊", count: Limits.emojiCodePointsMax + 1), "🦊 🦊", "🦊\u{1F}"] {
                try await Verify.fails(with: .invalidAppearance, "the avatar emoji \(emoji.unicodeScalars.map(\.value))") {
                    try await alice.profiles.updateAvatar(color: .amber, emoji: emoji)
                }
            }
            let unchanged = try await alice.profiles.myProfile()
            try Verify.equal(unchanged, reread, "refused updates change nothing")

            let renamed = try await alice.profiles.updateDisplayName(Unique.name("Alice"))
            try Verify.equal(renamed.avatarColor, .violet, "a display-name change keeps the avatar color")
            try Verify.equal(renamed.avatarEmoji, "🦊", "a display-name change keeps the avatar emoji")
            let cleared = try await alice.profiles.updateAvatar(color: nil, emoji: "  ")
            try Verify.equal(
                cleared, UserProfile(id: alice.id, displayName: renamed.displayName),
                "nil = an automatic color, a blank emoji = the initials"
            )
        },

        ContractScenario("appearance.profileChangeBumpsGroups") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let shared = try await alice.makeGroup("Commun", joinedBy: [bob])
            let own = try await bob.makeGroup("Bob")
            let other = try await alice.makeGroup("Autre")
            var sharedLast = try await alice.lastActivity(of: shared.id)
            var ownLast = try await bob.lastActivity(of: own.id)
            let otherLast = try await alice.lastActivity(of: other.id)

            _ = try await bob.profiles.updateDisplayName(Unique.name("Robert"))
            sharedLast = try await alice.checkBumped(shared.id, since: sharedLast, "a co-member's display-name change")
            ownLast = try await bob.checkBumped(own.id, since: ownLast, "a display-name change")
            _ = try await bob.profiles.updateAvatar(color: .amber, emoji: "🦉")
            sharedLast = try await alice.checkBumped(shared.id, since: sharedLast, "a co-member's avatar change")
            ownLast = try await bob.checkBumped(own.id, since: ownLast, "an avatar change")

            // Identical values and the onboarding bump nothing.
            let current = try await bob.profiles.myProfile()
            _ = try await bob.profiles.updateAvatar(color: .amber, emoji: "🦉")
            _ = try await bob.profiles.updateDisplayName(current.displayName)
            try await bob.profiles.completeOnboarding()
            let sharedAfter = try await alice.lastActivity(of: shared.id)
            try Verify.equal(sharedAfter, sharedLast, "identical values and the onboarding do not bump the groups")
            let ownAfter = try await bob.lastActivity(of: own.id)
            try Verify.equal(ownAfter, ownLast, "identical values and the onboarding do not bump the user's own group")
            let otherAfter = try await alice.lastActivity(of: other.id)
            try Verify.equal(otherAfter, otherLast, "a group the user is not in is never bumped")
        },
    ]

    static let onboardingScenarios: [ContractScenario] = [
        ContractScenario("onboarding.completeOnboarding") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let fresh = try await alice.profiles.myProfile()
            try Verify.newProfile(fresh, id: alice.id, displayName: alice.displayName, "a new account")
            let createdAt = try Verify.unwrap(fresh.createdAt, "createdAt of a new account")

            // The backend's clock: a group created now is not older than the account.
            let group = try await alice.makeGroup(joinedBy: [bob])
            let groupCreatedAt = try Verify.unwrap(try await alice.summary(of: group.id), "the group").group.createdAt
            try Verify.that(createdAt <= groupCreatedAt, "the account (\(createdAt)) predates the group (\(groupCreatedAt))")
            try Verify.that(
                OnboardingPolicy.shouldShow(profile: fresh, now: groupCreatedAt), "a new account is shown the onboarding"
            )
            let members = try await bob.groups.members(groupId: group.id)
            let asMember = try Verify.unwrap(members.first { $0.user.id == alice.id }, "alice among the members")
            try Verify.equal(asMember.user.onboardedAt, nil, "the members list has no onboardedAt")
            try Verify.equal(asMember.user.createdAt, nil, "the members list has no createdAt")

            try await Verify.step("completeOnboarding") { try await alice.profiles.completeOnboarding() }
            let done = try await alice.profiles.myProfile()
            let onboardedAt = try Verify.unwrap(done.onboardedAt, "onboardedAt after completeOnboarding")
            try Verify.that(onboardedAt >= groupCreatedAt, "onboardedAt is the time of the call")
            try Verify.equal(
                done, UserProfile(id: alice.id, displayName: alice.displayName, onboardedAt: onboardedAt, createdAt: createdAt),
                "only onboardedAt changed"
            )
            try Verify.that(!OnboardingPolicy.shouldShow(profile: done, now: onboardedAt), "the onboarding is not shown again")

            try await Verify.step("completeOnboarding again") { try await alice.profiles.completeOnboarding() }
            let again = try await alice.profiles.myProfile()
            try Verify.equal(again, done, "a second call keeps onboardedAt")
            let later = try await alice.groups.createGroup(name: Unique.name("Plus tard"))
            try Verify.that(onboardedAt <= later.group.createdAt, "onboardedAt comes from the backend's clock")

            let bobProfile = try await bob.profiles.myProfile()
            try Verify.equal(bobProfile.onboardedAt, nil, "other accounts are not onboarded")
            try await bob.auth.signOut()
            try await Verify.fails(with: .notAuthenticated, "completeOnboarding while signed out") {
                try await bob.profiles.completeOnboarding()
            }
            try await Verify.fails(with: .notAuthenticated, "updateAvatar while signed out") {
                try await bob.profiles.updateAvatar(color: .blue, emoji: nil)
            }
        },
    ]
}

extension TeamGroup {
    /// This group with `other`'s `lastActivityAt` (a group read later may have been bumped since).
    func withLastActivity(of other: TeamGroup) -> TeamGroup {
        var copy = self
        copy.lastActivityAt = other.lastActivityAt
        return copy
    }
}
