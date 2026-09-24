import Foundation
import TeamTasksContract
import TeamTasksCore
import TeamTasksMocks
import Testing

extension IntegrationTests {
    /// Backend-specific Auth checks against the local stack: password recovery by e-mail code (read from Mailpit)
    /// and the seed accounts of docs/CONTRACTS.md §8.
    @Suite struct AuthIntegrationTests {
        @Test(.timeLimit(.minutes(2)), .enabled(if: IntegrationEnvironment.mailpitURL != nil, "MAILPIT_URL is not set"))
        func passwordRecoveryWithTheEmailedCode() async throws {
            let user = try await SupabaseHarness().makeUser(displayName: "Récupération")
            try await user.auth.signOut()
            let device = try IntegrationEnvironment.makeServices()

            await #expect(throws: AppError.invalidEmail) { try await device.auth.sendPasswordReset(email: "pas-une-adresse") }
            // No account enumeration: an unknown e-mail succeeds silently.
            try await device.auth.sendPasswordReset(email: IntegrationEnvironment.uniqueEmail("inconnu"))

            // The e-mail is normalized (trimmed, lowercased) before reaching Auth.
            try await device.auth.sendPasswordReset(email: "  \(user.email.uppercased())  ")
            let code = try await Mailpit.recoveryCode(for: user.email)
            #expect(code.count == 6)

            let wrong = code == "000000" ? "111111" : "000000"
            await #expect(throws: AppError.otpInvalid) { try await device.auth.verifyRecoveryCode(email: user.email, code: wrong) }
            let before = await device.auth.currentUser()
            #expect(before == nil)

            try await device.auth.verifyRecoveryCode(email: " \(user.email.uppercased()) ", code: " \(code) ")
            let recovered = await device.auth.currentUser()
            #expect(recovered?.id == user.id, "a valid code opens a recovery session")

            await #expect(throws: AppError.weakPassword) { try await device.auth.updatePassword("court") }
            let newPassword = "nouveau-motdepasse-2026"
            try await device.auth.updatePassword(newPassword)
            // `422 same_password` is a success: the requested end state holds.
            try await device.auth.updatePassword(newPassword)

            try await device.auth.signOut()
            await #expect(throws: AppError.notAuthenticated) { try await device.auth.updatePassword(newPassword) }
            await #expect(throws: AppError.invalidCredentials) { try await device.auth.signIn(email: user.email, password: user.password) }
            try await device.auth.signIn(email: user.email, password: newPassword)
            let signedIn = await device.auth.currentUser()
            #expect(signedIn?.id == user.id)
            let profile = try await device.profiles.myProfile()
            #expect(profile.displayName == "Récupération")

            // A code works once.
            try await device.auth.signOut()
            await #expect(throws: AppError.otpInvalid) { try await device.auth.verifyRecoveryCode(email: user.email, code: code) }

            // Clean up.
            try await device.auth.signIn(email: user.email, password: newPassword)
            try await device.auth.deleteAccount()
        }

        /// The accounts of `supabase/seed.sql` sign in with the demo password (read-only checks: other tests may
        /// have added data, never removed any).
        @Test(.timeLimit(.minutes(1)))
        func seedUsersCanSignIn() async throws {
            for demo in DemoData.users {
                let device = try IntegrationEnvironment.makeServices()
                try await device.auth.signIn(email: " \(demo.email.uppercased()) ", password: DemoData.password)
                let user = await device.auth.currentUser()
                #expect(user == AuthUser(id: demo.id, email: demo.email))
                let profile = try await device.profiles.myProfile()
                #expect(profile == UserProfile(id: demo.id, displayName: demo.displayName))
                await #expect(throws: AppError.invalidCredentials) {
                    try await IntegrationEnvironment.makeServices().auth.signIn(email: demo.email, password: "mauvais-mot-de-passe")
                }
                try await device.auth.signOut()
            }

            let camille = try IntegrationEnvironment.makeServices()
            try await camille.auth.signIn(email: DemoData.camille.email, password: DemoData.password)
            let groups = try await camille.groups.myGroups()
            let lilas = try #require(groups.first { $0.id == DemoData.lilasGroupId })
            #expect(lilas.group.name == DemoData.lilasGroupName)
            #expect(lilas.myRole == .admin)
            let sport = try #require(groups.first { $0.id == DemoData.sportGroupId })
            #expect(sport.group.name == DemoData.sportGroupName)
            #expect(sport.myRole == .member)

            let tasks = try await camille.tasks.tasks(groupId: DemoData.lilasGroupId, includeOldDone: true)
            let seeded: Set<UUID> = [
                DemoData.TaskIDs.sortirPoubelles, DemoData.TaskIDs.faireCourses, DemoData.TaskIDs.payerLoyer,
                DemoData.TaskIDs.reparerFuite, DemoData.TaskIDs.nettoyerCuisine,
            ]
            #expect(seeded.isSubset(of: Set(tasks.map(\.id))))
            let members = try await camille.groups.members(groupId: DemoData.lilasGroupId)
            #expect(members.first?.user.id == DemoData.camille.id, "the admin comes first")
            try await camille.auth.signOut()
        }
    }
}
