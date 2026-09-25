import XCTest

/// The screenshots of the v2 groups screens, on the `showcase` content (signed in as Camille, admin of « Coloc' rue des
/// Lilas »): 15-groupe-vitrine, 16-groupe-activite, 17-groupe-apparence, and the dark variants 02-groupes-sombre and
/// 16-groupe-activite-sombre. scripts/ci/export-screenshots.sh exports them by name, like the 14 of `ScreenshotTests`;
/// the other captures (the dark group screen, the largest text size) go to `debug/`. One test per screen so that one
/// failure does not lose the other captures.
final class GroupsScreenshotTests: XCTestCase {
    @MainActor
    func test02GroupsDark() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", appearance: .dark, for: self)
        ui.waitForDemoGroups()
        ui.waitForContent(ui.elements(AccessibilityID.Groups.headerSummary), "the summary under the title")
        ui.capture("02-groupes-sombre")
    }

    /// « Coloc' rue des Lilas »: « À qui le tour ? » (Camille's turn), the filter chips and the task cards.
    @MainActor
    func test15ShowcaseGroup() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        ui.waitForContent(ui.elements(AccessibilityID.Groups.turnCard(UITestDemo.sortirPoubelles)), "the turn card")
        ui.waitForContent(ui.elements(AccessibilityID.Tasks.row(UITestDemo.payerLoyer)), "the first task")
        ui.capture("15-groupe-vitrine")

        // Scrolled: the hero's identity under the pinned bar, which then shows the group's name (debug capture).
        for _ in 0..<2 {
            ui.scroll(.towardsBottom)
        }
        ui.capture("groupe-vitrine-defilee")
    }

    /// « Activité »: the week's recap with the podium and the streak, then the feed.
    @MainActor
    func test16Activity() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        ui.showGroupTab("activity")
        ui.waitForContent(ui.elements(AccessibilityID.Groups.activityPodium), "the podium")
        ui.waitForContent(ui.elements(AccessibilityID.Groups.activityFeed), "the feed")
        ui.capture("16-groupe-activite")
    }

    /// The group screen, then « Activité », in dark mode.
    @MainActor
    func test16ActivityDark() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", appearance: .dark, for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        ui.waitForContent(ui.elements(AccessibilityID.Groups.turnCard(UITestDemo.sortirPoubelles)), "the turn card")
        ui.capture("groupe-vitrine-sombre")

        ui.showGroupTab("activity")
        ui.waitForContent(ui.elements(AccessibilityID.Groups.activityPodium), "the podium")
        ui.waitForContent(ui.elements(AccessibilityID.Groups.activityFeed), "the feed")
        ui.capture("16-groupe-activite-sombre")
    }

    /// « … » → « Apparence »: 🎉 on violet in the preview.
    @MainActor
    func test17Appearance() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", for: self)
        ui.waitForDemoGroups()
        ui.openGroup(UITestDemo.lilasGroup)
        ui.openGroupAppearance()
        ui.select(ui.buttons(AccessibilityID.Picker.emoji(UITestDemo.partyEmoji)), "the party emoji")
        ui.select(ui.buttons(AccessibilityID.Picker.color("violet")), "the violet swatch")
        let preview = ui.elements(AccessibilityID.Groups.appearancePreview)
        ui.scrollToTop(until: preview)
        ui.waitForText("\(UITestDemo.partyEmoji), violet", of: preview)
        ui.capture("17-groupe-apparence")
    }

    /// Design check (docs/DESIGN-V2.md §1): the groups list, the group screen and « Activité » at the largest
    /// accessibility text size (AX5), to be looked at under `debug/`.
    @MainActor
    func testGroupScreensLargestText() {
        let ui = EquipeApp.launch(.showcase, notifications: "authorized", appearance: .largestText, for: self)
        ui.waitForDemoGroups()
        ui.capture("ax-groupes")

        ui.openGroup(UITestDemo.lilasGroup)
        ui.capture("ax-groupe-haut")
        ui.showGroupTab("activity")
        ui.waitForContent(ui.elements(AccessibilityID.Groups.activityPodium), "the podium")
        ui.capture("ax-activite-haut")
        for _ in 0..<2 {
            ui.scroll(.towardsBottom)
        }
        ui.capture("ax-activite-bas")
    }
}
