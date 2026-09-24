import Foundation
import Supabase
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

/// Auth adapter behaviour that needs no server: client-side validation (§1), signed-out state (§9), state mapping.
/// The project URL points to a closed port, so a request that should not happen would fail with `.network`.
@Suite struct AuthUnitTests {
    let auth = UnitBackend.signedOutServices(FakeTransport()).auth

    @Test func signUpValidatesEmailThenPasswordThenDisplayName() async {
        await #expect(throws: AppError.invalidEmail) {
            try await auth.signUp(email: "adresse-invalide", password: "court", displayName: "")
        }
        await #expect(throws: AppError.weakPassword) {
            try await auth.signUp(email: "nouveau@example.com", password: "abc1234", displayName: "")
        }
        await #expect(throws: AppError.invalidInput) {
            try await auth.signUp(email: "nouveau@example.com", password: String(repeating: "é", count: 37), displayName: "Nom")
        }
        await #expect(throws: AppError.invalidDisplayName) {
            try await auth.signUp(email: "nouveau@example.com", password: "motdepasse123", displayName: "   ")
        }
        await #expect(throws: AppError.invalidDisplayName) {
            try await auth.signUp(email: "nouveau@example.com", password: "motdepasse123", displayName: String(repeating: "x", count: 51))
        }
    }

    @Test func impossibleCredentialsAreRefusedLocally() async {
        await #expect(throws: AppError.invalidCredentials) { try await auth.signIn(email: "pas-une-adresse", password: "motdepasse123") }
        await #expect(throws: AppError.invalidCredentials) { try await auth.signIn(email: "camille@example.com", password: "") }
    }

    @Test func recoveryInputIsValidatedLocally() async {
        await #expect(throws: AppError.invalidEmail) { try await auth.sendPasswordReset(email: "  ") }
        await #expect(throws: AppError.otpInvalid) { try await auth.verifyRecoveryCode(email: "camille@example.com", code: "  ") }
    }

    @Test func signedOutState() async {
        #expect(await auth.currentUser() == nil)
        await #expect(throws: AppError.notAuthenticated) { try await auth.updatePassword("motdepasse123") }
        await #expect(throws: Never.self) { try await auth.signOut() }
        var iterator = auth.authStates().makeAsyncIterator()
        #expect(await iterator.next() == .signedOut)
    }

    @Test func authEventsMapToStates() throws {
        let session = try JSONDecoder.supabase().decode(Session.self, from: Data(Self.sessionJSON.utf8))
        let user = AuthUser(id: Seed.camille, email: "camille@example.com")
        #expect(AuthStateMapping.state(for: session) == .signedIn(user))
        #expect(AuthStateMapping.state(for: nil) == .signedOut)
        for event in [AuthChangeEvent.initialSession, .signedIn, .tokenRefreshed, .userUpdated, .passwordRecovery] {
            #expect(AuthStateMapping.state(for: event, session: session) == .signedIn(user))
        }
        #expect(AuthStateMapping.state(for: .initialSession, session: nil) == .signedOut)
        #expect(AuthStateMapping.state(for: .signedOut, session: nil) == .signedOut)
        #expect(AuthStateMapping.state(for: .userDeleted, session: nil) == .signedOut)
    }

    static let sessionJSON = """
    {"access_token":"jeton","token_type":"bearer","expires_in":3600,"expires_at":1790247600,"refresh_token":"rafraichir",\
    "user":{"id":"11111111-1111-4111-8111-111111111111","aud":"authenticated","role":"authenticated",\
    "email":"camille@example.com","app_metadata":{"provider":"email"},"user_metadata":{"display_name":"Camille Martin"},\
    "created_at":"2026-08-24T23:52:26.878215Z","updated_at":"2026-09-24T00:14:27.0787Z","is_anonymous":false}}
    """
}

extension JSONDecoder {
    /// The decoder supabase-swift uses for Auth payloads.
    static func supabase() -> JSONDecoder {
        AuthClient.Configuration.jsonDecoder
    }
}
