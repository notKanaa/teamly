import Foundation
import Observation

/// What the root view shows.
public enum AppPhase: Sendable, Equatable {
    /// The stored session is being restored, or (v2) the reads deciding the onboarding are running (splash screen).
    case launching
    /// Authentication screens (login, sign-up, « Mot de passe oublié »).
    case signedOut
    /// The signed-in app (tabs) for this session.
    case signedIn(SessionModel)
    /// A recovery code was verified (the user is technically signed in) but the new password is not set yet:
    /// show this view model's « Nouveau mot de passe » step, full screen.
    case passwordRecovery(PasswordResetViewModel)
    /// v2: the onboarding of a new account (docs/CONTRACTS-V2.md §9), full screen, with the session already running.
    /// When it ends, the phase becomes `.signedIn` with the same session.
    case onboarding(OnboardingViewModel)

    public static func == (lhs: AppPhase, rhs: AppPhase) -> Bool {
        switch (lhs, rhs) {
        case (.launching, .launching), (.signedOut, .signedOut): true
        case let (.signedIn(left), .signedIn(right)): left === right
        case let (.passwordRecovery(left), .passwordRecovery(right)): left === right
        case let (.onboarding(left), .onboarding(right)): left === right
        default: false
        }
    }

    /// The running session: in the tabs and (v2) during the onboarding.
    public var session: SessionModel? {
        switch self {
        case let .signedIn(session): session
        case let .onboarding(model): model.session
        case .launching, .signedOut, .passwordRecovery: nil
        }
    }
}

/// Root model of the app: follows `AuthService.authStates()` and owns ONE `SessionModel` per signed-in user
/// (created and started on sign-in, stopped on sign-out or user change, docs/CONTRACTS.md §7).
///
/// v2: a signed-in user goes to `.onboarding` instead of the tabs when `OnboardingPolicy.shouldShow(profile:now:)`
/// holds (docs/CONTRACTS-V2.md §9): a new account. The profile is read once the session has started (splash
/// meanwhile), at most `SessionModel.Configuration.onboardingCheckTimeout`: a failed or slow read opens the tabs, and
/// the onboarding is proposed again at the next session. Once the onboarding is known to be done, skipped or not due,
/// this device remembers it (`OnboardingStore`) and opens the tabs without any read.
///
/// Views: `.task { appModel.start() }` on the root view, `switch appModel.phase`, and forward app events to
/// `handleForeground()`, `handleBackgroundRefresh()`, `open(url:)` / `router.open(_:)`.
@MainActor
@Observable
public final class AppModel {
    public let services: AppServices
    public let platform: PlatformServices
    /// Navigation of the signed-in app (kept across sessions: deep links received while signed out wait in it).
    public let router: Router
    public private(set) var phase: AppPhase = .launching
    /// True from the verification of a recovery code until the new password is set (or the recovery is
    /// abandoned). While true, a signed-in auth state shows `.passwordRecovery` instead of the app.
    public private(set) var isInPasswordRecovery = false
    /// The « Mot de passe oublié » flow presented from the signed-out screens (`.sheet(item: $appModel.passwordReset)`).
    public var passwordReset: PasswordResetViewModel?

    private let sessionConfiguration: SessionModel.Configuration
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var transitionTail: Task<Void, Never>?
    @ObservationIgnored private var latestAuthState: AuthState = .unknown
    @ObservationIgnored private var activeSession: SessionModel?
    /// The flow whose recovery code was verified (kept even if the sheet binding clears `passwordReset`).
    @ObservationIgnored private var recoveryModel: PasswordResetViewModel?

    public init(
        services: AppServices,
        platform: PlatformServices,
        router: Router = Router(),
        sessionConfiguration: SessionModel.Configuration = SessionModel.Configuration()
    ) {
        self.services = services
        self.platform = platform
        self.router = router
        self.sessionConfiguration = sessionConfiguration
    }

    /// The signed-in session (tabs or onboarding), nil in the other phases.
    public var session: SessionModel? { phase.session }

    /// v2: the onboarding shown, nil in the other phases.
    public var onboarding: OnboardingViewModel? {
        if case let .onboarding(model) = phase { return model }
        return nil
    }

    // MARK: - Lifecycle

