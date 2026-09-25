import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

// docs/CONTRACTS-V2.md §9: the onboarding of new accounts, and how `AppModel` routes to it.

@MainActor
@Suite struct OnboardingRoutingTests {
    typealias F = VMFixtures
    static let email = "nina@example.com"
    static let password = "motdepasse-solide"

    private func signIn(_ harness: VMHarness, _ app: AppModel, email: String = OnboardingRoutingTests.email) async throws {
        try await harness.services.auth.signIn(email: email, password: Self.password)
    }

    private func signOut(_ harness: VMHarness, _ app: AppModel) async throws {
        try await harness.services.auth.signOut()
        await VMWait.until("signed out") { app.phase == .signedOut }
    }

    /// A fresh sign-up lands in the onboarding, once its profile is read, with every step (no group, permission never
    /// asked). « Passer » opens the tabs of the same session, and the next sign-in opens them without any read.
    @Test func freshSignUpLandsInTheOnboarding() async throws {
        let harness = VMHarness(.signedOut, authorization: .notDetermined)
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed out") { app.phase == .signedOut }
        let signUp = app.makeSignUpViewModel()
        signUp.displayName = "Nina Petit"
        signUp.email = Self.email
        signUp.password = Self.password
        #expect(await signUp.signUp())
        await VMWait.until("onboarding") { app.onboarding != nil }
        let onboarding = try #require(app.onboarding)
        #expect(app.phase == .onboarding(onboarding))
        #expect(app.session === onboarding.session)
        #expect(onboarding.session.isRunning)
        #expect(app.router.isActive)
        #expect(onboarding.steps == [.welcome, .avatar, .firstGroup, .notifications])
        #expect(onboarding.welcomeTitle == "Bienvenue, Nina\u{00A0}!")
        let userId = onboarding.session.userId
        #expect(!OnboardingStore.isSettled(userId: userId, in: harness.store))

        await onboarding.skip()
        #expect(app.phase == .signedIn(onboarding.session))
        #expect(app.onboarding == nil)
        #expect(onboarding.isCompletedOnServer == true)
        #expect(try await harness.services.profiles.myProfile().onboardedAt != nil)
        #expect(OnboardingStore.isSettled(userId: userId, in: harness.store))
        #expect(!OnboardingStore.hasPendingCompletion(userId: userId, in: harness.store))

        let reads = harness.faults.calls(.myProfile)
        try await signOut(harness, app)
        try await signIn(harness, app)
        await VMWait.until("signed in") { app.session != nil }
        let session = try #require(app.session)
        #expect(app.phase == .signedIn(session))
        #expect(harness.faults.calls(.myProfile) == reads)
        await app.shutdown()
    }

    /// The demo users are onboarded, and a never-onboarded account older than 7 days (created with a v1 app) is not
    /// proposed the onboarding: both open the tabs, and the answer is remembered.
    @Test func onboardedOrOldAccountsOpenTheTabs() async throws {
        let harness = VMHarness()
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed in") { app.session != nil }
        let session = try #require(app.session)
        #expect(app.phase == .signedIn(session))
        #expect(app.onboarding == nil)
        #expect(OnboardingStore.isSettled(userId: F.camille.id, in: harness.store))
        #expect(harness.faults.calls(.myProfile) == 1)
        await app.shutdown()

        let old = VMHarness(.signedOut)
        let account = try old.backend.createAccount(email: "ancien@example.com", password: Self.password, displayName: "Ancien")
        old.clock.advance(by: 8 * 86_400)
        let oldApp = old.makeApp()
        oldApp.start()
        await VMWait.until("signed out") { oldApp.phase == .signedOut }
        try await signIn(old, oldApp, email: "ancien@example.com")
        await VMWait.until("signed in") { oldApp.session != nil }
        #expect(oldApp.phase == .signedIn(try #require(oldApp.session)))
        #expect(OnboardingStore.isSettled(userId: account.id, in: old.store))
        await oldApp.shutdown()
    }

