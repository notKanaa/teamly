import XCTest

/// The 9 screenshots of the CI artifact « screenshots »: scripts/ci/export-screenshots.sh names each file after its
/// attachment (01-connexion.png … 09-reglages.png). In-memory demo data, signed in as Camille (admin of
/// « Coloc' rue des Lilas ») except for the login screen. Each capture waits for the screen's real content; one test
/// per screen (or pair of screens) so that one failure does not lose the other captures.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func test01Login() {
        let ui = EquipeApp.launch(.signedOut, for: self)
        ui.waitFor(ui.elements(AccessibilityID.Auth.loginScreen), "the login screen")
        ui.waitForContent(ui.textFields(AccessibilityID.Auth.email), "the e-mail field")
        ui.waitForContent(ui.buttons(AccessibilityID.Auth.signInButton), "« Se connecter »")
        ui.capture("01-connexion")
    }

    @MainActor
    func test02GroupsAndCreateGroup() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.capture("02-groupes")

        let nameField = ui.textFields(AccessibilityID.Groups.nameField)
        ui.tap(ui.createGroupButton, "« Créer »", until: .shows(nameField))
        ui.typeText("Club de lecture", into: nameField, "the group name field")
        let createButton = ui.buttons(AccessibilityID.Groups.saveButton)
        ui.waitForContent(createButton, "« Créer » of the sheet")
        // The typed name is taken into account once « Créer » is enabled.
        let isEnabled = ui.waitUntilEnabled(createButton, timeout: UITestTimeout.medium)
        ui.capture("03-creer-groupe")

        XCTAssertTrue(isEnabled, "« Créer » stays disabled with a valid name")
    }

    @MainActor
    func test04InviteCode() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        // « Fermer » shows with the sheet, before its code is loaded.
        ui.tap(
            ui.elements(AccessibilityID.Groups.inviteButton), "« Inviter avec un code »",
            until: .shows(ui.buttons(AccessibilityID.Groups.doneButton))
        )
        let code = ui.elements(AccessibilityID.Groups.inviteCode)
        ui.waitForContent(code, "the invite code")
        ui.capture("04-code-invitation")

        ui.waitForText(UITestDemo.lilasInviteCode, of: code)
    }

    @MainActor
    func test05NewTask() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)

        let titleField = ui.elements(AccessibilityID.Tasks.titleField)
        ui.tap(ui.addTaskButton, "« + »", until: .shows(titleField))
        ui.typeText("Arroser les plantes", into: titleField, "the title field")
        ui.typeText(
            "Deux fois par semaine, sans oublier le balcon.",
            into: ui.elements(AccessibilityID.Tasks.detailsField), "the description field"
        )
        // Leaving for « Assigner à » also closes the keyboard.
        ui.assign(UITestDemo.inesName)
        // Polish only (never fails the capture): high priority and a due date.
        ui.selectSegment("Haute", of: AccessibilityID.Tasks.priorityPicker)
        ui.switchOn(AccessibilityID.Tasks.dueDateToggle)
        ui.scrollToTop(until: titleField)

        ui.waitForContent(titleField, "the title field")
        ui.waitForContent(ui.buttons(AccessibilityID.Tasks.saveButton), "« Créer » of the editor")
        ui.capture("05-nouvelle-tache")
    }

    @MainActor
    func test06GroupDetail() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        ui.waitForContent(ui.elements(AccessibilityID.Groups.membersButton), "the « Membres » row")
        ui.waitForContent(ui.elements(AccessibilityID.Tasks.row(UITestDemo.payerLoyer)), "the first task")
        ui.capture("06-detail-groupe")
    }

    @MainActor
    func test07MyTasks() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", for: self)
        ui.openTab(AccessibilityID.Tabs.myTasksTitle, identifier: AccessibilityID.Tabs.myTasks)
        ui.waitFor(ui.elements(AccessibilityID.MyTasks.list), "the « Mes tâches » list")
        ui.waitForContent(ui.elements(AccessibilityID.Tasks.row(UITestDemo.faireCourses)), "« \(UITestDemo.faireCourses) »")
        ui.waitForContent(ui.elements(AccessibilityID.Tasks.row(UITestDemo.reserverGymnase)), "« \(UITestDemo.reserverGymnase) »")
        ui.capture("07-mes-taches")
    }

    @MainActor
    func test08Members() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        let membersList = ui.elements(AccessibilityID.Members.list)
        ui.tapRow(AccessibilityID.Groups.membersButton, "the « Membres » row", until: .shows(membersList))
        ui.waitFor(membersList, "the members list")
        ui.waitForContent(ui.elements(AccessibilityID.Members.row(UITestDemo.camilleName)), "Camille's row")
        ui.waitForContent(ui.elements(AccessibilityID.Members.row(UITestDemo.inesName)), "Inès' row")
        ui.waitForContent(ui.elements(AccessibilityID.Members.inviteCode), "the invite code (admin)")
        ui.capture("08-membres")
    }

    @MainActor
    func test09Settings() {
        let ui = EquipeApp.launch(.populated, notifications: "authorized", for: self)
        ui.openTab(AccessibilityID.Tabs.settingsTitle, identifier: AccessibilityID.Tabs.settings)
        // Only shown once the profile is loaded.
        ui.waitForContent(ui.textFields(AccessibilityID.Settings.displayNameField), "the display name field")
        ui.waitForContent(ui.elements(AccessibilityID.Settings.email), "the e-mail row")
        ui.capture("09-reglages")
    }
}
