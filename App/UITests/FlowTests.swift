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

    /// « Créer » → the new group opens (its creator is admin), then shows in the list.
    @MainActor
    func testCreateGroup() {
        let ui = EquipeApp.launch(.populated, for: self)
        ui.waitForDemoGroups()

        ui.tap(ui.button(AccessibilityID.Groups.createButton), "« Créer »")
        let nameField = ui.textField(AccessibilityID.Groups.nameField)
        let name = ui.typeText("Club de lecture", into: nameField)
        ui.tapWhenEnabled(ui.button(AccessibilityID.Groups.saveButton), "« Créer » of the sheet")
        ui.waitForDisappearance(nameField, "the « Nouveau groupe » sheet")

        ui.waitForNavigationTitle(name)
        ui.waitFor(ui.element(AccessibilityID.Groups.emptyTasks), "the « Aucune tâche » state")
        ui.waitFor(ui.element(AccessibilityID.Groups.inviteButton), "« Inviter avec un code » (the creator is admin)")

        ui.goBack(from: name)
        ui.waitForContent(ui.element(AccessibilityID.Groups.row(name)), "the new group in the list")
    }

    /// « Rejoindre » with a well-formed but unknown code → « Erreur » alert; the sheet stays open.
    @MainActor
    func testJoinWithInvalidCodeShowsError() {
        let ui = EquipeApp.launch(.populated, for: self)
        ui.waitForDemoGroups()

        ui.tap(ui.button(AccessibilityID.Groups.joinButton), "« Rejoindre »")
        let codeField = ui.textField(AccessibilityID.Groups.codeField)
        ui.typeText("AAAA2222", into: codeField)
        ui.tapWhenEnabled(ui.button(AccessibilityID.Groups.saveButton), "« Rejoindre » of the sheet")

        let alert = ui.waitForAlert(containing: "invalide")
        ui.tap(alert.buttons["OK"], "« OK »")
        ui.waitForDisappearance(alert, "the alert")

        // Still on the form, nothing joined.
        ui.waitFor(codeField, "the code field")
        ui.assertNotShown(ui.element(AccessibilityID.Groups.joinResult), within: 1, "An unknown code must not join a group")
        ui.tap(ui.button(AccessibilityID.Groups.cancelButton), "« Annuler »")
        ui.waitForDisappearance(codeField, "the « Rejoindre un groupe » sheet")
        ui.waitForContent(ui.element(AccessibilityID.Groups.row(UITestDemo.lilasGroup)))
    }

    /// Camille (admin) creates a task in « Coloc' rue des Lilas » assigned to Inès; the task screen lists her.
    @MainActor
    func testCreateTaskAssignedToMember() {
        let ui = EquipeApp.launch(.populated, for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)

        ui.tap(ui.button(AccessibilityID.Tasks.addButton), "« + »")
        let titleField = ui.element(AccessibilityID.Tasks.titleField)
        let title = ui.typeText("Arroser les plantes", into: titleField)
        ui.assign(UITestDemo.inesName)
        ui.tapWhenEnabled(ui.button(AccessibilityID.Tasks.saveButton), "« Créer » of the editor")
        ui.waitForDisappearance(titleField, "the « Nouvelle tâche » sheet")

        ui.openTask(title)
        ui.reveal(ui.element(labelContaining: UITestDemo.inesName), timeout: UITestTimeout.medium, "Inès among the assignees")
    }

    /// Inès (member) on a task created by Camille and assigned to her: she may change its status but neither edit nor
    /// delete it. On her own task, « Modifier » is shown (so the first check is not vacuous).
    @MainActor
    func testAssigneeCanChangeStatusButNotEdit() {
        let ui = EquipeApp.launch(.signedOut, for: self)
        ui.signIn(email: UITestDemo.inesEmail, password: UITestDemo.password)
        ui.openGroup(UITestDemo.lilasGroup)
        // Admin-only row, rendered with the rest of the loaded header.
        ui.assertNotShown(ui.element(AccessibilityID.Groups.inviteButton), within: 1, "A member must not see the invite code")

        ui.openTask(UITestDemo.payerLoyer)
        let inProgress = ui.element(AccessibilityID.Tasks.statusOption("in_progress"))
        ui.waitForContent(inProgress, "the « En cours » status option")
        ui.assertNotShown(ui.button(AccessibilityID.Tasks.editButton), within: 2, "An assignee must not edit the task")
        inProgress.tap()
        let isSelected = ui.waitUntilSelected(inProgress)
        XCTAssertTrue(isSelected, "The status did not switch to « En cours »")
        ui.scroll(.towardsBottom)
        ui.assertNotShown(ui.button(AccessibilityID.Tasks.deleteButton), within: 1, "An assignee must not delete the task")

        // The group screen shows the new status (its row's label reads « Payer le loyer, En cours, … »).
        ui.goBack()
        ui.waitFor(ui.element(labelContaining: UITestDemo.payerLoyer, "En cours"), "« \(UITestDemo.payerLoyer) » in progress")

        ui.openTask(UITestDemo.reparerFuite)
        ui.waitForContent(ui.button(AccessibilityID.Tasks.editButton), "« Modifier » on a task created by Inès")
    }

    /// Réglages → « Se déconnecter » → confirmation → back to the login screen.
    @MainActor
    func testSignOut() {
        let ui = EquipeApp.launch(.populated, for: self)
        ui.openTab(AccessibilityID.Tabs.settingsTitle, identifier: AccessibilityID.Tabs.settings)
        ui.waitForContent(ui.textField(AccessibilityID.Settings.displayNameField), "the loaded settings")

        let signOut = ui.button(AccessibilityID.Settings.signOut)
        ui.tap(signOut, timeout: UITestTimeout.short, "« Se déconnecter »")
        ui.confirm("Se déconnecter", identifier: AccessibilityID.Settings.confirmSignOut, openedFrom: signOut)

        ui.waitFor(ui.element(AccessibilityID.Auth.loginScreen), "the login screen")
        ui.waitForContent(ui.button(AccessibilityID.Auth.signInButton), "« Se connecter »")
        let myTasksTab = ui.tabButtonCandidates(AccessibilityID.Tabs.myTasksTitle, identifier: AccessibilityID.Tabs.myTasks)
        let remainingTab = ui.firstExisting(myTasksTab, timeout: 1)
        XCTAssertNil(remainingTab, "The tabs must be gone after signing out")
    }

    /// A user of no group gets the empty state with its two actions.
    @MainActor
    func testEmptyGroupsShowsEmptyState() {
        let ui = EquipeApp.launch(.emptyGroups, for: self)
        ui.waitForTabBar()
        ui.waitFor(ui.element(AccessibilityID.Groups.emptyState), "the « no group » state")
        ui.waitForContent(ui.element(AccessibilityID.Groups.emptyCreateButton), "« Créer un groupe »")
        ui.waitForContent(ui.element(AccessibilityID.Groups.emptyJoinButton), "« Rejoindre avec un code »")
    }
}
