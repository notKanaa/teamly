import Foundation
import Observation

/// What this device remembers about a user's onboarding (`KeyValueStore`, one entry each per user), so that
/// `AppModel` reads the profile to decide at most until the answer is known.
public enum OnboardingStore {
    /// The onboarding was finished or skipped here, or found done or not due: the tabs open without any read.
    public static func settledKey(userId: UUID) -> String {
        "onboarding.settled.\(userId.uuidString)"
    }

    /// The onboarding was finished or skipped, but the server has not confirmed `completeOnboarding()` yet: the next
    /// session tells it again.
    public static func pendingCompletionKey(userId: UUID) -> String {
        "onboarding.pendingCompletion.\(userId.uuidString)"
    }

    public static func isSettled(userId: UUID, in store: any KeyValueStore) -> Bool {
        store.value(Bool.self, forKey: settledKey(userId: userId)) ?? false
    }

    public static func markSettled(userId: UUID, in store: any KeyValueStore) {
        store.setValue(true, forKey: settledKey(userId: userId))
    }

    public static func hasPendingCompletion(userId: UUID, in store: any KeyValueStore) -> Bool {
        store.value(Bool.self, forKey: pendingCompletionKey(userId: userId)) ?? false
    }

    public static func setPendingCompletion(_ pending: Bool, userId: UUID, in store: any KeyValueStore) {
        store.setValue(pending ? true : nil, forKey: pendingCompletionKey(userId: userId))
    }

    /// Forgets the user (account deletion).
    public static func clear(userId: UUID, in store: any KeyValueStore) {
        store.set(nil, forKey: settledKey(userId: userId))
        store.set(nil, forKey: pendingCompletionKey(userId: userId))
    }
}

