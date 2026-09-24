import Foundation
import Supabase
import TeamTasksCore

/// `AuthService` on Supabase Auth (docs/CONTRACTS.md §1, §9).
struct SupabaseAuthService: AuthService {
    let context: SupabaseContext

    private var auth: AuthClient { context.auth }

    /// The current state first (from the locally stored session, `emitLocalSessionAsInitialSession`), then every
    /// change; consecutive duplicates (e.g. a token refresh) are dropped.
    func authStates() -> AsyncStream<AuthState> {
        let (stream, continuation) = AsyncStream.makeStream(of: AuthState.self, bufferingPolicy: .unbounded)
        let auth = auth
        let initial = AuthStateMapping.state(for: auth.currentSession)
        continuation.yield(initial)
        let task = Task {
            var last = initial
            for await (event, session) in auth.authStateChanges {
                guard let state = AuthStateMapping.state(for: event, session: session), state != last else { continue }
                last = state
                continuation.yield(state)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func currentUser() async -> AuthUser? {
        auth.currentSession.map { AuthStateMapping.user($0.user) }
    }

    /// Validates with `InputValidation.signUp` first: Supabase Auth alone accepts a blank or too long name.
    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        let input = try InputValidation.signUp(email: email, password: password, displayName: displayName)
        do {
            let response = try await auth.signUp(
                email: input.email,
                password: password,
                data: ["display_name": .string(input.displayName)]
            )
            return response.session == nil ? .confirmationRequired : .signedIn
        } catch {
            throw SupabaseErrorMapping.auth(error)
        }
    }

    /// No account can have a malformed e-mail or an out-of-range password: such input is refused locally with
    /// `.invalidCredentials`, like the mocks.
    func signIn(email: String, password: String) async throws {
        let normalized = InputValidation.normalizedEmail(email)
        guard (try? InputValidation.email(normalized)) != nil, (try? InputValidation.password(password)) != nil else {
            throw AppError.invalidCredentials
        }
        do {
            try await auth.signIn(email: normalized, password: password)
        } catch {
            throw SupabaseErrorMapping.auth(error, context: .signIn)
        }
    }

    /// Local scope: only this device's session ends. The local session is removed before the server call, so a
    /// failure of that call (network) does not keep the user signed in and is not reported.
    func signOut() async throws {
        do {
            try await auth.signOut(scope: .local)
        } catch {
            if auth.currentSession == nil, !(error is CancellationError) { return }
            throw SupabaseErrorMapping.auth(error)
        }
    }

    /// Unknown e-mails succeed silently (Supabase Auth does not reveal whether an account exists).
    func sendPasswordReset(email: String) async throws {
        let email = try InputValidation.email(email)
        do {
            try await auth.resetPasswordForEmail(email)
        } catch {
            throw SupabaseErrorMapping.auth(error)
        }
    }

    /// A valid code opens a recovery session (the user is signed in).
    func verifyRecoveryCode(email: String, code: String) async throws {
        let email = InputValidation.normalizedEmail(email)
        let code = InputValidation.trimmed(code)
        guard !email.isEmpty, !code.isEmpty else { throw AppError.otpInvalid }
        do {
            try await auth.verifyOTP(email: email, token: code, type: .recovery)
        } catch {
            throw SupabaseErrorMapping.auth(error, context: .verifyOTP)
        }
    }

    /// `422 same_password` (the new password is the current one) is a success: the requested end state holds.
    func updatePassword(_ newPassword: String) async throws {
        guard auth.currentSession != nil else { throw AppError.notAuthenticated }
        try InputValidation.password(newPassword)
        do {
            try await auth.update(user: UserAttributes(password: newPassword))
        } catch let AuthError.api(_, errorCode, _, _) where errorCode == .samePassword {
            return
        } catch {
            throw SupabaseErrorMapping.auth(error)
        }
    }

    /// RPC `delete_my_account`, then local sign-out.
    func deleteAccount() async throws {
        _ = try await context.rest.send { _ in RestQuery.rpc("delete_my_account") }
        try? await auth.signOut(scope: .local)
    }
}

/// Supabase Auth sessions and events → `AuthState`.
enum AuthStateMapping {
    static func user(_ user: User) -> AuthUser {
        AuthUser(id: user.id, email: user.email)
    }

    static func state(for session: Session?) -> AuthState {
        session.map { .signedIn(user($0.user)) } ?? .signedOut
    }

    /// nil for events that do not change the state.
    static func state(for event: AuthChangeEvent, session: Session?) -> AuthState? {
        switch event {
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated, .passwordRecovery, .mfaChallengeVerified:
            return state(for: session)
        case .signedOut, .userDeleted:
            return .signedOut
        }
    }
}
