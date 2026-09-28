import XCTest

/// The v3 social flows on the showcase (docs/CONTRACTS-V3.md), signed in as Camille. They take the screenshots 23 to 28
/// of the CI artifact on their way (scripts/ci/export-screenshots.sh); the other captures go to `debug/`. One test per
/// feature so that one failure does not lose the other captures.
final class SocialFlowTests: XCTestCase {
    /// « Payer le loyer » is overdue and assigned to Inès: « Relancer Inès » sends a nudge, a toast says so
    /// (23-relancer), and the button then says « Relance envoyée ».
    @MainActor
    func test23NudgeAnOverdueTask() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        ui.openTask(UITestDemo.payerLoyer)

        let nudge = ui.buttons(AccessibilityID.Social.nudgeButton)
        ui.waitForText(UITestSocial.nudgeTitle, of: nudge)
        let toast = ui.elements(AccessibilityID.Social.toast)
        ui.tap(nudge, "« \(UITestSocial.nudgeTitle) »", until: .shows(toast))
        ui.waitForText(UITestSocial.nudgeToast, of: toast)
        ui.capture("23-relancer")
        ui.waitForText(UITestSocial.nudgeDone, of: nudge)
    }

    /// « Membres » shows Inès's absence. Réglages › « Mode absent » previews that Lucas takes Camille's « Sortir les
    /// poubelles » of tonight (24-mode-absent); « Activer » closes the sheet with a toast, then Réglages and « Membres »
    /// show her absence.
    @MainActor
    func test24AwayMode() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        ui.openMembers()
        ui.waitFor(
            ui.elements(labelContaining: UITestDemo.inesName, UITestSocial.awayWord), "Inès away next week"
        )

        ui.openSettings()
        let handovers = ui.elements(AccessibilityID.Social.awayHandovers)
        ui.tap(ui.buttons(AccessibilityID.Social.settingsAwayRow), "« Mode absent »", until: .shows(handovers))
        ui.waitForContent(
            ui.elements(labelContaining: UITestDemo.sortirPoubelles, UITestSocial.awayHandover),
            "Lucas takes « \(UITestDemo.sortirPoubelles) »"
        )
        ui.capture("24-mode-absent")

        let save = ui.buttons(AccessibilityID.Social.awaySaveButton)
        ui.tapWhenEnabled(save, "« Activer le mode absent »", until: .hides(save))
        ui.waitFor(
            ui.elements(AccessibilityID.Social.toast, labelContaining: UITestSocial.awayToast), "« Mode absent activé »"
        )
        ui.waitFor(
            ui.elements(AccessibilityID.Social.settingsAwayRow, labelContaining: UITestSocial.awayWord),
            "Réglages: Camille away"
        )

        // « Membres » (still open in « Groupes ») shows it too.
        ui.openTab(AccessibilityID.Tabs.groupsTitle, identifier: AccessibilityID.Tabs.groups)
        ui.waitFor(
            ui.elements(labelContaining: UITestDemo.camilleName, UITestSocial.awayWord), "Camille away on « Membres »"
        )
        ui.capture("membres-absente")
    }

    /// Lucas proposed his turn of « Ranger le matériel » (« Projet Asso Sport ») to Camille: « Mes tâches » shows the
    /// proposal (25-echange-tour); « Accepter » makes it her turn, and the task joins her list.
    @MainActor
    func test25AcceptTheTurnProposedToCamille() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", for: self)
        ui.openMyTasks()
        ui.waitForContent(ui.elements(AccessibilityID.MyTasks.daySummary), "« Ta journée »")
        let proposal = ui.elements(AccessibilityID.Social.swapRequest(UITestSocial.materiel))
        ui.waitForContent(proposal, "Lucas's proposal")
        ui.capture("25-echange-tour")

        let accept = ui.buttons(AccessibilityID.Social.acceptSwap(UITestSocial.materiel))
        ui.tap(accept, "« Accepter »", until: .hides(accept))
        ui.waitFor(
            ui.elements(AccessibilityID.Social.toast, labelContaining: UITestSocial.swapToast), "« \(UITestSocial.swapToast) »"
        )
        ui.reveal(
            ui.elements(AccessibilityID.Tasks.row(UITestSocial.materiel)), "« \(UITestSocial.materiel) » in « Mes tâches »"
        )
    }

    /// « Activité »: Camille and Lucas applauded Inès's « Arroser les plantes » (👏 2, Camille's highlighted,
    /// 26-activite-reactions); a tap on 👏 removes Camille's at once (👏 1).
    @MainActor
    func test26ToggleAReaction() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        ui.showGroupTab("activity")
        ui.waitForContent(ui.elements(AccessibilityID.Groups.activityFeed), "the feed")

        let clapId = AccessibilityID.Social.reactionChip(UITestSocial.plants, UITestSocial.clapLabel)
        ui.reveal(ui.elements(clapId), "the 👏 of « \(UITestSocial.plants) »")
        ui.waitFor(ui.elements(clapId, value: UITestSocial.clapBefore), "👏 2, Camille's included")
        ui.capture("26-activite-reactions")

        ui.tap(ui.buttons(clapId), "👏", until: .shows(ui.elements(clapId, value: UITestSocial.clapAfter)))
    }

    /// « Faire les courses »: the two comments that mention Camille; « @Lu » suggests Lucas, and the comment sent
    /// mentions him (27-commentaires).
    @MainActor
    func test27CommentWithAMention() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        ui.openTask(UITestDemo.faireCourses)

        let field = ui.elements(AccessibilityID.Social.commentField)
        ui.typeText(UITestSocial.mentionTyped, into: field, "the comment field")
        let suggestion = ui.buttons(AccessibilityID.Social.mentionSuggestion("Lucas"))
        ui.tap(suggestion, "the suggestion « \(UITestSocial.mention) »", until: .hides(suggestion))
        ui.waitFor(
            ui.elements(AccessibilityID.Social.commentField, valueContaining: UITestSocial.mention),
            "« \(UITestSocial.mention) » in the field"
        )

        let sent = ui.elements(AccessibilityID.Social.comment, labelContaining: UITestSocial.mention)
        ui.tapWhenEnabled(
            ui.buttons(AccessibilityID.Social.commentSendButton), "« Envoyer »", until: .shows(sent)
        )
        ui.reveal(sent, "the comment sent")
        ui.capture("27-commentaires")
    }

    /// « Nettoyer le frigo », done by Camille, has a photo: its thumbnail opens it in full screen (28-photo-preuve).
    @MainActor
    func test28OpenThePhotoProof() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        // Only the done tasks: the card comes sooner.
        let done = ui.buttons(AccessibilityID.Groups.filterChip("done"))
        ui.tap(done, "« Terminées »", until: .selects(done))
        ui.openTask(UITestSocial.fridge)

        let thumbnail = ui.elements(AccessibilityID.Social.photoThumbnail(0))
        ui.reveal(thumbnail, "the photo of « \(UITestSocial.fridge) »")
        ui.capture("photo-preuve-tache")

        let viewer = ui.elements(AccessibilityID.Social.photoViewer)
        ui.tap(thumbnail, "the thumbnail", until: .shows(viewer))
        ui.waitForContent(viewer, "the photo in full screen")
        ui.capture("28-photo-preuve")

        ui.tap(ui.buttons(AccessibilityID.Social.photoViewerClose), "« Fermer »", until: .hides(viewer))
    }
}