/// The onboarding of a new account (docs/CONTRACTS-V2.md §9), shown full screen by `AppPhase.onboarding` before the
/// tabs, with the session already running. The steps are those of `OnboardingPolicy.steps(hasGroups:notifications:)`:
/// 1. « Bienvenue » (`welcomeTitle`, `highlights`);
/// 2. the avatar (`avatar`: a color and the initials or an emoji, optional: « Continuer » saves a change);
/// 3. the first group, when the user has none: « Créer » (`createGroup`: name, emoji, color) or « Rejoindre »
///    (`joinGroup`: invite code), with their own field messages; a group created or joined here is not created again
///    when the user comes back to the step;
/// 4. the notifications, when the permission was never asked: « Activer les notifications » asks for it.
///
/// Navigation: `advance()` (the primary button), `skipStep()` (« Plus tard »: the next step without acting),
/// `goBack()`, and `skip()` (« Passer »: ends at once, from any step). Ending (after the last step, or « Passer »)
/// opens the tabs at once and tells the server (`completeOnboarding()`); if that call fails the next session tells it
/// again: an error never keeps the user in the onboarding. A failed step shows `error` (or a field message) and
/// stays; « Plus tard » and « Passer » remain available.
@MainActor
@Observable
public final class OnboardingViewModel: ErrorPresenting, Identifiable {
    /// « Créer » or « Rejoindre », on the first group step.
    public enum FirstGroupMode: String, Sendable, Hashable, CaseIterable, Identifiable {
        case create
        case join

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .create: "Créer"
            case .join: "Rejoindre"
            }
        }
    }

    /// What the first group step did.
    public enum FirstGroupOutcome: Sendable, Hashable {
        case created(GroupSummary)
        case joined(JoinResult)

        public var groupId: UUID {
            switch self {
            case let .created(summary): summary.id
            case let .joined(result): result.groupId
            }
        }

        public var groupName: String {
            switch self {
            case let .created(summary): summary.group.name
            case let .joined(result): result.groupName
            }
        }
    }

    /// One of the three things the welcome step presents.
    public struct Highlight: Sendable, Hashable, Identifiable {
        public var title: String
        public var message: String
        /// SF Symbols name.
        public var systemImage: String

        public init(title: String, message: String, systemImage: String) {
            self.title = title
            self.message = message
            self.systemImage = systemImage
        }

        public var id: String { title }
    }

    public static let skipButtonTitle = "Passer"
    public static let laterButtonTitle = "Plus tard"
    public static let welcomeMessage =
        "Équipe, c’est la liste de tâches de ton groupe. Trois choses à savoir avant de commencer."
    public static let highlights = [
        Highlight(
            title: "À tour de rôle",
            message: "Les corvées passent toutes seules à la personne suivante.",
            systemImage: "arrow.triangle.2.circlepath"
        ),
        Highlight(
            title: "Des checklists",
            message: "Découpe une tâche en étapes et vois où ça en est.",
            systemImage: "checklist"
        ),
        Highlight(
            title: "Le récap de la semaine",
            message: "Qui a fait quoi, avec le podium du groupe.",
            systemImage: "trophy"
        ),
    ]
    public static let avatarTitle = "Choisis ton avatar"
    public static let avatarMessage = "C’est lui que le groupe verra à côté de tes tâches."
    public static let colorSectionTitle = "Couleur"
    public static let symbolSectionTitle = "Symbole"
    public static let emojiSectionTitle = "Emoji"
    public static let firstGroupTitle = "Ton premier groupe"
    public static let firstGroupMessage =
        "Crée celui de ta coloc, de ta famille ou de ton asso. Ou rejoins un groupe avec son code."
    public static let groupNameLabel = "Nom du groupe"
    public static let inviteCodeLabel = "Code d’invitation"
    public static let joinHint = "Demande-le à un admin du groupe\u{00A0}: il le trouve dans Membres."
    public static let notificationsTitle = "Ne rate plus ton tour"
    public static let notificationsMessage =
        "Active les notifications pour savoir quand on te confie une tâche, quand c’est ton tour et quand une échéance approche."

    public nonisolated let id = UUID()
    public let session: SessionModel
    /// The steps shown, in order (never empty).
    public let steps: [OnboardingStep]
    public private(set) var stepIndex = 0
    /// The user's profile (display name of the welcome, avatar).
    public var profile: UserProfile { avatar.profile }
    /// Step 2.
    public let avatar: AvatarEditorViewModel
    /// Step 3: « Créer » or « Rejoindre ».
    public var firstGroupMode = FirstGroupMode.create
    /// Step 3, « Créer ».
    public let createGroup: CreateGroupViewModel
    /// Step 3, « Rejoindre ».
    public let joinGroup: JoinGroupViewModel
    /// The group created or joined at step 3.
    public private(set) var firstGroup: FirstGroupOutcome?
    /// The notification permission (updated by step 4).
    public private(set) var notificationStatus: NotificationAuthorization
    public private(set) var isRequestingNotifications = false
    /// The onboarding ended (finished or skipped): the tabs are shown.
    public private(set) var isFinished = false
    /// Whether the server confirmed the end of the onboarding: nil until it answers (or before the end); false when
    /// the call failed (the next session tells it again).
    public private(set) var isCompletedOnServer: Bool?
    public var error: ErrorState?

    @ObservationIgnored private weak var app: AppModel?

    /// - Parameters:
    ///   - profile: the user's profile, as read by `ProfileService.myProfile()`.
    ///   - hasGroups: the user already belongs to a group (no « Premier groupe » step).
    ///   - notifications: the current permission (no notifications step unless `.notDetermined`).
    ///   - app: told when the onboarding ends, to show the tabs.
    public init(
        session: SessionModel,
        profile: UserProfile,
        hasGroups: Bool,
        notifications: NotificationAuthorization,
        app: AppModel? = nil
    ) {
        self.session = session
        steps = OnboardingPolicy.steps(hasGroups: hasGroups, notifications: notifications)
        avatar = AvatarEditorViewModel(session: session, profile: profile)
        createGroup = CreateGroupViewModel(session: session)
        joinGroup = JoinGroupViewModel(session: session)
        notificationStatus = notifications
        self.app = app
    }

    // MARK: - Progress

    public var step: OnboardingStep { steps[stepIndex] }
    /// 1-based.
    public var stepNumber: Int { stepIndex + 1 }
    public var stepCount: Int { steps.count }
    /// « 2 sur 4 ».
    public var progressText: String { "\(stepNumber) sur \(stepCount)" }
    public var isLastStep: Bool { stepIndex == steps.count - 1 }

    /// A request of the current step is in progress (disable the buttons, show a spinner).
    public var isBusy: Bool {
        avatar.isSaving || createGroup.isSubmitting || joinGroup.isSubmitting || isRequestingNotifications
    }

    public var canGoBack: Bool { stepIndex > 0 && !isBusy && !isFinished }

    // MARK: - Texts of the current step

    /// « Bienvenue, Camille ! ».
    public var welcomeTitle: String {
        let name = FrenchText.firstName(of: profile.displayName)
        return name.isEmpty ? "Bienvenue\u{00A0}!" : "Bienvenue, \(name)\u{00A0}!"
    }

    public var title: String {
        switch step {
        case .welcome: welcomeTitle
        case .avatar: Self.avatarTitle
        case .firstGroup: Self.firstGroupTitle
        case .notifications: Self.notificationsTitle
        }
    }

    public var message: String {
        switch step {
        case .welcome: Self.welcomeMessage
        case .avatar: Self.avatarMessage
        case .firstGroup: Self.firstGroupMessage
        case .notifications: Self.notificationsMessage
        }
    }

    /// « C’est parti », « Continuer », « Créer le groupe » / « Rejoindre le groupe », « Activer les notifications »,
    /// or « Terminer » on a last avatar or group step.
    public var primaryButtonTitle: String {
        switch step {
        case .welcome:
            return "C’est parti"
        case .avatar:
            return isLastStep ? "Terminer" : "Continuer"
        case .firstGroup:
            if firstGroup != nil { return isLastStep ? "Terminer" : "Continuer" }
            return firstGroupMode == .create ? "Créer le groupe" : "Rejoindre le groupe"
        case .notifications:
            return "Activer les notifications"
        }
    }

    /// « Plus tard » (`skipStep()`) on a first group step not done yet and on the notifications step; nil elsewhere.
    public var secondaryButtonTitle: String? {
        switch step {
        case .firstGroup: firstGroup == nil ? Self.laterButtonTitle : nil
        case .notifications: Self.laterButtonTitle
        case .welcome, .avatar: nil
        }
    }

    /// The primary button is enabled.
    public var canAdvance: Bool {
        guard !isFinished, !isBusy else { return false }
        switch step {
        case .welcome, .avatar, .notifications:
            return true
        case .firstGroup:
            if firstGroup != nil { return true }
            return firstGroupMode == .create ? createGroup.canSubmit : joinGroup.canSubmit
        }
    }

    /// Once the first group is done: « Le groupe « X » est créé. », « Tu as rejoint « X ». », « Tu fais déjà partie
    /// de « X ». »
    public var firstGroupDoneMessage: String? {
        guard let firstGroup else { return nil }
        let name = FrenchText.quoted(firstGroup.groupName)
        switch firstGroup {
        case .created:
            return "Le groupe \(name) est créé."
        case let .joined(result):
            return result.alreadyMember ? "Tu fais déjà partie de \(name)." : "Tu as rejoint \(name)."
        }
    }

    // MARK: - Navigation

    /// The previous step.
    public func goBack() {
        guard canGoBack else { return }
        error = nil
        stepIndex -= 1
    }

    /// The primary button: « C’est parti »; « Continuer » (saves a changed avatar); « Créer le groupe » /
    /// « Rejoindre le groupe » (then « Continuer » once done); « Activer les notifications » (asks for the
    /// permission, whatever the answer). Moves to the next step, or ends after the last one.
    /// - Returns: false when the step failed: `error` (or a field message of `createGroup` / `joinGroup`) is shown
    ///   and the user stays on it.
    @discardableResult
    public func advance() async -> Bool {
        guard canAdvance else { return false }
        error = nil
        switch step {
        case .welcome:
            break
        case .avatar:
            guard await avatar.save() else {
                adoptError(of: avatar)
                return false
            }
        case .firstGroup:
            guard await submitFirstGroup() else { return false }
        case .notifications:
            isRequestingNotifications = true
            notificationStatus = await session.requestNotificationAuthorizationIfNeeded()
            isRequestingNotifications = false
        }
        await moveForward()
        return true
    }

    /// « Plus tard »: the next step without doing this one (an avatar choice is dropped); ends after the last step. On
    /// the notifications step the app will not ask for the permission by itself during this session.
    public func skipStep() async {
        guard !isFinished, !isBusy else { return }
        error = nil
        switch step {
        case .avatar: avatar.reset()
        case .notifications: session.deferNotificationPrompt()
        case .welcome, .firstGroup: break
        }
        await moveForward()
    }

    /// « Passer »: ends the onboarding now, from any step (even while a request is in progress).
    public func skip() async {
        error = nil
        await finish()
    }

    private func moveForward() async {
        if isLastStep {
            await finish()
        } else {
            stepIndex += 1
        }
    }

    private func submitFirstGroup() async -> Bool {
        if firstGroup != nil { return true }
        switch firstGroupMode {
        case .create:
            guard let created = await createGroup.create() else {
                adoptError(of: createGroup)
                return false
            }
            firstGroup = .created(created)
        case .join:
            guard let joined = await joinGroup.join() else {
                adoptError(of: joinGroup)
                return false
            }
            firstGroup = .joined(joined)
        }
        return true
    }

    /// Shows the alert of a step's own model in this one's.
    private func adoptError(of model: some ErrorPresenting) {
        guard let state = model.error else { return }
        error = state
        model.error = nil
    }

    // MARK: - End

    /// Opens the tabs at once, then tells the server. Until the server confirms, this device remembers to tell it
    /// again at the next session, and never shows the onboarding again.
    private func finish() async {
        guard !isFinished else { return }
        isFinished = true
        let store = session.platform.store
        let userId = session.userId
        OnboardingStore.markSettled(userId: userId, in: store)
        OnboardingStore.setPendingCompletion(true, userId: userId, in: store)
        app?.onboardingDidFinish(self)
        let profiles = session.services.profiles
        // Its own task: the view that started this call goes away with the onboarding.
        let completion = Task { try await profiles.completeOnboarding() }
        do {
            try await completion.value
            OnboardingStore.setPendingCompletion(false, userId: userId, in: store)
            isCompletedOnServer = true
        } catch {
            isCompletedOnServer = false
        }
    }
}