    /// A user who already has a group skips « Premier groupe », and a decided permission skips the notifications.
    @Test func stepsFollowTheGroupsAndThePermission() async throws {
        let harness = VMHarness(.signedOut, authorization: .denied)
        let account = try harness.backend.createAccount(email: Self.email, password: Self.password, displayName: "Zoé")
        _ = try await harness.backend.services(for: account.id).groups.join(code: try #require(InviteCode("LYLAS234")))
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed out") { app.phase == .signedOut }
        try await signIn(harness, app)
        await VMWait.until("onboarding") { app.onboarding != nil }
        let onboarding = try #require(app.onboarding)
        #expect(onboarding.steps == [.welcome, .avatar])
        #expect(onboarding.progressText == "1 sur 2")
        #expect(await onboarding.advance())
        #expect(onboarding.primaryButtonTitle == "Terminer")
        #expect(await onboarding.advance())
        #expect(app.phase == .signedIn(onboarding.session))
        await app.shutdown()
    }

    /// A failed or slow profile read never keeps the user on the splash screen: the tabs open, and the onboarding is
    /// proposed again at the next session.
    @Test func failedOrSlowChecksOpenTheTabs() async throws {
        let harness = VMHarness(.signedOut)
        let account = try harness.backend.createAccount(email: Self.email, password: Self.password, displayName: "Léa")
        let configuration = SessionModel.Configuration(
            realtimeDebounce: .zero, realtimeRetryDelay: .milliseconds(20), onboardingCheckTimeout: .seconds(1)
        )
        let app = AppModel(services: harness.services, platform: harness.platform, sessionConfiguration: configuration)
        app.start()
        await VMWait.until("signed out") { app.phase == .signedOut }

        harness.faults.fail(.myProfile, with: AppError.network)
        try await signIn(harness, app)
        await VMWait.until("signed in") { app.session != nil }
        #expect(app.phase == .signedIn(try #require(app.session)))
        #expect(!OnboardingStore.isSettled(userId: account.id, in: harness.store))

        try await signOut(harness, app)
        harness.faults.hold(.myProfile)
        try await signIn(harness, app)
        await VMWait.until("signed in after the timeout") { app.session != nil }
        #expect(app.phase == .signedIn(try #require(app.session)))
        harness.faults.release(.myProfile)

        try await signOut(harness, app)
        try await signIn(harness, app)
        await VMWait.until("onboarding") { app.onboarding != nil }
        await app.shutdown()
    }

    /// When the server does not confirm the end, the tabs open anyway and the next session tells it again.
    @Test func aFailedCompletionIsToldAgainAtTheNextSession() async throws {
        let harness = VMHarness(.signedOut)
        let account = try harness.backend.createAccount(email: Self.email, password: Self.password, displayName: "Léa")
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed out") { app.phase == .signedOut }
        try await signIn(harness, app)
        await VMWait.until("onboarding") { app.onboarding != nil }
        let onboarding = try #require(app.onboarding)

        harness.faults.fail(.completeOnboarding, with: AppError.network)
        await onboarding.skip()
        #expect(app.phase == .signedIn(onboarding.session))
        #expect(onboarding.isCompletedOnServer == false)
        #expect(OnboardingStore.hasPendingCompletion(userId: account.id, in: harness.store))
        let lea = harness.backend.services(for: account.id)
        #expect(try await lea.profiles.myProfile().onboardedAt == nil)

        try await signOut(harness, app)
        try await signIn(harness, app)
        await VMWait.until("signed in") { app.session != nil }
        #expect(app.onboarding == nil)
        await VMWait.until("told again") { !OnboardingStore.hasPendingCompletion(userId: account.id, in: harness.store) }
        #expect(try await lea.profiles.myProfile().onboardedAt != nil)
        await app.shutdown()
    }

    @Test func phases() throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let profile = UserProfile(id: F.camille.id, displayName: "Camille Martin")
        let first = OnboardingViewModel(session: session, profile: profile, hasGroups: true, notifications: .authorized)
        let second = OnboardingViewModel(session: session, profile: profile, hasGroups: true, notifications: .authorized)
        #expect(AppPhase.onboarding(first) == .onboarding(first))
        #expect(AppPhase.onboarding(first) != .onboarding(second))
        #expect(AppPhase.onboarding(first) != .signedIn(session))
        #expect(AppPhase.onboarding(first).session === session)
        #expect(AppPhase.launching.session == nil)
    }
}

@MainActor
@Suite struct OnboardingViewModelTests {
    typealias F = VMFixtures

    /// A new account signed in on the harness's device, and its onboarding (without an app model).
    private func newcomer(
        _ harness: VMHarness,
        notifications: NotificationAuthorization = .notDetermined
    ) async throws -> OnboardingViewModel {
        let account = try harness.backend.createAccount(
            email: "nina@example.com", password: DemoData.password, displayName: "Nina Petit"
        )
        try await harness.services.auth.signIn(email: "nina@example.com", password: DemoData.password)
        let session = SessionModel(
            user: AuthUser(id: account.id, email: account.email),
            services: harness.services,
            platform: harness.platform,
            configuration: VMHarness.testConfiguration
        )
        let profile = try await harness.services.profiles.myProfile()
        #expect(OnboardingPolicy.shouldShow(profile: profile, now: harness.clock.peek()))
        return OnboardingViewModel(session: session, profile: profile, hasGroups: false, notifications: notifications)
    }

