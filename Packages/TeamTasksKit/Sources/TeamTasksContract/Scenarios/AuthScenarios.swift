import Foundation
import TeamTasksCore

// Auth and profiles (docs/CONTRACTS.md §1, §4.3). Password recovery needs the e-mail content, so it is
// covered by backend-specific tests (mock code / Mailpit), not here.
extension ContractScenarios {
    static let authScenarios: [ContractScenario] = [
        ContractScenario("auth.signOutAndSignIn") { harness in
            let alice = try await harness.user("Alice")
            let current = await alice.auth.currentUser()
            try Verify.equal(current?.id, alice.id, "currentUser after sign-up")

            try await Verify.step("signOut") { try await alice.auth.signOut() }
            let afterSignOut = await alice.auth.currentUser()
            try Verify.that(afterSignOut == nil, "currentUser must be nil after signOut, got \(String(describing: afterSignOut))")
            try await Verify.fails(with: .notAuthenticated, "myGroups while signed out") {
                try await alice.groups.myGroups()
            }
            try await Verify.fails(with: .notAuthenticated, "myProfile while signed out") {
                try await alice.profiles.myProfile()
            }
            // An RPC called without a session: our own error or PostgREST's permission error.
            try await Verify.fails(withAnyOf: [.notAuthenticated, .forbidden], "createGroup while signed out") {
                try await alice.groups.createGroup(name: Unique.name("Groupe"))
            }

            try await Verify.fails(with: .invalidCredentials, "signIn with a wrong password") {
                try await alice.auth.signIn(email: alice.email, password: alice.password + "!")
            }
            try await Verify.fails(with: .invalidCredentials, "signIn with an unknown e-mail") {
                try await alice.auth.signIn(email: Unique.email(like: alice.email), password: alice.password)
            }
            try await Verify.step("signIn with the right credentials") {
                try await alice.auth.signIn(email: alice.email, password: alice.password)
            }
            let back = await alice.auth.currentUser()
            try Verify.equal(back?.id, alice.id, "currentUser after signIn")
            let profile = try await alice.profiles.myProfile()
            try Verify.equal(profile.displayName, alice.displayName, "display name after signIn")
        },

        ContractScenario("auth.authStatesStream") { harness in
            let alice = try await harness.user("Alice")
            let probe = StreamProbe(alice.auth.authStates())
            defer { probe.stop() }
            let first = try await probe.waitFor("first auth state") { _ in true }
            try Verify.that(
                first.element == .unknown || first.element.user?.id == alice.id,
                "authStates must start with the current state (or .unknown while restoring), got \(first.element)"
            )
            try await probe.waitFor("signed-in state") { $0.user?.id == alice.id }

            let beforeSignOut = probe.mark()
            try await alice.auth.signOut()
            try await probe.waitFor(".signedOut after signOut", after: beforeSignOut) { $0 == .signedOut }

            let beforeSignIn = probe.mark()
            try await alice.auth.signIn(email: alice.email, password: alice.password)
            try await probe.waitFor(".signedIn after signIn", after: beforeSignIn) { $0.user?.id == alice.id }
        },

        ContractScenario("auth.signUpValidation") { harness in
            let alice = try await harness.user("Alice")
            try await alice.auth.signOut()
            let fresh = Unique.email(like: alice.email)
            try await Verify.fails(with: .invalidEmail, "malformed e-mail") {
                try await alice.auth.signUp(email: "adresse-invalide", password: alice.password, displayName: "Nom")
            }
            try await Verify.fails(with: .weakPassword, "7-character password") {
                try await alice.auth.signUp(email: fresh, password: "abc1234", displayName: "Nom")
            }
            try await Verify.fails(with: .invalidDisplayName, "blank display name") {
                try await alice.auth.signUp(email: fresh, password: alice.password, displayName: "   ")
            }
            try await Verify.fails(with: .invalidDisplayName, "51-character display name") {
                try await alice.auth.signUp(email: fresh, password: alice.password, displayName: Fixed.text(51))
            }
            try await Verify.fails(with: .emailAlreadyUsed, "already registered e-mail") {
                try await alice.auth.signUp(email: alice.email, password: alice.password, displayName: "Nom")
            }
            let current = await alice.auth.currentUser()
            try Verify.that(current == nil, "failed sign-ups must not open a session, got \(String(describing: current))")
            try await Verify.fails(with: .invalidCredentials, "failed sign-ups must not create the account") {
                try await alice.auth.signIn(email: fresh, password: alice.password)
            }
        },

        ContractScenario("auth.signUpOpensSession") { harness in
            let alice = try await harness.user("Alice")
            let fresh = Unique.email(like: alice.email)
            let name = Unique.name("Nouveau")
            let outcome = try await Verify.step("signUp with a fresh e-mail") {
                try await alice.auth.signUp(email: fresh, password: alice.password, displayName: "  \(name)  ")
            }
            try Verify.equal(outcome, .signedIn, "sign-up outcome (e-mail confirmation disabled)")
            let created = await alice.auth.currentUser()
            let user = try Verify.unwrap(created, "currentUser after sign-up")
            try Verify.that(user.id != alice.id, "sign-up must open a session for the new account")
            try Verify.equal(user.email?.lowercased(), fresh.lowercased(), "e-mail of the new account")
            let profile = try await alice.profiles.myProfile()
            try Verify.equal(profile, UserProfile(id: user.id, displayName: name), "profile created with the trimmed name")
            let groups = try await alice.groups.myGroups()
            try Verify.that(groups.isEmpty, "a new account belongs to no group, got \(groups)")

            // The account works with its credentials; then clean it up.
            try await alice.auth.signOut()
            try await Verify.step("signIn to the new account") {
                try await alice.auth.signIn(email: fresh, password: alice.password)
            }
            let again = await alice.auth.currentUser()
            try Verify.equal(again?.id, user.id, "signed back in to the new account")
            try await Verify.step("delete the new account") { try await alice.auth.deleteAccount() }
        },
    ]

    static let profileScenarios: [ContractScenario] = [
        ContractScenario("profile.readAndRename") { harness in
            let alice = try await harness.user("Alice")
            let profile = try await alice.profiles.myProfile()
            try Verify.equal(profile, UserProfile(id: alice.id, displayName: alice.displayName), "initial profile")

            let newName = Unique.name("Renommée")
            let updated = try await alice.profiles.updateDisplayName("  \(newName)  ")
            try Verify.equal(updated, UserProfile(id: alice.id, displayName: newName), "updated profile (trimmed)")
            let reread = try await alice.profiles.myProfile()
            try Verify.equal(reread, updated, "profile after update")

            for invalid in ["", "   ", Fixed.text(51)] {
                try await Verify.fails(with: .invalidDisplayName, "display name of \(invalid.count) characters") {
                    try await alice.profiles.updateDisplayName(invalid)
                }
            }
            let unchanged = try await alice.profiles.myProfile()
            try Verify.equal(unchanged, updated, "profile unchanged after invalid updates")

            let longest = Fixed.text(50)
            let accepted = try await alice.profiles.updateDisplayName(longest)
            try Verify.equal(accepted.displayName, longest, "50-character display name accepted")
        },

        ContractScenario("profile.coMembersSeeNewName") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let newName = Unique.name("Robert")
            _ = try await bob.profiles.updateDisplayName(newName)
            let members = try await alice.groups.members(groupId: group.id)
            try Verify.equal(
                members.first { $0.user.id == bob.id }?.user.displayName, newName,
                "a co-member sees the new display name"
            )
        },
    ]
}
