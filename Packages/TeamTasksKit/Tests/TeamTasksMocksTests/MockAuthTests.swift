import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

@Suite struct MockAuthTests {
    /// Supabase Auth (GoTrue) accepts the HTML5 e-mail syntax: ASCII only, domain labels starting and ending with
    /// a letter or digit (probes: `xxxxx@-example.com`, `xxxxx@example..com`, `üxxxxx@example.com` → invalid format).
    @Test(arguments: [
        "", "   ", "camille", "camille@", "@example.com", "cam ille@example.com", "camille@.fr", "a@b@c.fr",
        "üxxxxx@example.com", "xxxxx@-example.com", "xxxxx@example-.com", "xxxxx@example..com", "xxxxx@example.com.",
        "camille@exämple.com",
    ])
    func signUpRejectsMalformedEmails(email: String) async {
        let services = InMemoryBackend().services(for: nil)
        await #expect(throws: AppError.invalidEmail) {
            try await services.auth.signUp(email: email, password: "motdepasse123", displayName: "Nom")
        }
    }

    /// Accepted by GoTrue (probes), so accepted by the mock too.
    @Test(arguments: ["user@localhost", ".xxxxx@example.com", "a..xxxxx@example.com", "camille@example", "o'neil+tag@sub-domain.example.fr"])
    func signUpAcceptsWhatSupabaseAuthAccepts(email: String) async throws {
        let services = InMemoryBackend().services(for: nil)
        #expect(try await services.auth.signUp(email: email, password: "motdepasse123", displayName: "Nom") == .signedIn)
        #expect(await services.auth.currentUser()?.email == email.lowercased())
    }

    /// GoTrue measures passwords in UTF-8 bytes: at least 8 (`minimum_password_length`), at most 72 (bcrypt).
    @Test func passwordLengthIsCountedInBytes() async throws {
        let backend = InMemoryBackend()
        let services = backend.services(for: nil)
        #expect(try await services.auth.signUp(email: "octets@example.com", password: "éééé", displayName: "Octets") == .signedIn)
        #expect(try await backend.services(for: nil).auth.signUp(email: "emoji@example.com", password: "😀😀", displayName: "Emoji") == .signedIn)
        await #expect(throws: AppError.weakPassword) {
            try await backend.services(for: nil).auth.signUp(email: "court@example.com", password: "ééé1", displayName: "Court")
        }
        let longest = String(repeating: "a", count: 72)
        #expect(try await backend.services(for: nil).auth.signUp(email: "long@example.com", password: longest, displayName: "Long") == .signedIn)
        await #expect(throws: AppError.invalidInput) {
            try await backend.services(for: nil).auth.signUp(email: "trop@example.com", password: longest + "a", displayName: "Trop")
        }
        await #expect(throws: AppError.invalidInput) {
            try await services.auth.updatePassword(String(repeating: "é", count: 37))
        }
        try await services.auth.updatePassword(String(repeating: "é", count: 36))
    }

    @Test func signUpValidation() async throws {
        let backend = InMemoryBackend.demo()
        let services = backend.services(for: nil)
        await #expect(throws: AppError.weakPassword) {
            try await services.auth.signUp(email: "nouveau@example.com", password: "1234567", displayName: "Nom")
        }
        await #expect(throws: AppError.invalidDisplayName) {
            try await services.auth.signUp(email: "nouveau@example.com", password: "motdepasse123", displayName: " \n ")
        }
        await #expect(throws: AppError.invalidDisplayName) {
            try await services.auth.signUp(email: "nouveau@example.com", password: "motdepasse123", displayName: String(repeating: "é", count: 51))
        }
        // E-mails are case-insensitive and trimmed.
        await #expect(throws: AppError.emailAlreadyUsed) {
            try await services.auth.signUp(email: "  CAMILLE@Example.com ", password: "motdepasse123", displayName: "Nom")
        }
        #expect(await services.auth.currentUser() == nil)
        #expect(backend.userId(forEmail: "nouveau@example.com") == nil)
    }

    @Test func signUpNormalizesAndOpensTheSession() async throws {
        let services = InMemoryBackend().services(for: nil)
        let outcome = try await services.auth.signUp(
            email: "  Zoe.Leroy@Example.COM ", password: "motdepasse123", displayName: "  Zoé Leroy  "
        )
        #expect(outcome == .signedIn)
        let user = try #require(await services.auth.currentUser())
        #expect(user.email == "zoe.leroy@example.com")
        #expect(try await services.profiles.myProfile() == UserProfile(id: user.id, displayName: "Zoé Leroy"))
        let fiftyAccents = String(repeating: "é", count: 50)
        #expect(try await services.profiles.updateDisplayName(fiftyAccents).displayName == fiftyAccents)
    }

    @Test func signInAndSignOut() async throws {
        let services = InMemoryBackend.demo().services(for: nil)
        await #expect(throws: AppError.invalidCredentials) {
            try await services.auth.signIn(email: DemoData.camille.email, password: "mauvais-mot-de-passe")
        }
        await #expect(throws: AppError.invalidCredentials) {
            try await services.auth.signIn(email: "personne@example.com", password: DemoData.password)
        }
        try await services.auth.signIn(email: " Camille@Example.com ", password: DemoData.password)
        #expect(await services.auth.currentUser()?.id == DemoData.camille.id)
        try await services.auth.signOut()
        #expect(await services.auth.currentUser() == nil)
        try await services.auth.signOut() // idempotent
        await #expect(throws: AppError.notAuthenticated) { try await services.profiles.myProfile() }
        await #expect(throws: AppError.notAuthenticated) { try await services.groups.createGroup(name: "Groupe") }
        await #expect(throws: AppError.notAuthenticated) { try await services.push.enable() }
        await #expect(throws: AppError.notAuthenticated) { try await services.auth.updatePassword("nouveau-mdp") }
        await #expect(throws: AppError.notAuthenticated) { try await services.auth.deleteAccount() }
    }

    @Test func authStatesEmitsTheCurrentStateThenChanges() async throws {
        let services = InMemoryBackend.demo().services(for: nil)
        var first = services.auth.authStates().makeAsyncIterator()
        #expect(await first.next() == .signedOut)
        try await services.auth.signIn(email: DemoData.lucas.email, password: DemoData.password)
        let lucas = AuthUser(id: DemoData.lucas.id, email: DemoData.lucas.email)
        #expect(await first.next() == .signedIn(lucas))

        // A late subscriber starts with the current state.
        var second = services.auth.authStates().makeAsyncIterator()
        #expect(await second.next() == .signedIn(lucas))

        try await services.auth.signOut()
        #expect(await first.next() == .signedOut)
        #expect(await second.next() == .signedOut)
        // Signing in again as the same user after sign-out is a change; a repeated sign-out is not.
        try await services.auth.signOut()
        try await services.auth.signIn(email: DemoData.lucas.email, password: DemoData.password)
        #expect(await first.next() == .signedIn(lucas))
    }

    @Test func passwordRecoveryWithTheDeterministicCode() async throws {
        let clock = MockClock(Date(timeIntervalSince1970: 1_790_150_400))
        let backend = InMemoryBackend.demo(now: clock.provider)
        let services = backend.services(for: nil)
        let email = DemoData.ines.email

        await #expect(throws: AppError.invalidEmail) { try await services.auth.sendPasswordReset(email: "pas-un-email") }
        try await services.auth.sendPasswordReset(email: "inconnu@example.com") // no account enumeration
        #expect(backend.pendingRecoveryCode(email: "inconnu@example.com") == nil)
        await #expect(throws: AppError.otpInvalid) {
            try await services.auth.verifyRecoveryCode(email: email, code: InMemoryBackend.recoveryCode)
        }

        try await services.auth.sendPasswordReset(email: email)
        #expect(backend.pendingRecoveryCode(email: email) == "123456")
        #expect(InMemoryBackend.recoveryCode == "123456")
        await #expect(throws: AppError.otpInvalid) { try await services.auth.verifyRecoveryCode(email: email, code: "654321") }
        #expect(await services.auth.currentUser() == nil)

        try await services.auth.verifyRecoveryCode(email: email, code: " 123456 ")
        #expect(await services.auth.currentUser()?.id == DemoData.ines.id)
        #expect(backend.pendingRecoveryCode(email: email) == nil) // consumed
        await #expect(throws: AppError.weakPassword) { try await services.auth.updatePassword("court") }
        try await services.auth.updatePassword("nouveau-mot-de-passe")
        try await services.auth.signOut()

        await #expect(throws: AppError.invalidCredentials) {
            try await services.auth.signIn(email: email, password: DemoData.password)
        }
        try await services.auth.signIn(email: email, password: "nouveau-mot-de-passe")
        #expect(await services.auth.currentUser()?.id == DemoData.ines.id)
    }

    @Test func recoveryCodesExpireAfterAnHour() async throws {
        let clock = MockClock(Date(timeIntervalSince1970: 1_790_150_400))
        let backend = InMemoryBackend.demo(now: clock.provider)
        let services = backend.services(for: nil)
        try await services.auth.sendPasswordReset(email: DemoData.lucas.email)
        clock.advance(by: InMemoryBackend.recoveryCodeLifetime + 1)
        await #expect(throws: AppError.otpInvalid) {
            try await services.auth.verifyRecoveryCode(email: DemoData.lucas.email, code: InMemoryBackend.recoveryCode)
        }
        try await services.auth.sendPasswordReset(email: DemoData.lucas.email)
        clock.advance(by: InMemoryBackend.recoveryCodeLifetime)
        try await services.auth.verifyRecoveryCode(email: DemoData.lucas.email, code: InMemoryBackend.recoveryCode)
        #expect(await services.auth.currentUser()?.id == DemoData.lucas.id)
    }

    @Test func deleteAccountSignsOutEveryWhere() async throws {
        let backend = InMemoryBackend.demo()
        let phone = backend.services(for: DemoData.ines.id)
        let tablet = backend.services(for: DemoData.ines.id)
        var states = phone.auth.authStates().makeAsyncIterator()
        #expect(await states.next()?.user?.id == DemoData.ines.id)

        try await phone.auth.deleteAccount()
        #expect(await states.next() == .signedOut)
        #expect(await phone.auth.currentUser() == nil)
        #expect(await tablet.auth.currentUser() == nil)
        await #expect(throws: AppError.notAuthenticated) { try await tablet.groups.myGroups() }
        #expect(backend.userId(forEmail: DemoData.ines.email) == nil)

        // The e-mail can be registered again.
        let outcome = try await phone.auth.signUp(email: DemoData.ines.email, password: DemoData.password, displayName: "Inès")
        #expect(outcome == .signedIn)
        #expect(try await phone.groups.myGroups().isEmpty)
    }
}
