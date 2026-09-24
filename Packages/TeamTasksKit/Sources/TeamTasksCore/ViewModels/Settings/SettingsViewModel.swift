import Foundation
import Observation

/// « Réglages » tab: display name, reminder lead time, optional ntfy push, notification permission, sign-out and
/// account deletion (only after typing « SUPPRIMER »).
///
/// View: `.task(id: model.refreshKey) { await model.load() }`. Sign-out and deletion end the session through
/// `AuthService.authStates()`: `AppModel` then shows the login screen.
@MainActor
@Observable
public final class SettingsViewModel: ErrorPresenting {
    public static let deleteConfirmationWord = "SUPPRIMER"
    public static let deleteAccountWarning =
        "Votre compte, votre profil et vos assignations seront supprimés définitivement. Les groupes dont vous êtes le seul membre seront supprimés avec leurs tâches\u{00A0}; dans les autres, le membre le plus ancien deviendra admin si vous étiez le seul admin. Tapez «\u{00A0}SUPPRIMER\u{00A0}» pour confirmer."
    public static let ntfyServer = "https://ntfy.sh"
    public static let pushInstructionSteps = [
        "Installez l’application gratuite «\u{00A0}ntfy\u{00A0}» depuis l’App Store.",
        "Dans ntfy, touchez «\u{00A0}+\u{00A0}» puis abonnez-vous au sujet ci-dessous (serveur ntfy.sh).",
        "Une notification vous prévient quand une tâche vous est assignée, même quand Équipe est fermée.",
    ]
    public static let pushPrivacyNote =
        "Gardez ce sujet secret\u{00A0}: toute personne qui le connaît peut voir quand une tâche vous est assignée (le titre de la tâche n’est jamais envoyé)."
    public static let pushDisabledExplanation =
        "Recevez une notification quand une tâche vous est assignée, même quand Équipe est fermée, grâce à l’application gratuite ntfy."

    // MARK: Profile

    public private(set) var profile: UserProfile?
    /// Editable display name (filled by `load()`).
    public var displayName: String {
        get { displayNameValue }
        set {
            displayNameValue = newValue
            if displayNameError != nil { displayNameError = SignUpViewModel.displayNameMessage(newValue) }
        }
    }

    public private(set) var displayNameError: String?
    public private(set) var isSavingName = false

    // MARK: Push

    public private(set) var pushTopic: String?
    public private(set) var isUpdatingPush = false

    // MARK: Notifications

    /// nil until loaded.
    public private(set) var notificationStatus: NotificationAuthorization?

    // MARK: Account

    /// What the user typed in the deletion confirmation field.
    public var deleteConfirmation = ""
    public private(set) var isSigningOut = false
    public private(set) var isDeletingAccount = false

    public private(set) var loadState: LoadState = .idle
    public var error: ErrorState?

    public let session: SessionModel
    private var displayNameValue = ""
    private var leadTimeValue: ReminderLeadTime?
    private let runner = LoadRunner()
    private let background = BackgroundWork()
    private var loadedRevision: Int?
    private var fetchingRevision: Int?

    public init(session: SessionModel) {
        self.session = session
    }

    // MARK: - Loading

    /// Changes when the profile may have changed on another device (a display-name update is a memberships signal).
    public var refreshKey: RefreshKey { RefreshKey(revision: session.feed.membershipsRevision) }

    public var needsRefresh: Bool { loadState != .loaded || loadedRevision != refreshKey.revision }

    public func load() async {
        guard needsRefresh else { return }
        let upToDate = runner.isRunning && fetchingRevision == refreshKey.revision
        await runner.run(rerunIfRunning: !upToDate) { [weak self] in await self?.fetch() }
    }

