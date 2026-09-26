import XCTest

/// End-to-end flows on the in-memory backend (French demo data, nothing persisted between tests).
final class FlowTests: XCTestCase {
    /// signedOut → login with the demo account → the signed-in app shows Camille's two groups.
    @MainActor
    func testLoginWithDemoAccount() {
        let ui = EquipeApp.launch(.signedOut, for: self)
        ui.signIn(email: UITestDemo.camilleEmail, password: UITestDemo.password)
        ui.waitForDemoGroups()
    }

    /// « + » → « Créer un groupe » → the new group opens (its creator is admin), then shows in the list.
    @MainActor
    func testCreateGroup() {
        let ui = EquipeApp.launch(.populated, for: self)
        ui.waitForDemoGroups()

        let nameField = ui.textFields(AccessibilityID.Groups.nameField)
        ui.openCreateGroupSheet()
        let name = ui.typeText("Club de lecture", into: nameField, "the group name field")
        ui.tapWhenEnabled(ui.buttons(AccessibilityID.Groups.saveButton), "« Créer » of the sheet", until: .hides(nameField))
        ui.waitForDisappearance(nameField, "the « Nouveau groupe » sheet")

        ui.waitForGroupScreen(name)
        ui.waitFor(ui.elements(AccessibilityID.Groups.emptyTasks), "the « Aucune tâche » state")
        ui.waitFor(ui.elements(AccessibilityID.Groups.inviteButton), "« Inviter » (the creator is admin)")

        ui.leaveGroupScreen()
        ui.waitForContent(ui.elements(AccessibilityID.Groups.row(name)), "the new group in the list")
    }

    /// « Rejoindre » with a well-formed but unknown code → « Code d'invitation invalide. » alert; the sheet stays open
    /// with the code, and nothing is joined.
    @MainActor
    func testJoinWithInvalidCodeShowsError() {
        let ui = EquipeApp.launch(.populated, for: self)
        ui.waitForDemoGroups()

        let codeField = ui.textFields(AccessibilityID.Groups.codeField)
        ui.tap(ui.joinGroupButton, "« Rejoindre »", until: .shows(codeField))
        // 8 letters of the code alphabet: « Rejoindre » gets enabled; the field formats them live as ZZZZ-ZZZZ.
        ui.typeText(
            UITestDemo.unknownInviteCode, into: codeField, "the invite code field",
            expecting: UITestDemo.unknownInviteCodeDisplayed
        )
        let joinButton = ui.buttons(AccessibilityID.Groups.saveButton)
        if !ui.waitUntilEnabled(joinButton, timeout: UITestTimeout.short) {
            // The field re-formats its text after each key and may miss the last one while showing all 8 (a CI run:
            // « ZZZZ-ZZZZ » shown, « Rejoindre » disabled): typing the last letter again hands it over.
            ui.app.typeText(XCUIKeyboardKey.delete.rawValue + String(UITestDemo.unknownInviteCode.suffix(1)))
            ui.waitForText(UITestDemo.unknownInviteCodeDisplayed, of: codeField)
        }
        ui.tapWhenEnabled(joinButton, "« Rejoindre » of the sheet", until: .shows(ui.app.alerts))

        ui.waitForAlert(containing: UITestDemo.invalidCodeMessage)
        ui.tapAlertButton("OK")

        // Still on the form with the code, nothing joined.
        ui.waitForText(UITestDemo.unknownInviteCodeDisplayed, of: codeField)
        ui.assertNotShown(ui.elements(AccessibilityID.Groups.joinResult), within: 1, "An unknown code must not join a group")
        ui.tap(ui.buttons(AccessibilityID.Groups.cancelButton), "« Annuler »", until: .hides(codeField))
        ui.waitForDisappearance(codeField, "the « Rejoindre un groupe » sheet")
        ui.waitForContent(ui.elements(AccessibilityID.Groups.row(UITestDemo.lilasGroup)), "the groups list")
    }