    @Test func walksThroughEveryStep() async throws {
        let harness = VMHarness(.signedOut, authorization: .notDetermined)
        let model = try await newcomer(harness)
        let userId = model.session.userId

        #expect(model.step == .welcome)
        #expect(model.progressText == "1 sur 4")
        #expect(!model.canGoBack)
        #expect(model.title == "Bienvenue, Nina\u{00A0}!")
        #expect(model.message == OnboardingViewModel.welcomeMessage)
        #expect(OnboardingViewModel.highlights.map(\.title) == ["À tour de rôle", "Des checklists", "Le récap de la semaine"])
        #expect(model.primaryButtonTitle == "C’est parti")
        #expect(model.secondaryButtonTitle == nil)
        #expect(await model.advance())

        // Avatar.
        #expect(model.step == .avatar)
        #expect(model.progressText == "2 sur 4")
        #expect(model.canGoBack)
        #expect(model.title == "Choisis ton avatar")
        #expect(model.primaryButtonTitle == "Continuer")
        #expect(model.avatar.initials == "NP")
        #expect(model.avatar.colorOptions == ColorKey.allCases)
        #expect(model.avatar.emojiOptions == EmojiChoices.avatars)
        #expect(model.avatar.preview == AvatarAppearance(color: ColorKey.automatic(for: userId), emoji: nil, initials: "NP"))
        // A color other than the automatic one (the account id is random).
        let color: ColorKey = ColorKey.automatic(for: userId) == .teal ? .pink : .teal
        model.avatar.selectColor(color)
        model.avatar.selectEmoji("\u{1F98A}")
        #expect(model.avatar.preview == AvatarAppearance(color: color, emoji: "\u{1F98A}", initials: "NP"))
        #expect(model.avatar.isSelected(color))
        #expect(model.avatar.isSelected(emoji: "\u{1F98A}"))
        #expect(!model.avatar.isSelected(emoji: nil))
        #expect(await model.advance())
        #expect(harness.faults.calls(.updateAvatar) == 1)
        let saved = try await harness.services.profiles.myProfile()
        #expect(saved.avatarColor == color && saved.avatarEmoji == "\u{1F98A}")

        // Back and forth: the saved avatar is not sent again.
        model.goBack()
        #expect(model.step == .avatar)
        #expect(await model.advance())
        #expect(harness.faults.calls(.updateAvatar) == 1)

        // First group: « Créer ».
        #expect(model.step == .firstGroup)
        #expect(model.title == "Ton premier groupe")
        #expect(model.firstGroupMode == .create)
        #expect(OnboardingViewModel.FirstGroupMode.allCases.map(\.label) == ["Créer", "Rejoindre"])
        #expect(model.primaryButtonTitle == "Créer le groupe")
        #expect(model.secondaryButtonTitle == "Plus tard")
        #expect(!model.canAdvance)
        model.createGroup.name = "Coloc Parc"
        model.createGroup.selectColor(.coral)
        model.createGroup.selectEmoji("\u{1F3E0}")
        #expect(model.createGroup.preview == AvatarAppearance(color: .coral, emoji: "\u{1F3E0}", initials: "CP"))
        #expect(model.canAdvance)
        #expect(await model.advance())
        let created = try #require(try await harness.services.groups.myGroups().first)
        #expect(created.group.name == "Coloc Parc")
        #expect(created.group.color == .coral && created.group.emoji == "\u{1F3E0}")
        #expect(created.myRole == .admin)
        #expect(model.firstGroup?.groupId == created.id)
        #expect(model.firstGroup?.groupName == "Coloc Parc")
        #expect(model.firstGroupDoneMessage == "Le groupe «\u{00A0}Coloc Parc\u{00A0}» est créé.")

        // Back to the group step: nothing is created twice.
        model.goBack()
        #expect(model.primaryButtonTitle == "Continuer")
        #expect(model.secondaryButtonTitle == nil)
        #expect(await model.advance())
        #expect(harness.faults.calls(.createGroup) == 1)

        // Notifications: asked, then the end.
        #expect(model.step == .notifications)
        #expect(model.title == "Ne rate plus ton tour")
        #expect(model.primaryButtonTitle == "Activer les notifications")
        #expect(model.secondaryButtonTitle == "Plus tard")
        #expect(await model.advance())
        #expect(harness.scheduler.requestCount == 1)
        #expect(model.notificationStatus == .authorized)
        #expect(model.isFinished)
        #expect(model.isCompletedOnServer == true)
        #expect(try await harness.services.profiles.myProfile().onboardedAt != nil)
        #expect(OnboardingStore.isSettled(userId: userId, in: harness.store))
        #expect(!model.canGoBack)
        #expect(await !model.advance())
    }

