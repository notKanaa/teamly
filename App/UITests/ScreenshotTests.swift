import XCTest

/// The 14 screenshots of the CI artifact « screenshots »: scripts/ci/export-screenshots.sh names each file after its
/// attachment (01-connexion.png … 14-onboarding-notifications.png). In-memory demo data, signed in as Camille (admin of
/// « Coloc' rue des Lilas ») except for the login screen and the onboarding (a new account). Each capture waits for the
/// screen's real content; one test per screen (or sequence of screens) so that one failure does not lose the other
/// captures.
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

        // The « Compte » section is under the tab bar at the top of the form: scrolled into view for its own capture.
        ui.reveal(ui.buttons(AccessibilityID.Settings.deleteAccount), "« Supprimer mon compte »")
        ui.capture("10-reglages-compte")
    }

    /// The 4 steps of the onboarding of a new account, as on the mockups: the initials on indigo, then a « Coloc des
    /// Lilas » group with 🏠 on coral.
    @MainActor
    func test11To14Onboarding() {
        let ui = EquipeApp.launch(.signedOut, for: self)
        ui.signUp(name: "Camille Martin", email: "camille.martin@example.com", password: UITestDemo.password)

        ui.waitForContent(ui.onboardingStep("welcome"), "the welcome step")
        ui.waitForContent(ui.onboardingPrimaryButton, "« C’est parti »")
        ui.capture("11-onboarding-bienvenue")

        ui.advanceOnboarding("« C’est parti »", to: "avatar")
        ui.select(ui.buttons(AccessibilityID.Picker.color("indigo")), "the indigo swatch")
        ui.waitForContent(ui.elements(AccessibilityID.Picker.avatarPreview), "the avatar preview")
        ui.capture("12-onboarding-avatar")

        ui.advanceOnboarding("« Continuer »", to: "firstGroup")
        let nameField = ui.textFields(AccessibilityID.Onboarding.groupNameField)
        ui.typeText("Coloc des Lilas", into: nameField, "the group name field")
        ui.dismissKeyboard()
        ui.select(ui.buttons(AccessibilityID.Picker.emoji(UITestDemo.houseEmoji)), "the house emoji")
        ui.select(ui.buttons(AccessibilityID.Picker.color("coral")), "the coral swatch")
        ui.scrollToTop(until: nameField)
        ui.waitForContent(ui.elements(AccessibilityID.Onboarding.mode("create")), "« Créer »")
        ui.capture("13-onboarding-groupe")

        ui.advanceOnboarding("« Créer le groupe »", to: "notifications")
        ui.waitForContent(ui.buttons(AccessibilityID.Onboarding.laterButton), "« Plus tard »")
        ui.capture("14-onboarding-notifications")
    }
}

/// Design checks of the v2 screens (docs/DESIGN-V2.md §1): the same screens in dark mode and at the largest
/// accessibility text size, and the gallery of every component. Their captures are not part of the 14: the CI exports
/// them under `debug/`, to be looked at.
final class DesignCheckTests: XCTestCase {
    /// The 4 pages of the design system gallery (`-uiTestDesignGallery`), top and bottom, in light then dark mode.
    @MainActor
    func testComponentGallery() {
        let variants: [(name: String, appearance: UITestAppearance?)] = [("clair", nil), ("sombre", .dark)]
        for variant in variants {
            let ui = EquipeApp.launch(
                .signedOut, appearance: variant.appearance, arguments: ["-uiTestDesignGallery"], for: self
            )
            ui.waitFor(ui.elements(AccessibilityID.Gallery.screen), "the design gallery")
            for page in 1...4 {
                let segment = ui.buttons(AccessibilityID.Gallery.page(page))
                ui.tap(segment, "the gallery page \(page)", until: .selects(segment))
                ui.capture("galerie-\(page)-haut-\(variant.name)")
                for _ in 0..<3 {
                    ui.scroll(.towardsBottom)
                }
                ui.capture("galerie-\(page)-bas-\(variant.name)")
            }
        }
    }

    @MainActor
    func testDarkMode() {
        let ui = EquipeApp.launch(.signedOut, appearance: .dark, for: self)
        ui.waitForContent(ui.buttons(AccessibilityID.Auth.signInButton), "« Se connecter »")
        ui.capture("dark-connexion")

        ui.signUp(name: "Camille Martin", email: "camille.sombre@example.com", password: UITestDemo.password)
        ui.waitForContent(ui.onboardingPrimaryButton, "« C’est parti »")
        ui.capture("dark-onboarding-bienvenue")
        ui.advanceOnboarding("« C’est parti »", to: "avatar")
        ui.select(ui.buttons(AccessibilityID.Picker.emoji(UITestDemo.foxEmoji)), "the fox emoji")
        ui.capture("dark-onboarding-avatar")
        ui.advanceOnboarding("« Continuer »", to: "firstGroup")
        ui.capture("dark-onboarding-groupe")
        ui.tap(
            ui.buttons(AccessibilityID.Onboarding.laterButton), "« Plus tard »",
            until: .shows(ui.onboardingStep("notifications"))
        )
        ui.waitForContent(ui.buttons(AccessibilityID.Onboarding.laterButton), "« Plus tard »")
        ui.capture("dark-onboarding-notifications")
        ui.tap(ui.buttons(AccessibilityID.Onboarding.laterButton), "« Plus tard »", until: .shows(ui.app.tabBars))

        ui.openTab(AccessibilityID.Tabs.settingsTitle, identifier: AccessibilityID.Tabs.settings)
        ui.waitForContent(ui.textFields(AccessibilityID.Settings.displayNameField), "the display name field")
        ui.capture("dark-reglages")

        let cancel = ui.buttons(AccessibilityID.Settings.avatarCancelButton, orLabel: "Annuler")
        ui.tap(ui.buttons(AccessibilityID.Settings.avatarButton), "the avatar row", until: .shows(cancel))
        ui.waitForContent(ui.elements(AccessibilityID.Picker.avatarPreview), "the avatar preview")
        ui.capture("dark-avatar-editeur")
    }

    @MainActor
    func testLargestText() {
        let ui = EquipeApp.launch(.signedOut, appearance: .largestText, for: self)
        ui.waitFor(ui.elements(AccessibilityID.Auth.loginScreen), "the login screen")
        ui.capture("ax-connexion")

        ui.signUp(name: "Camille Martin", email: "camille.grande@example.com", password: UITestDemo.password)
        ui.waitForContent(ui.onboardingStep("welcome"), "the welcome step")
        ui.capture("ax-onboarding-bienvenue")
        ui.advanceOnboarding("« C’est parti »", to: "avatar")
        ui.capture("ax-onboarding-avatar")
        ui.advanceOnboarding("« Continuer »", to: "firstGroup")
        ui.capture("ax-onboarding-groupe")
        ui.tap(
            ui.buttons(AccessibilityID.Onboarding.skipButton), "« Passer »",
            until: .shows(ui.app.tabBars)
        )

        ui.openTab(AccessibilityID.Tabs.settingsTitle, identifier: AccessibilityID.Tabs.settings)
        ui.waitForContent(ui.elements(AccessibilityID.Settings.avatarButton), "the avatar row")
        ui.capture("ax-reglages")
    }
}