    /// Camille (admin) creates a task in « Coloc' rue des Lilas » assigned to Inès; the task screen lists her.
    @MainActor
    func testCreateTaskAssignedToMember() {
        let ui = EquipeApp.launch(.populated, for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)

        let titleField = ui.elements(AccessibilityID.Tasks.titleField)
        ui.tap(ui.addTaskButton, "« + »", until: .shows(titleField))
        let typedTitle = ui.typeText("Arroser les plantes", into: titleField, "the title field")
        ui.assign(UITestDemo.inesName)
        // The title as it will be saved (the keyboard may have corrected a word once the field lost the focus).
        let title = ui.currentText(of: titleField) ?? typedTitle
        // The sheet is gone once its « Annuler » is (always on screen, unlike the title field, which the editor may
        // have scrolled away to reach « Assigner à »).
        ui.tapWhenEnabled(
            ui.buttons(AccessibilityID.Tasks.saveButton), "« Créer » of the editor",
            until: .hides(ui.buttons(AccessibilityID.Tasks.cancelButton))
        )
        ui.waitForDisappearance(titleField, "the « Nouvelle tâche » sheet")

        // The new row gives the saved title: the keyboard (English on the CI simulator) may have corrected the last
        // word when the field lost the focus, after the reads above. Its first word was read after being corrected
        // (on the space that followed it), and no other task of the group starts with it.
        let firstWord = String(title.prefix { $0 != " " })
        ui.openTask(ui.taskTitle(startingWith: firstWord) ?? title)
        ui.reveal(ui.elements(labelContaining: UITestDemo.inesName), "Inès among the assignees", timeout: UITestTimeout.medium)
    }

    /// Inès (member) on a task created by Camille and assigned to her: she may change its status but neither edit nor
    /// delete it. On her own task, « Modifier » is shown (so the first check is not vacuous).
    @MainActor
    func testAssigneeCanChangeStatusButNotEdit() {
        let ui = EquipeApp.launch(.signedOut, for: self)
        ui.signIn(email: UITestDemo.inesEmail, password: UITestDemo.password)
        ui.openGroup(UITestDemo.lilasGroup)
        // Admin-only row, rendered with the rest of the loaded header.
        ui.assertNotShown(ui.elements(AccessibilityID.Groups.inviteButton), within: 1, "A member must not see the invite code")

        ui.openTask(UITestDemo.payerLoyer)
        let inProgress = ui.elements(AccessibilityID.Tasks.statusOption("in_progress"))
        ui.waitForContent(inProgress, "the « En cours » status option")
        ui.assertNotShown(ui.buttons(AccessibilityID.Tasks.editButton), within: 2, "An assignee must not edit the task")
        ui.tap(inProgress, "« En cours »", until: .selects(inProgress))
        let isSelected = ui.waitUntilSelected(inProgress)
        XCTAssertTrue(isSelected, "The status did not switch to « En cours »")
        ui.scroll(.towardsBottom)
        ui.assertNotShown(ui.buttons(AccessibilityID.Tasks.deleteButton), within: 1, "An assignee must not delete the task")

        // The group screen shows the new status (its row's label reads « Payer le loyer, En cours, … »).
        ui.goBack(from: UITestScreen.task)
        ui.waitFor(ui.elements(labelContaining: UITestDemo.payerLoyer, "En cours"), "« \(UITestDemo.payerLoyer) » in progress")

        ui.openTask(UITestDemo.reparerFuite)
        ui.waitForContent(ui.buttons(AccessibilityID.Tasks.editButton), "« Modifier » on a task created by Inès")
    }

    /// Réglages → « Se déconnecter » → confirmation → back to the login screen.
    @MainActor
    func testSignOut() {
        let ui = EquipeApp.launch(.populated, for: self)
        ui.openTab(AccessibilityID.Tabs.settingsTitle, identifier: AccessibilityID.Tabs.settings)
        ui.waitForContent(ui.textFields(AccessibilityID.Settings.displayNameField), "the loaded settings")

        ui.tap(ui.buttons(AccessibilityID.Settings.signOut), "« Se déconnecter »", timeout: UITestTimeout.short)
        ui.confirm("Se déconnecter", identifier: AccessibilityID.Settings.confirmSignOut, openedFrom: AccessibilityID.Settings.signOut)

        ui.waitFor(ui.elements(AccessibilityID.Auth.loginScreen), "the login screen")
        ui.waitForContent(ui.buttons(AccessibilityID.Auth.signInButton), "« Se connecter »")
        let myTasksTab = ui.tabButtonCandidates(AccessibilityID.Tabs.myTasksTitle, identifier: AccessibilityID.Tabs.myTasks)
        let remainingTab = ui.firstExisting(myTasksTab, timeout: 1)
        XCTAssertNil(remainingTab, "The tabs must be gone after signing out")
    }

