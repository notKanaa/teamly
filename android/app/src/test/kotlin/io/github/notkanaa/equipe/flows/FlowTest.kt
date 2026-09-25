package io.github.notkanaa.equipe.flows

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.mocks.InMemoryBackend
import io.github.notkanaa.equipe.mocks.MockClock
import io.github.notkanaa.equipe.mocks.MockScenario
import io.github.notkanaa.equipe.navigation.TabTestTags
import io.github.notkanaa.equipe.testing.DemoTime
import io.github.notkanaa.equipe.testing.EquipeUi
import io.github.notkanaa.equipe.testing.MockApp
import io.github.notkanaa.equipe.ui.auth.AuthTestTags
import io.github.notkanaa.equipe.ui.components.tasks.TaskTestTags
import io.github.notkanaa.equipe.ui.groups.GroupsTags
import io.github.notkanaa.equipe.ui.members.MembersTags
import io.github.notkanaa.equipe.ui.mytasks.MyTasksTestTags
import io.github.notkanaa.equipe.ui.settings.SettingsTestTags
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.milliseconds

/**
 * End-to-end flows through the real shell (`EquipeRoot` / `MainShell`) on the in-memory backend: the iOS
 * App/UITests/FlowTests.swift, plus sign-up, joining with a code, « Mes tâches » and its badge, the members' roles,
 * leaving a group, the password reset with the e-mailed code and the account deletion. French demo data, nothing
 * persisted between tests; the clock starts at the iOS captures' time and advances by 1 ms at every read (distinct
 * dates for successive changes, like successive transactions).
 */