    /// Starts following the auth state (idempotent; call from the root view's `.task`). The first state
    /// resolves `launching`.
    public func start() {
        guard authTask == nil else { return }
        let states = services.auth.authStates()
        authTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await self.serialized { [weak self] in
                    await self?.apply(state)
                }
            }
        }
    }

    /// Stops following the auth state and ends the session (tests, previews).
    public func shutdown() async {
        authTask?.cancel()
        authTask = nil
        await serialized { [weak self] in
            await self?.endSession(then: .signedOut)
        }
    }

    // MARK: - App events

    /// Scene became active: reload every screen, catch up on assignments, synchronize reminders.
    public func handleForeground() async {
        await activeSession?.handleForeground()
    }

    /// Background App Refresh (`.backgroundTask(.appRefresh(…))`). Works even when the app was launched in
    /// the background and no view ran `start()`: the stored session is restored first.
    public func handleBackgroundRefresh() async {
        start()
        if activeSession == nil, phase == .launching, !isInPasswordRecovery,
           let user = await services.auth.currentUser() {
            await serialized { [weak self] in
                guard let self, self.activeSession == nil, self.phase == .launching, !self.isInPasswordRecovery else { return }
                self.latestAuthState = .signedIn(user)
                await self.enterSession(for: user)
            }
        }
        await activeSession?.handleBackgroundRefresh()
    }

    /// Significant time change (midnight, time zone, clock): refresh date-dependent content and reminders.
    public func handleSignificantTimeChange() async {
        await activeSession?.handleSignificantTimeChange()
    }

    /// Opens an `equipe://` URL (applied when a session is active). Returns false when it is not ours.
    @discardableResult
    public func open(url: URL) -> Bool {
        router.open(url: url)
    }

    // MARK: - View model factories

    public func makeLoginViewModel(email: String = "") -> LoginViewModel {
        LoginViewModel(services: services, email: email)
    }

    public func makeSignUpViewModel() -> SignUpViewModel {
        SignUpViewModel(services: services)
    }

    /// Starts a « Mot de passe oublié » flow and stores it in `passwordReset` (present it as a sheet).
    @discardableResult
    public func startPasswordReset(email: String = "") -> PasswordResetViewModel {
        let model = PasswordResetViewModel(services: services, email: email, app: self)
        passwordReset = model
        return model
    }

    // MARK: - Password recovery (called by PasswordResetViewModel)

    /// Called right before verifying a recovery code: the sign-in that follows must not open the app.
    func beginPasswordRecovery(_ model: PasswordResetViewModel) {
        isInPasswordRecovery = true
        recoveryModel = model
    }

    /// The code was refused: back to normal.
    func cancelPasswordRecovery() async {
        guard isInPasswordRecovery else { return }
        isInPasswordRecovery = false
        recoveryModel = nil
        await reapplyLatestState()
    }

    /// The new password is set: open the app.
    func finishPasswordRecovery() async {
        isInPasswordRecovery = false
        recoveryModel = nil
        passwordReset = nil
        await reapplyLatestState()
    }

    /// The user gave up at the « Nouveau mot de passe » step: sign out (local) and back to the login screen.
    func abandonPasswordRecovery() async {
        try? await services.auth.signOut()
        isInPasswordRecovery = false
        recoveryModel = nil
        passwordReset = nil
        await reapplyLatestState()
    }

    // MARK: - Transitions

    /// Runs auth transitions one at a time, in order (they await the previous session's teardown).
    private func serialized(_ body: @escaping @MainActor @Sendable () async -> Void) async {
        let previous = transitionTail
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        transitionTail = task
        await task.value
    }

    private func reapplyLatestState() async {
        await serialized { [weak self] in
            guard let self else { return }
            await self.apply(self.latestAuthState)
        }
    }

    private func apply(_ state: AuthState) async {
        latestAuthState = state
        switch state {
        case .unknown:
            // Not restored yet: stay on the splash screen; never undo a resolved state.
            break
        case .signedOut:
            if isInPasswordRecovery, let recoveryModel, case .passwordRecovery = phase {
                // The recovery session ended by itself (revoked, refresh refused): the new password can no longer
                // be set. The flow starts over at the e-mail step, with an explanation, instead of reopening on
                // a dead session.
                isInPasswordRecovery = false
                self.recoveryModel = nil
                recoveryModel.recoverySessionEnded()
                passwordReset = recoveryModel
            }
            await endSession(then: .signedOut)
        case let .signedIn(user):
            await enterSession(for: user)
        }
    }

    private func enterSession(for user: AuthUser) async {
        if let current = activeSession, current.userId == user.id {
            current.update(user: user)
            // The same user again (e.g. a refreshed session): an onboarding in progress stays.
            if case let .onboarding(model) = phase, model.session === current { return }
            phase = .signedIn(current)
            return
        }
        if activeSession != nil {
            await endSession(then: .launching)
        }
        if isInPasswordRecovery, let recoveryModel {
            phase = .passwordRecovery(recoveryModel)
            return
        }
        let session = SessionModel(user: user, services: services, platform: platform, configuration: sessionConfiguration)
        activeSession = session
        session.start()
        router.activate()
        let onboarding = await onboardingIfDue(for: session)
        guard activeSession === session else { return }
        if let onboarding {
            phase = .onboarding(onboarding)
        } else {
            phase = .signedIn(session)
        }
    }

    // MARK: - Onboarding (v2)

    /// What the reads say about the onboarding.
    private enum OnboardingDecision: Sendable {
        /// Done, or never to be shown (account too old): remembered on this device.
        case notDue
        case due(profile: UserProfile, hasGroups: Bool, notifications: NotificationAuthorization)
    }

    /// The onboarding to show before the tabs, nil when it is not due or cannot be decided in time
    /// (docs/CONTRACTS-V2.md §9). Reads the profile, then, when the onboarding is due, the groups (« Premier groupe »
    /// is skipped with a group) and the permission (the notifications step is skipped once decided), all within
    /// `onboardingCheckTimeout`. Without any read once this device knows the answer (`OnboardingStore`).
    private func onboardingIfDue(for session: SessionModel) async -> OnboardingViewModel? {
        let store = platform.store
        let userId = session.userId
        if OnboardingStore.hasPendingCompletion(userId: userId, in: store) {
            retryOnboardingCompletion(userId: userId)
        }
        guard !OnboardingStore.isSettled(userId: userId, in: store) else { return nil }
        if phase != .launching { phase = .launching }
        let profiles = services.profiles
        let groups = services.groups
        let notifications = platform.notifications
        let now = platform.now
        let decision = await Self.firstResult(within: sessionConfiguration.onboardingCheckTimeout) {
            let profile = try await profiles.myProfile()
            guard OnboardingPolicy.shouldShow(profile: profile, now: now()) else { return OnboardingDecision.notDue }
            let hasGroups = !((try? await groups.myGroups()) ?? []).isEmpty
            let status = await notifications.authorizationStatus()
            return OnboardingDecision.due(profile: profile, hasGroups: hasGroups, notifications: status)
        }
        switch decision {
        case .notDue?:
            OnboardingStore.markSettled(userId: userId, in: store)
            return nil
        case let .due(profile, hasGroups, status)?:
            return OnboardingViewModel(session: session, profile: profile, hasGroups: hasGroups, notifications: status, app: self)
        case nil:
            // Failed or too slow: the tabs now, the onboarding again at the next session.
            return nil
        }
    }

    /// The onboarding ended (`OnboardingViewModel`): the tabs of the same session.
    func onboardingDidFinish(_ model: OnboardingViewModel) {
        guard case let .onboarding(current) = phase, current === model else { return }
        phase = .signedIn(model.session)
    }

    /// Tells the server again that the onboarding ended (the previous call failed), in the background.
    private func retryOnboardingCompletion(userId: UUID) {
        let profiles = services.profiles
        let store = platform.store
        Task {
            do {
                try await profiles.completeOnboarding()
                OnboardingStore.setPendingCompletion(false, userId: userId, in: store)
            } catch {
                // Still pending: tried again at the next session.
            }
        }
    }

    /// The result of `operation`, or nil when it throws or has not finished after `timeout`: the caller never waits
    /// longer. A late result is dropped and the operation is cancelled.
    static func firstResult<Value: Sendable>(
        within timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        let race = FirstResultRace<Value>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            race.start(continuation, timeout: timeout, operation: operation)
        }
    }

    /// Switches the UI first, then tears the previous session down (awaited, so that the next session never
    /// overlaps it).
    private func endSession(then nextPhase: AppPhase) async {
        let ending = activeSession
        activeSession = nil
        phase = nextPhase
        if ending != nil {
            router.deactivate()
        }
        await ending?.stop()
    }
}

/// The two contenders of `AppModel.firstResult(within:_:)`, the operation and the timer: the first to end resumes the
/// caller and cancels the other.
final class FirstResultRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var tasks: [Task<Void, Never>] = []

    func start(
        _ continuation: CheckedContinuation<Value?, Never>,
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        lock.withLock { self.continuation = continuation }
        let work = Task {
            let value = try? await operation()
            self.finish(with: value)
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self.finish(with: nil)
        }
        let isOver = lock.withLock { () -> Bool in
            tasks = [work, timer]
            return self.continuation == nil
        }
        if isOver {
            work.cancel()
            timer.cancel()
        }
    }

    private func finish(with value: Value?) {
        let (continuation, tasks) = lock.withLock { () -> (CheckedContinuation<Value?, Never>?, [Task<Void, Never>]) in
            let pending = (self.continuation, self.tasks)
            self.continuation = nil
            return pending
        }
        guard let continuation else { return }
        for task in tasks {
            task.cancel()
        }
        continuation.resume(returning: value)
    }
}
