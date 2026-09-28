import XCTest

// Helpers and data of the v3 social flows (App/UITests/SocialFlowTests.swift). They only build on the public helpers of
// EquipeApp.swift: queries by identifier, `reveal` (never `isHittable`), coordinate taps, outcomes.

/// The v3 content of the showcase (TeamTasksMocks `DemoData.Showcase`), seen by Camille.
enum UITestSocial {
    /// « Relancer » on « Payer le loyer » (overdue, assigned to Inès).
    static let nudgeTitle = "Relancer Inès"
    static let nudgeToast = "Relance envoyée à Inès"
    static let nudgeDone = "Relance envoyée"
    /// The badge of an absence (« Absent·e du 5 au 11 oct. »).
    static let awayWord = "Absent\u{00B7}e"
    /// Who takes Camille's « Sortir les poubelles » while she is away.
    static let awayHandover = "Lucas le fera"
    static let awayToast = "Mode absent activé"
    /// Lucas proposes his turn of « Ranger le matériel » (« Projet Asso Sport ») to Camille.
    static let materiel = "Ranger le matériel"
    static let swapToast = "Tu prends le tour de Lucas"
    /// Camille and Lucas applaud Inès's « Arroser les plantes ».
    static let plants = "Arroser les plantes"
    /// `ReactionEmoji.clap.label`.
    static let clapLabel = "Bravo"
    static let clapBefore = "2 réactions, dont la tienne"
    static let clapAfter = "1 réaction"
    /// Typed in the comment of « Faire les courses », then completed with the suggestion « @Lucas ».
    static let mentionTyped = "Merci @Lu"
    static let mention = "@Lucas"
    /// The done task with a photo.
    static let fridge = "Nettoyer le frigo"
}

@MainActor
extension EquipeApp {
    /// From the group screen: the members link of the hero, until « Membres » shows.
    func openMembers(file: StaticString = #filePath, line: UInt = #line) {
        let list = elements(AccessibilityID.Members.list)
        tapRow(AccessibilityID.Groups.membersButton, "the « Membres » row", until: .shows(list), file: file, line: line)
        waitForContent(
            elements(AccessibilityID.Members.row(UITestDemo.camilleName)), "Camille's row", file: file, line: line
        )
    }

    /// Every element with this identifier whose value contains `text`.
    func elements(_ identifier: String, valueContaining text: String) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@", identifier, text))
    }
}