    /// « Plus tard » moves on without acting; on the notifications step it ends without asking.
    @Test func laterSkipsAStep() async throws {
        let harness = VMHarness(.signedOut, authorization: .notDetermined)
        let model = try await newcomer(harness)
        #expect(await model.advance())
        model.avatar.selectEmoji("\u{1F43C}")
        await model.skipStep()
        #expect(model.step == .firstGroup)
        #expect(model.avatar.emoji == nil)
        #expect(harness.faults.calls(.updateAvatar) == 0)
        await model.skipStep()
        #expect(model.step == .notifications)
        #expect(try await harness.services.groups.myGroups().isEmpty)
        await model.skipStep()
        #expect(model.isFinished)
        #expect(harness.scheduler.requestCount == 0)
        #expect(model.session.isNotificationPromptDeferred)
        #expect(model.isCompletedOnServer == true)
    }

    /// « Passer » ends at once, from any step, and only once.
    @Test func passerEndsAtOnce() async throws {
        let harness = VMHarness(.signedOut)
        let model = try await newcomer(harness)
        #expect(await model.advance())
        await model.skip()
        #expect(model.isFinished)
        #expect(!model.session.isNotificationPromptDeferred)
        #expect(harness.faults.calls(.completeOnboarding) == 1)
        await model.skip()
        #expect(await !model.advance())
        await model.skipStep()
        #expect(harness.faults.calls(.completeOnboarding) == 1)
    }

    @Test func joinsAGroupWithItsCode() async throws {
        let harness = VMHarness(.signedOut, authorization: .denied)
        let model = try await newcomer(harness, notifications: .denied)
        #expect(model.steps == [.welcome, .avatar, .firstGroup])
        #expect(await model.advance())
        #expect(await model.advance())
        model.firstGroupMode = .join
        #expect(model.primaryButtonTitle == "Rejoindre le groupe")
        #expect(!model.canAdvance)
        model.joinGroup.code = "ABCD-EFGH"
        #expect(model.canAdvance)
        #expect(await !model.advance())
        #expect(model.step == .firstGroup)
        #expect(model.errorMessage == "Code d’invitation invalide.")
        #expect(model.joinGroup.error == nil)
        model.joinGroup.code = "lylas234"
        #expect(await model.advance())
        #expect(model.firstGroup == .joined(JoinResult(groupId: F.lilas, groupName: "Coloc' rue des Lilas", alreadyMember: false)))
        #expect(model.firstGroupDoneMessage == "Tu as rejoint «\u{00A0}Coloc' rue des Lilas\u{00A0}».")
        #expect(model.isFinished)
    }

    /// A failed step shows its error and stays; the user can retry, go on or leave.
    @Test func aFailedStepStays() async throws {
        let harness = VMHarness(.signedOut)
        let model = try await newcomer(harness, notifications: .authorized)
        #expect(await model.advance())
        // A color other than the automatic one (the account id is random).
        let color: ColorKey = ColorKey.automatic(for: model.session.userId) == .pink ? .teal : .pink
        model.avatar.selectColor(color)
        harness.faults.fail(.updateAvatar, with: AppError.network)
        #expect(await !model.advance())
        #expect(model.step == .avatar)
        #expect(model.errorMessage == AppError.network.messageFR)
        #expect(model.avatar.error == nil)
        #expect(model.avatar.color == color)
        #expect(await model.advance())
        #expect(model.step == .firstGroup)

        model.createGroup.name = String(repeating: "x", count: 61)
        #expect(await !model.advance())
        #expect(model.createGroup.nameError == AppError.invalidName.messageFR)
        #expect(model.error == nil)
        harness.faults.fail(.createGroup, with: AppError.network)
        model.createGroup.name = "Famille"
        #expect(await !model.advance())
        #expect(model.errorMessage == AppError.network.messageFR)

        await model.skip()
        #expect(model.isFinished)
    }

    /// The avatar editor keeps an automatic color automatic and sends nothing without a change.
    @Test func avatarEditorChoices() async throws {
        let harness = VMHarness()
        let profile = UserProfile(id: F.camille.id, displayName: "Camille Martin")
        let editor = AvatarEditorViewModel(session: harness.makeSession(), profile: profile)
        let automatic = ColorKey.automatic(for: F.camille.id)
        #expect(editor.isSelected(automatic))
        #expect(!editor.hasChanges)
        editor.selectColor(automatic == .teal ? .pink : .teal)
        #expect(editor.hasChanges)
        editor.selectColor(automatic)
        #expect(editor.color == nil)
        #expect(!editor.hasChanges)
        editor.selectEmoji("\u{1F98A}")
        #expect(editor.hasChanges && editor.canSave)
        editor.reset()
        #expect(editor.emoji == nil && !editor.hasChanges)
        #expect(await editor.save())
        #expect(harness.faults.calls(.updateAvatar) == 0)

        // An emoji refused before any request.
        editor.selectEmoji("a b")
        #expect(await !editor.save())
        #expect(editor.errorMessage == AppError.invalidAppearance.messageFR)
        #expect(harness.faults.calls(.updateAvatar) == 0)
    }
}
