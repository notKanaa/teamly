package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AuthState
import io.github.notkanaa.equipe.core.SignUpOutcome
import io.github.notkanaa.equipe.core.UserProfile

// Auth and profiles (docs/CONTRACTS.md §1, §4.3). Password recovery needs the e-mail content, so it is covered by
// backend-specific tests (mock code / Mailpit), not here.

// Sign-up input is validated with `InputValidation.signUp` before calling Auth (Supabase Auth alone accepts a blank or
// 51-character display name and would create the account).
internal val authScenarios: List<ContractScenario> = listOf(
    ContractScenario("auth.signOutAndSignIn") { harness ->
        val alice = harness.user("Alice")
        val current = alice.auth.currentUser()
        Verify.equal(current?.id, alice.id, "currentUser after sign-up")

        Verify.step("signOut") { alice.auth.signOut() }
        val afterSignOut = alice.auth.currentUser()
        Verify.that(afterSignOut == null, "currentUser must be null after signOut, got $afterSignOut")
        Verify.fails(AppError.NotAuthenticated, "myGroups while signed out") { alice.groups.myGroups() }
        Verify.fails(AppError.NotAuthenticated, "myProfile while signed out") { alice.profiles.myProfile() }
        // An RPC called without a session (PostgREST answers HTTP 401 / 42501): still NotAuthenticated.
        Verify.fails(AppError.NotAuthenticated, "createGroup while signed out") {
            alice.groups.createGroup(Unique.name("Groupe"))
        }

        Verify.fails(AppError.InvalidCredentials, "signIn with a wrong password") {
            alice.auth.signIn(alice.email, alice.password + "!")
        }
        Verify.fails(AppError.InvalidCredentials, "signIn with an unknown e-mail") {
            alice.auth.signIn(Unique.email(alice.email), alice.password)
        }
        Verify.step("signIn with the right credentials") { alice.auth.signIn(alice.email, alice.password) }
        val back = alice.auth.currentUser()
        Verify.equal(back?.id, alice.id, "currentUser after signIn")
        val profile = alice.profiles.myProfile()
        Verify.equal(profile.displayName, alice.displayName, "display name after signIn")
    },

    ContractScenario("auth.authStatesStream") { harness ->
        val alice = harness.user("Alice")
        StreamProbe(alice.auth.authStates()).use { probe ->
            val first = probe.waitFor("first auth state") { true }
            Verify.that(
                first.value == AuthState.Unknown || first.value.user?.id == alice.id,
                "authStates must start with the current state (or Unknown while restoring), got ${first.value}",
            )
            probe.waitFor("signed-in state") { it.user?.id == alice.id }

            val beforeSignOut = probe.mark()
            alice.auth.signOut()
            probe.waitFor("SignedOut after signOut", after = beforeSignOut) { it == AuthState.SignedOut }

            val beforeSignIn = probe.mark()
            alice.auth.signIn(alice.email, alice.password)
            probe.waitFor("SignedIn after signIn", after = beforeSignIn) { it.user?.id == alice.id }
        }
    },

    ContractScenario("auth.signUpValidation") { harness ->
        val alice = harness.user("Alice")
        alice.auth.signOut()
        val fresh = Unique.email(alice.email)
        Verify.fails(AppError.InvalidEmail, "malformed e-mail") {
            alice.auth.signUp("adresse-invalide", alice.password, "Nom")
        }
        Verify.fails(AppError.WeakPassword, "7-character password") {
            alice.auth.signUp(fresh, "abc1234", "Nom")
        }
        Verify.fails(AppError.InvalidDisplayName, "blank display name") {
            alice.auth.signUp(fresh, alice.password, "   ")
        }
        Verify.fails(AppError.InvalidDisplayName, "51-character display name") {
            alice.auth.signUp(fresh, alice.password, Fixed.text(51))
        }
        Verify.fails(AppError.EmailAlreadyUsed, "already registered e-mail") {
            alice.auth.signUp(alice.email, alice.password, "Nom")
        }
        val current = alice.auth.currentUser()
        Verify.that(current == null, "failed sign-ups must not open a session, got $current")
        Verify.fails(AppError.InvalidCredentials, "failed sign-ups must not create the account") {
            alice.auth.signIn(fresh, alice.password)
        }
    },

    ContractScenario("auth.signUpOpensSession") { harness ->
        val alice = harness.user("Alice")
        val fresh = Unique.email(alice.email)
        val name = Unique.name("Nouveau")
        val outcome = Verify.step("signUp with a fresh e-mail") {
            alice.auth.signUp(fresh, alice.password, "  $name  ")
        }
        Verify.equal(outcome, SignUpOutcome.SIGNED_IN, "sign-up outcome (e-mail confirmation disabled)")
        val created = alice.auth.currentUser()
        val user = Verify.unwrap(created, "currentUser after sign-up")
        Verify.that(user.id != alice.id, "sign-up must open a session for the new account")
        Verify.equal(user.email?.lowercase(), fresh.lowercase(), "e-mail of the new account")
        val profile = alice.profiles.myProfile()
        Verify.equal(profile, UserProfile(user.id, name), "profile created with the trimmed name")
        val groups = alice.groups.myGroups()
        Verify.that(groups.isEmpty(), "a new account belongs to no group, got $groups")

        // The account works with its credentials; then clean it up.
        alice.auth.signOut()
        Verify.step("signIn to the new account") { alice.auth.signIn(fresh, alice.password) }
        val again = alice.auth.currentUser()
        Verify.equal(again?.id, user.id, "signed back in to the new account")
        Verify.step("delete the new account") { alice.auth.deleteAccount() }
    },
)

internal val profileScenarios: List<ContractScenario> = listOf(
    ContractScenario("profile.readAndRename") { harness ->
        val alice = harness.user("Alice")
        val profile = alice.profiles.myProfile()
        Verify.equal(profile, UserProfile(alice.id, alice.displayName), "initial profile")

        val newName = Unique.name("Renommée")
        val updated = alice.profiles.updateDisplayName("  $newName  ")
        Verify.equal(updated, UserProfile(alice.id, newName), "updated profile (trimmed)")
        val reread = alice.profiles.myProfile()
        Verify.equal(reread, updated, "profile after update")

        for (invalid in listOf("", "   ", Fixed.text(51), "Ali\u0000ce")) {
            Verify.fails(AppError.InvalidDisplayName, "display name ${debugDescription(invalid)}") {
                alice.profiles.updateDisplayName(invalid)
            }
        }
        val unchanged = alice.profiles.myProfile()
        Verify.equal(unchanged, updated, "profile unchanged after invalid updates")

        val longest = Fixed.text(50)
        val accepted = alice.profiles.updateDisplayName(longest)
        Verify.equal(accepted.displayName, longest, "50-character display name accepted")
    },

    ContractScenario("profile.coMembersSeeNewName") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        val newName = Unique.name("Robert")
        bob.profiles.updateDisplayName(newName)
        val members = alice.groups.members(group.id)
        Verify.equal(
            members.firstOrNull { it.user.id == bob.id }?.user?.displayName, newName,
            "a co-member sees the new display name",
        )
    },
)