    public func reload() async {
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetch() }
    }

    private func fetch() async {
        let revision = refreshKey.revision
        fetchingRevision = revision
        defer { fetchingRevision = nil }
        if loadState != .loaded { loadState = .loading }
        if leadTimeValue == nil {
            leadTimeValue = ReminderLeadTime.load(from: session.platform.store)
        }
        notificationStatus = await session.platform.notifications.authorizationStatus()
        let profiles = session.services.profiles
        let push = session.services.push
        do {
            async let profileRequest = profiles.myProfile()
            async let topicRequest = push.currentTopic()
            let (profile, topic) = try await (profileRequest, topicRequest)
            // Keep a name being edited; follow the server otherwise.
            if self.profile == nil || displayNameValue == self.profile?.displayName {
                displayNameValue = profile.displayName
            }
            self.profile = profile
            pushTopic = topic
            loadedRevision = revision
            loadState = .loaded
        } catch {
            guard let state = ErrorState(from: error) else {
                if loadState == .loading { loadState = .idle }
                return
            }
            if loadState == .loaded {
                self.error = state
            } else {
                loadState = .failed(state.message)
            }
        }
    }

    // MARK: - Account info

    /// E-mail of the account.
    public var email: String? { session.user.email }

    // MARK: - Display name

    public var canSaveDisplayName: Bool {
        let trimmed = InputValidation.trimmed(displayNameValue)
        return !trimmed.isEmpty && trimmed != profile?.displayName && !isSavingName
    }

    @discardableResult
    public func saveDisplayName() async -> Bool {
        guard !isSavingName else { return false }
        error = nil
        displayNameError = SignUpViewModel.displayNameMessage(displayNameValue)
        guard displayNameError == nil else { return false }
        isSavingName = true
        defer { isSavingName = false }
        do {
            let updated = try await session.services.profiles.updateDisplayName(displayNameValue)
            profile = updated
            displayNameValue = updated.displayName
            // Names appear on every group screen.
            session.feed.bumpAll()
            return true
        } catch {
            if present(error) == .invalidDisplayName {
                displayNameError = AppError.invalidDisplayName.messageFR
                self.error = nil
            }
            return false
        }
    }

    // MARK: - Reminders

    public var leadTimeOptions: [ReminderLeadTime] { ReminderLeadTime.allCases }

    /// Picker binding: persists the choice and resynchronizes the reminders in the background.
    public var leadTime: ReminderLeadTime {
        get { leadTimeValue ?? ReminderLeadTime.load(from: session.platform.store) }
        set {
            guard newValue != leadTime else { return }
            store(newValue)
            background.start { [weak self] in
                _ = await self?.session.synchronizeReminders()
            }
        }
    }

    /// Persists the lead time and resynchronizes the reminders (awaited). Returns false when « Mes tâches » could
    /// not be loaded (the reminders then keep their previous schedule until the next synchronization).
    @discardableResult
    public func setLeadTime(_ value: ReminderLeadTime) async -> Bool {
        store(value)
        return await session.synchronizeReminders()
    }

    private func store(_ value: ReminderLeadTime) {
        leadTimeValue = value
        value.save(to: session.platform.store)
    }

    /// Waits for the background work started by the `leadTime` setter (tests).
    func waitForBackgroundWork() async {
        await background.waitForAll()
    }

    // MARK: - Push (ntfy)

    public var isPushEnabled: Bool { pushTopic != nil }

    /// Web address of the topic (also what the ntfy app subscribes to).
    public var pushTopicURL: URL? {
        pushTopic.flatMap { URL(string: "\(Self.ntfyServer)/\($0)") }
    }

    /// Opens the topic in the ntfy app when installed.
    public var ntfyAppURL: URL? {
        pushTopic.flatMap { URL(string: "ntfy://ntfy.sh/\($0)") }
    }

    @discardableResult
    public func enablePush() async -> Bool {
        guard !isUpdatingPush else { return false }
        error = nil
        isUpdatingPush = true
        defer { isUpdatingPush = false }
        do {
            pushTopic = try await session.services.push.enable()
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    public func disablePush() async -> Bool {
        guard !isUpdatingPush else { return false }
        error = nil
        isUpdatingPush = true
        defer { isUpdatingPush = false }
        do {
            try await session.services.push.disable()
            pushTopic = nil
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// Toggle binding helper.
    @discardableResult
    public func setPushEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            return await enablePush()
        }
        return await disablePush()
    }

    // MARK: - Notifications permission

    /// « Activées », « Refusées », « Pas encore demandées ».
    public var notificationStatusText: String {
        switch notificationStatus {
        case .authorized: "Activées"
        case .denied: "Refusées"
        case .notDetermined: "Pas encore demandées"
        case nil: "…"
        }
    }

    /// Shown when refused: the permission can only be changed in the system settings.
    public var notificationHint: String? {
        switch notificationStatus {
        case .denied: "Pour recevoir les rappels et les nouvelles tâches, autorisez les notifications d’Équipe dans l’app Réglages de l’iPhone."
        case .notDetermined: "Autorisez les notifications pour recevoir les rappels d’échéance et les nouvelles tâches."
        case .authorized, nil: nil
        }
    }

    public var canRequestNotifications: Bool { notificationStatus == .notDetermined }

    public func refreshNotificationStatus() async {
        notificationStatus = await session.platform.notifications.authorizationStatus()
    }

    /// Asks the system for the permission (only possible once); when granted, reminders and catch-up run.
    @discardableResult
    public func requestNotifications() async -> Bool {
        let status = await session.requestNotificationAuthorizationIfNeeded()
        notificationStatus = status
        return status == .authorized
    }

    // MARK: - Session

    @discardableResult
    public func signOut() async -> Bool {
        guard !isSigningOut else { return false }
        error = nil
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try await session.services.auth.signOut()
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// True once « SUPPRIMER » is typed exactly.
    public var canDeleteAccount: Bool { deleteConfirmation == Self.deleteConfirmationWord && !isDeletingAccount }

    /// Deletes the account (only when `canDeleteAccount`).
    @discardableResult
    public func deleteAccount() async -> Bool {
        guard deleteConfirmation == Self.deleteConfirmationWord else {
            present(message: "Tapez «\u{00A0}SUPPRIMER\u{00A0}» pour confirmer.", error: .invalidInput)
            return false
        }
        guard !isDeletingAccount else { return false }
        error = nil
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await session.services.auth.deleteAccount()
            session.platform.store.set(nil, forKey: MyTasksViewModel.lastSeenKey(userId: session.userId))
            deleteConfirmation = ""
            return true
        } catch {
            present(error)
            return false
        }
    }
}
