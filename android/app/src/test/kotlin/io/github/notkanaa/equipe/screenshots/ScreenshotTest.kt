package io.github.notkanaa.equipe.screenshots

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.mocks.MockScenario
import io.github.notkanaa.equipe.navigation.TabTestTags
import io.github.notkanaa.equipe.testing.EquipeUi
import io.github.notkanaa.equipe.testing.MockApp
import io.github.notkanaa.equipe.testing.capture
import io.github.notkanaa.equipe.ui.auth.AuthTestTags
import io.github.notkanaa.equipe.ui.components.tasks.TaskTestTags
import io.github.notkanaa.equipe.ui.groups.GroupsTags
import io.github.notkanaa.equipe.ui.members.MembersTags
import io.github.notkanaa.equipe.ui.mytasks.MyTasksTestTags
import io.github.notkanaa.equipe.ui.settings.SettingsTestTags
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The screenshots of the iOS suite (App/UITests/ScreenshotTests.swift), with the same file names: 01-connexion.png …
 * 10-reglages-compte.png, written to app/build/outputs/roborazzi. Also the dark variants of 02, 06 and 07 (`-sombre`)
 * and 07 at font scale 1.8 (`-police-xl`).
 *
 * The whole app (`EquipeRoot`: login screen, then `MainShell`) on the in-memory backend, driven through its test tags
 * like the iOS UI tests: signed in as Camille (admin of « Coloc' rue des Lilas ») except for the login screen, clock
 * fixed at the iOS captures' time, a 411 × 891 dp phone (robolectric.properties). Each capture waits for the screen's
 * real content; one test per screen (or pair of screens), like iOS.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ScreenshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val ui = EquipeUi(compose)
    private var app: MockApp? = null

    @After
    fun tearDown() {
        app?.close()
    }

    private fun launch(scenario: MockScenario) {
        app = ui.launch(scenario)
    }

    @Test
    fun test01Login() {
        launch(MockScenario.SIGNED_OUT)
        ui.waitFor(AuthTestTags.LOGIN_SCREEN)
        ui.waitFor(AuthTestTags.EMAIL)
        ui.waitFor(AuthTestTags.SIGN_IN)
        capture("01-connexion")
    }

    @Test
    fun test02GroupsAndCreateGroup() {
        launch(MockScenario.POPULATED)
        ui.waitForDemoGroups()
        capture("02-groupes")

        ui.tap(GroupsTags.CREATE)
        ui.type(GroupsTags.NAME_FIELD, "Club de lecture")
        // The typed name is taken into account once « Créer » is enabled.
        ui.node(GroupsTags.SAVE).assertIsEnabled()
        capture("03-creer-groupe")
    }

    @Test
    fun test04InviteCode() {
        launch(MockScenario.POPULATED)
        ui.waitForDemoGroups()
        ui.openGroup(DemoData.lilasGroupName)
        ui.tap(GroupsTags.INVITE)
        ui.waitFor(GroupsTags.DONE)
        ui.waitForText(GroupsTags.INVITE_CODE, "LYLA-S234")
        capture("04-code-invitation")
    }

    @Test
    fun test05NewTask() {
        launch(MockScenario.POPULATED)
        ui.waitForDemoGroups()
        ui.openGroup(DemoData.lilasGroupName)

        ui.tap(TaskTestTags.ADD_BUTTON)
        ui.type(TaskTestTags.TITLE_FIELD, "Arroser les plantes")
        ui.type(TaskTestTags.DETAILS_FIELD, "Deux fois par semaine, sans oublier le balcon.")
        ui.assign(DemoData.ines.displayName)
        ui.tap(TaskTestTags.priorityOption(TaskPriority.HIGH))
        ui.tap(TaskTestTags.DUE_DATE_TOGGLE)
        // Back to the top of the form (like iOS `scrollToTop`).
        ui.reveal(TaskTestTags.TITLE_FIELD)
        ui.waitFor(TaskTestTags.SAVE_BUTTON)
        capture("05-nouvelle-tache")
    }

    @Test
    fun test06GroupDetail() {
        groupDetail()
        capture("06-detail-groupe")
    }

    @Test
    fun test07MyTasks() {
        myTasks()
        capture("07-mes-taches")
    }

    @Test
    fun test08Members() {
        launch(MockScenario.POPULATED)
        ui.waitForDemoGroups()
        ui.openGroup(DemoData.lilasGroupName)
        ui.tap(GroupsTags.MEMBERS)
        ui.waitFor(MembersTags.LIST)
        ui.waitFor(MembersTags.row(DemoData.camille.displayName))
        ui.waitFor(MembersTags.row(DemoData.ines.displayName))
        ui.waitFor(MembersTags.INVITE_CODE)
        capture("08-membres")
    }

    @Test
    fun test09Settings() {
        launch(MockScenario.POPULATED)
        ui.openTab(TabTestTags.SETTINGS)
        // Only shown once the profile is loaded.
        ui.waitFor(SettingsTestTags.DISPLAY_NAME_FIELD)
        ui.waitFor(SettingsTestTags.EMAIL)
        capture("09-reglages")

        // The « Compte » section is below the first screen: scrolled into view (down to « Version », under it) for its
        // own capture.
        ui.reveal(SettingsTestTags.VERSION)
        ui.node(SettingsTestTags.DELETE_ACCOUNT).assertIsDisplayed()
        capture("10-reglages-compte")
    }

    @Test
    @Config(qualifiers = "+night")
    fun test02GroupsDark() {
        launch(MockScenario.POPULATED)
        ui.waitForDemoGroups()
        capture("02-groupes-sombre")
    }

    @Test
    @Config(qualifiers = "+night")
    fun test06GroupDetailDark() {
        groupDetail()
        capture("06-detail-groupe-sombre")
    }

    @Test
    @Config(qualifiers = "+night")
    fun test07MyTasksDark() {
        myTasks()
        capture("07-mes-taches-sombre")
    }

    /** « Mes tâches » at font scale 1.8 (large text is scaled less than 1.8 times: Android 14+ non-linear scaling). */
    @Test
    @Config(fontScale = 1.8f)
    fun test07MyTasksLargeFont() {
        myTasks()
        capture("07-mes-taches-police-xl")
    }

    private fun groupDetail() {
        launch(MockScenario.POPULATED)
        ui.waitForDemoGroups()
        ui.openGroup(DemoData.lilasGroupName)
        ui.waitFor(GroupsTags.MEMBERS)
        ui.waitFor(TaskTestTags.row("Payer le loyer"))
    }

    private fun myTasks() {
        launch(MockScenario.POPULATED)
        ui.openTab(TabTestTags.MY_TASKS)
        ui.waitFor(MyTasksTestTags.LIST)
        ui.waitFor(TaskTestTags.row("Faire les courses"))
        ui.waitFor(TaskTestTags.row("Réserver le gymnase"))
    }
}