    /// A user of no group gets the empty state with its two actions.
    @MainActor
    func testEmptyGroupsShowsEmptyState() {
        let ui = EquipeApp.launch(.emptyGroups, for: self)
        ui.waitForTabBar()
        ui.waitFor(ui.elements(AccessibilityID.Groups.emptyState), "the « no group » state")
        ui.waitForContent(ui.elements(AccessibilityID.Groups.emptyCreateButton), "« Créer un groupe »")
        ui.waitForContent(ui.elements(AccessibilityID.Groups.emptyJoinButton), "« Rejoindre avec un code »")
    }

    /// Réglages → the avatar row → « Ton avatar »: an emoji, « Enregistrer »; the sheet closes.
    @MainActor
    func testEditAvatarFromSettings() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", for: self)
        ui.openTab(AccessibilityID.Tabs.settingsTitle, identifier: AccessibilityID.Tabs.settings)
        // The row opens the editor once the profile is loaded (with the display name field).
        ui.waitForContent(ui.textFields(AccessibilityID.Settings.displayNameField), "the loaded settings")

        let save = ui.buttons(AccessibilityID.Settings.avatarSaveButton, orLabel: "Enregistrer")
        ui.tap(ui.buttons(AccessibilityID.Settings.avatarButton), "the avatar row", until: .shows(save))
        ui.waitForContent(ui.elements(AccessibilityID.Picker.avatarPreview), "the avatar preview")
        ui.select(ui.buttons(AccessibilityID.Picker.emoji(UITestDemo.foxEmoji)), "the fox emoji")
        ui.capture("avatar-editeur")

        ui.tapWhenEnabled(save, "« Enregistrer »", until: .hides(save))
        ui.waitForDisappearance(save, "the « Ton avatar » sheet")
        ui.waitForContent(ui.buttons(AccessibilityID.Settings.avatarButton), "the avatar row")
    }

    /// A new account goes through the 4 steps of the onboarding: « Bienvenue », an emoji avatar (and back to that step
    /// once), a first group created on the spot, « Plus tard » for the notifications; then the tabs show that group.
    @MainActor
    func testOnboardingOfANewAccount() {
        let ui = EquipeApp.launch(.signedOut, for: self)
        ui.signUp(name: "Hugo Petit", email: "hugo.petit@example.com", password: UITestDemo.password)

        // 1. Bienvenue.
        ui.waitForContent(ui.onboardingStep("welcome"), "the welcome step")
        ui.waitForText("Étape 1 sur 4", of: ui.elements(AccessibilityID.Onboarding.progress))
        ui.assertNotShown(ui.buttons(AccessibilityID.Onboarding.backButton), within: 1, "No « Retour » on the first step")
        ui.advanceOnboarding("« C’est parti »", to: "avatar")

        // 2. Avatar: an emoji instead of the initials.
        let fox = ui.buttons(AccessibilityID.Picker.emoji(UITestDemo.foxEmoji))
        ui.select(fox, "the fox emoji")
        ui.advanceOnboarding("« Continuer »", to: "firstGroup")

        // Back to the avatar, which kept its emoji, then forward again.
        ui.tap(
            ui.buttons(AccessibilityID.Onboarding.backButton), "« Retour »",
            until: .shows(ui.onboardingStep("avatar"))
        )
        XCTAssertTrue(ui.waitUntilSelected(fox), "The saved emoji is not selected any more")
        ui.advanceOnboarding("« Continuer »", to: "firstGroup")

        // 3. Premier groupe: « Créer ».
        ui.waitForText("Étape 3 sur 4", of: ui.elements(AccessibilityID.Onboarding.progress))
        let name = ui.typeText(
            "Club de lecture", into: ui.textFields(AccessibilityID.Onboarding.groupNameField), "the group name field"
        )
        ui.advanceOnboarding("« Créer le groupe »", to: "notifications")

        // 4. Notifications: « Plus tard » ends the onboarding.
        ui.tap(
            ui.buttons(AccessibilityID.Onboarding.laterButton), "« Plus tard »",
            until: .shows(ui.app.tabBars)
        )
        ui.waitForTabBar()
        ui.waitForContent(ui.elements(AccessibilityID.Groups.row(name)), "the group created during the onboarding")
    }
}