@RunWith(AndroidJUnit4::class)
class FlowTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val ui = EquipeUi(compose)
    private var app: MockApp? = null

    @After
    fun tearDown() {
        app?.close()
    }

    private fun launch(scenario: MockScenario): MockApp =
        ui.launch(scenario, clock = MockClock(DemoTime.now, autoAdvance = 1.milliseconds)).also { app = it }

    // region Authentication

    /** signedOut → login with the demo account → the signed-in app shows Camille's two groups. */
    @Test
    fun signInWithTheDemoAccount() {
        launch(MockScenario.SIGNED_OUT)
        ui.signIn(DemoData.camille.email, DemoData.password)
        ui.waitForDemoGroups()
    }

    /** A wrong password keeps the login screen with the error. */
    @Test
    fun wrongPasswordShowsTheError() {
        launch(MockScenario.SIGNED_OUT)
        ui.replaceText(AuthTestTags.EMAIL, DemoData.camille.email)
        ui.type(AuthTestTags.PASSWORD, "mauvaismotdepasse")
        ui.tap(AuthTestTags.SIGN_IN)
        ui.waitFor(hasText(AppError.InvalidCredentials.message!!))
        ui.tap(hasText("OK"))
        assertTrue(ui.exists(AuthTestTags.LOGIN_SCREEN))
        assertFalse(ui.exists(TabTestTags.MY_TASKS))
    }

    /** « Créer un compte » → the account is created and signed in: the app opens on the « no group » state. */
    @Test
    fun signUpOpensTheApp() {
        val app = launch(MockScenario.SIGNED_OUT)
        ui.tap(AuthTestTags.GO_TO_SIGN_UP)
        ui.waitFor(AuthTestTags.SIGN_UP_SCREEN)
        ui.node(AuthTestTags.SIGN_UP).assertIsNotEnabled()
        ui.type(AuthTestTags.DISPLAY_NAME, "Alice Durand")
        ui.type(AuthTestTags.EMAIL, "alice@example.com")
        ui.type(AuthTestTags.PASSWORD, "motdepasse123")
        ui.tap(AuthTestTags.SIGN_UP)

        ui.waitForTabBar()
        ui.waitFor(GroupsTags.EMPTY)
        assertNotNull(app.backend.userId("alice@example.com"))
    }

    /** Réglages → « Se déconnecter » → confirmation → back to the login screen, without the tabs. */
    @Test
    fun signOut() {
        launch(MockScenario.POPULATED)
        ui.openTab(TabTestTags.SETTINGS)
        ui.waitFor(SettingsTestTags.DISPLAY_NAME_FIELD)

        ui.tap(SettingsTestTags.SIGN_OUT)
        ui.tap(SettingsTestTags.CONFIRM_SIGN_OUT)

        ui.waitFor(AuthTestTags.LOGIN_SCREEN)
        ui.waitFor(AuthTestTags.SIGN_IN)
        assertFalse("The tabs must be gone after signing out", ui.exists(TabTestTags.MY_TASKS))
    }

    /**
     * « Mot de passe oublié » → the code of the e-mail (mock: always 123456) → « Nouveau mot de passe » → the app
     * opens; the new password works for the next sign-in.
     */
    @Test
    fun passwordResetWithTheEmailedCode() {
        val app = launch(MockScenario.SIGNED_OUT)
        val email = DemoData.camille.email
        ui.replaceText(AuthTestTags.EMAIL, email)
        ui.tap(AuthTestTags.FORGOT_PASSWORD)
        ui.waitFor(AuthTestTags.RESET_SCREEN)
        // The e-mail of the login form is carried over.
        ui.waitForText(AuthTestTags.RESET_EMAIL, email)
        ui.tap(AuthTestTags.RESET_SEND_CODE)

        ui.waitFor(AuthTestTags.RESET_CODE)
        val code = app.backend.pendingRecoveryCode(email)
        assertEquals(InMemoryBackend.recoveryCode, code)
        ui.node(AuthTestTags.RESET_VERIFY_CODE).assertIsNotEnabled()
        ui.type(AuthTestTags.RESET_CODE, code!!)
        ui.tap(AuthTestTags.RESET_VERIFY_CODE)

        // Signed in with a recovery session: the « Nouveau mot de passe » step, full screen, before the app.
        ui.waitFor(AuthTestTags.NEW_PASSWORD)
        assertFalse(ui.exists(TabTestTags.MY_TASKS))
        val newPassword = "nouveaumotdepasse"
        ui.type(AuthTestTags.NEW_PASSWORD, newPassword)
        ui.type(AuthTestTags.NEW_PASSWORD_CONFIRMATION, newPassword)
        ui.tap(AuthTestTags.SAVE_NEW_PASSWORD)
        ui.waitForDemoGroups()

        // The new password is the account's password now.
        ui.openTab(TabTestTags.SETTINGS)
        ui.tap(SettingsTestTags.SIGN_OUT)
        ui.tap(SettingsTestTags.CONFIRM_SIGN_OUT)
        ui.signIn(email, newPassword)
        ui.waitForDemoGroups()
    }

    /** « Supprimer mon compte » needs « SUPPRIMER » typed; then the account is gone and the login screen is back. */
    @Test
    fun deleteTheAccount() {
        val app = launch(MockScenario.POPULATED)
        ui.openTab(TabTestTags.SETTINGS)
        ui.waitFor(SettingsTestTags.DISPLAY_NAME_FIELD)
        ui.tap(SettingsTestTags.DELETE_ACCOUNT)

        ui.waitFor(SettingsTestTags.DELETE_CONFIRMATION_FIELD)
        ui.node(SettingsTestTags.CONFIRM_DELETE_ACCOUNT).assertIsNotEnabled()
        ui.type(SettingsTestTags.DELETE_CONFIRMATION_FIELD, "SUPPRIME")
        ui.node(SettingsTestTags.CONFIRM_DELETE_ACCOUNT).assertIsNotEnabled()
        ui.type(SettingsTestTags.DELETE_CONFIRMATION_FIELD, "R")
        ui.node(SettingsTestTags.CONFIRM_DELETE_ACCOUNT).assertIsEnabled()
        ui.tap(SettingsTestTags.CONFIRM_DELETE_ACCOUNT)

        ui.waitFor(AuthTestTags.LOGIN_SCREEN)
        assertFalse(ui.exists(TabTestTags.MY_TASKS))
        assertNull(app.backend.userId(DemoData.camille.email))
        // Her groups stay for the others: « Coloc' rue des Lilas » still has Lucas and Inès.
        val inesGroups = app.backend.services(DemoData.ines.id).groups
        val lilasMembers = runBlocking { inesGroups.members(DemoData.lilasGroupId) }
        assertEquals(setOf(DemoData.lucas.id, DemoData.ines.id), lilasMembers.map { it.user.id }.toSet())
    }

    // endregion

    // region Groups

    /** « Créer » → the new group opens (its creator is admin) → its invite code → the group shows in the list. */
    @Test
    fun createGroupThenShowItsInviteCode() {
        val app = launch(MockScenario.POPULATED)
        ui.waitForDemoGroups()

        ui.tap(GroupsTags.CREATE)
        ui.node(GroupsTags.SAVE).assertIsNotEnabled()
        ui.type(GroupsTags.NAME_FIELD, "Club de lecture")
        ui.tap(GroupsTags.SAVE)
        ui.waitForGone(GroupsTags.NAME_FIELD)

        // The group screen: empty, with « Inviter avec un code » (the creator is admin).
        ui.waitFor(hasText("Club de lecture"))
        ui.waitFor(GroupsTags.EMPTY_TASKS)
        ui.tap(GroupsTags.INVITE)

        val groups = runBlocking { app.environment.services.groups.myGroups() }
        val created = groups.single { it.group.name == "Club de lecture" }
        assertEquals(MemberRole.ADMIN, created.myRole)
        val code = runBlocking { app.environment.services.groups.inviteCode(created.id) }
        ui.waitForText(GroupsTags.INVITE_CODE, code.formatted)
        assertTrue(code.formatted, Regex("[A-Z0-9]{4}-[A-Z0-9]{4}").matches(code.formatted))
        ui.tap(GroupsTags.DONE)
        ui.waitForGone(GroupsTags.INVITE_CODE)

        ui.goBack()
        ui.waitFor(GroupsTags.row("Club de lecture"))
    }

    /** A user of no group gets the empty state with its two actions. */
    @Test
    fun emptyGroupsShowsTheEmptyState() {
        launch(MockScenario.EMPTY_GROUPS)
        ui.waitForTabBar()
        ui.waitFor(GroupsTags.EMPTY)
        ui.waitFor(GroupsTags.EMPTY_CREATE)
        ui.waitFor(GroupsTags.EMPTY_JOIN)
    }

    /** « Rejoindre avec un code » → the code is formatted live → « Bienvenue ! » → « Ouvrir le groupe ». */
    @Test
    fun joinWithACode() {
        val app = launch(MockScenario.EMPTY_GROUPS)
        ui.tap(GroupsTags.EMPTY_JOIN)
        ui.node(GroupsTags.SAVE).assertIsNotEnabled()
        ui.type(GroupsTags.CODE_FIELD, DemoData.lilasInviteCode.lowercase())
        ui.waitForText(GroupsTags.CODE_FIELD, "LYLA-S234")
        ui.tap(GroupsTags.SAVE)

        ui.waitForText(GroupsTags.JOIN_RESULT, "Vous avez rejoint « ${DemoData.lilasGroupName} ».")
        ui.tap(GroupsTags.OPEN_GROUP)
        ui.waitFor(TaskTestTags.ADD_BUTTON)
        ui.waitFor(TaskTestTags.row("Payer le loyer"))
        val me = app.environment.signedInUser!!.id
        val members = runBlocking { app.environment.services.groups.members(DemoData.lilasGroupId) }
        assertEquals(MemberRole.MEMBER, members.single { it.user.id == me }.role)

        ui.goBack()
        ui.waitFor(GroupsTags.row(DemoData.lilasGroupName))
    }

    /**
     * « Rejoindre » with a well-formed but unknown code → « Code d’invitation invalide. »; the sheet stays open with
     * the code and nothing is joined.
     */
    @Test
    fun joinWithAnInvalidCodeShowsTheError() {
        launch(MockScenario.POPULATED)
        ui.waitForDemoGroups()
        ui.tap(GroupsTags.JOIN)
        ui.type(GroupsTags.CODE_FIELD, "ZZZZZZZZ")
        ui.waitForText(GroupsTags.CODE_FIELD, "ZZZZ-ZZZZ")
        ui.tap(GroupsTags.SAVE)

        ui.waitFor(hasText(AppError.InvalidCode.message!!))
        ui.tap(hasText("OK"))
        ui.waitForText(GroupsTags.CODE_FIELD, "ZZZZ-ZZZZ")
        assertFalse("An unknown code must not join a group", ui.exists(GroupsTags.JOIN_RESULT))
        ui.tap(GroupsTags.CANCEL)
        ui.waitForGone(GroupsTags.CODE_FIELD)
        ui.waitFor(GroupsTags.row(DemoData.lilasGroupName))
    }

    /** The admin names Inès admin from « Membres »; being no longer the only admin, she may leave the group. */
    @Test
    fun promoteAMember() {
        val app = launch(MockScenario.POPULATED)
        ui.waitForDemoGroups()
        ui.openGroup(DemoData.lilasGroupName)
        ui.tap(GroupsTags.MEMBERS)
        ui.waitFor(MembersTags.LIST)
        ui.reveal(MembersTags.LEAVE)
        ui.node(MembersTags.LEAVE).assertIsNotEnabled()

        val ines = DemoData.ines.displayName
        ui.tap(MembersTags.actions(ines))
        ui.tap(MembersTags.ROLE)
        ui.waitFor(hasContentDescription("Rôle : Admin") and hasAnyAncestor(hasTestTag(MembersTags.row(ines))))

        val members = runBlocking { app.environment.services.groups.members(DemoData.lilasGroupId) }
        assertEquals(MemberRole.ADMIN, members.single { it.user.id == DemoData.ines.id }.role)
        ui.reveal(MembersTags.LEAVE)
        ui.node(MembersTags.LEAVE).assertIsEnabled()
    }

    /** A member leaves « Projet Asso Sport » from « Membres »: back to the list, without the group. */
    @Test
    fun leaveAGroup() {
        val app = launch(MockScenario.POPULATED)
        ui.waitForDemoGroups()
        ui.openGroup(DemoData.sportGroupName)
        ui.tap(GroupsTags.MEMBERS)
        ui.tap(MembersTags.LEAVE)
        ui.tap(MembersTags.LEAVE_CONFIRM)

        ui.waitForGone(GroupsTags.row(DemoData.sportGroupName))
        ui.waitFor(GroupsTags.row(DemoData.lilasGroupName))
        assertFalse(ui.exists(MembersTags.LIST))
        val groups = runBlocking { app.environment.services.groups.myGroups() }
        assertFalse(groups.any { it.id == DemoData.sportGroupId })
    }

    // endregion

    // region Tasks

    /**
     * Camille (admin) creates a task in « Coloc' rue des Lilas » assigned to Inès and sets it « En cours »; Inès signs
     * in: the « Mes tâches » badge counts it, the task shows there as « Nouveau », and the badge clears once seen.
     */
    @Test
    fun createAnAssignedTaskChangeItsStatusAndFindItInMyTasks() {
        launch(MockScenario.POPULATED)
        ui.waitForDemoGroups()
        ui.openGroup(DemoData.lilasGroupName)

        val title = "Arroser les plantes"
        ui.tap(TaskTestTags.ADD_BUTTON)
        ui.type(TaskTestTags.TITLE_FIELD, title)
        ui.assign(DemoData.ines.displayName)
        ui.tap(TaskTestTags.SAVE_BUTTON)
        ui.waitForGone(TaskTestTags.TITLE_FIELD)

        ui.openTask(title)
        ui.waitFor(hasText(DemoData.ines.displayName))
        val inProgress = TaskTestTags.statusOption(TaskStatus.IN_PROGRESS)
        ui.tap(inProgress)
        ui.waitUntil("« En cours » selected") { ui.isOn(inProgress) }
        ui.goBack()
        ui.waitUntil("« $title » in progress on the group screen") {
            ui.textOf(TaskTestTags.row(title)).startsWith("$title, En cours")
        }

        ui.openTab(TabTestTags.SETTINGS)
        ui.tap(SettingsTestTags.SIGN_OUT)
        ui.tap(SettingsTestTags.CONFIRM_SIGN_OUT)
        ui.signIn(DemoData.ines.email, DemoData.password)

        // « Payer le loyer » and the new task, both assigned by Camille.
        ui.waitFor(hasContentDescription("Mes tâches, 2 nouvelles tâches"))
        ui.openTab(TabTestTags.MY_TASKS)
        ui.waitFor(MyTasksTestTags.LIST)
        ui.reveal(TaskTestTags.row(title))
        assertTrue(ui.textOf(TaskTestTags.row(title)).startsWith("$title, nouveau, En cours"))

        // Leaving « Mes tâches » marks everything as seen.
        ui.openTab(TabTestTags.GROUPS)
        ui.waitUntil("the badge to clear") { !ui.exists(hasContentDescription("nouvelle", substring = true)) }
    }

    /**
     * Inès (member) on a task created by Camille and assigned to her: she may change its status but neither edit nor
     * delete it. On her own task, « Modifier » is shown (so the first check is not vacuous).
     */
    @Test
    fun assigneeCanChangeTheStatusButNotEdit() {
        launch(MockScenario.SIGNED_OUT)
        ui.signIn(DemoData.ines.email, DemoData.password)
        ui.openGroup(DemoData.lilasGroupName)
        assertFalse("A member must not see the invite code", ui.exists(GroupsTags.INVITE))

        ui.openTask("Payer le loyer")
        val inProgress = TaskTestTags.statusOption(TaskStatus.IN_PROGRESS)
        ui.waitFor(inProgress)
        assertFalse("An assignee must not edit the task", ui.exists(TaskTestTags.EDIT_BUTTON))
        ui.tap(inProgress)
        ui.waitUntil("« En cours » selected") { ui.isOn(inProgress) }
        assertFalse("An assignee must not delete the task", ui.exists(TaskTestTags.DELETE_BUTTON))

        ui.goBack()
        ui.waitUntil("« Payer le loyer » in progress") {
            ui.textOf(TaskTestTags.row("Payer le loyer")).startsWith("Payer le loyer, En cours")
        }
        ui.openTask("Réparer la fuite du lavabo")
        ui.waitFor(TaskTestTags.EDIT_BUTTON)
    }

    // endregion
}
