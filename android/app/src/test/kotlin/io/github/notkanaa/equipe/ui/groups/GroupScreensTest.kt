package io.github.notkanaa.equipe.ui.groups

import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.viewmodel.AppRoute
import io.github.notkanaa.equipe.core.viewmodel.Router
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.mocks.MockScenario
import io.github.notkanaa.equipe.testing.mockSession
import io.github.notkanaa.equipe.ui.members.MembersScreen
import io.github.notkanaa.equipe.ui.theme.EquipeTheme
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/**
 * The screens of the « Groupes » tab and « Membres » (real view models on the in-memory backend), each composed alone
 * and driven through its UI: navigation requests, sheets, filters, menus, dialogs and the resulting backend state.
 */
@RunWith(AndroidJUnit4::class)
class GroupScreensTest {
    @get:Rule
    val compose = createComposeRule()

    private val lilas = DemoData.lilasGroupId
    private val sport = DemoData.sportGroupId

    private fun session(scenario: MockScenario = MockScenario.POPULATED): SessionModel = mockSession(scenario)

    private fun show(content: @Composable () -> Unit) {
        compose.setContent { EquipeTheme(darkTheme = false, content = content) }
        settle()
    }

    private fun settle() {
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
    }

    /** Composes (scrolls to) a lazy item of the list [listTag]. */
    private fun reveal(listTag: String, tag: String) {
        compose.onNodeWithTag(listTag).performScrollToNode(hasTestTag(tag))
        settle()
    }

    private fun click(tag: String) {
        val node = compose.onNodeWithTag(tag)
        try {
            node.performScrollTo()
        } catch (error: AssertionError) {
            // Not inside a scrollable container (dialog button, sheet header).
        }
        node.performClick()
        settle()
    }

    @Test
    fun tappingAGroupShowsIt() {
        val router = Router()
        show { GroupsListScreen(session(), router) }
        click(GroupsTags.row(DemoData.lilasGroupName))
        assertEquals(listOf<AppRoute>(AppRoute.Group(lilas)), router.state.value.groupsPath)
    }

    @Test
    fun emptyStateOpensTheSheets() {
        show { GroupsListScreen(session(MockScenario.EMPTY_GROUPS), Router()) }
        click(GroupsTags.EMPTY_JOIN)
        compose.onNodeWithTag(GroupsTags.CODE_FIELD).assertExists()
    }

    @Test
    fun createdGroupIsHandedOver() {
        var created: GroupSummary? = null
        show { CreateGroupSheet(session(), onDismiss = {}, onCreated = { created = it }) }
        compose.onNodeWithTag(GroupsTags.SAVE).assertIsNotEnabled()
        compose.onNodeWithTag(GroupsTags.NAME_FIELD).performTextInput("  Club de lecture ")
        settle()
        compose.onNodeWithContentDescription("15 caractères sur 60").assertExists()
        click(GroupsTags.SAVE)
        assertEquals("Club de lecture", created?.group?.name)
        assertEquals(MemberRole.ADMIN, created?.myRole)
    }

    @Test
    fun tooLongNameShowsTheValidationMessage() {
        var created: GroupSummary? = null
        show { CreateGroupSheet(session(), onDismiss = {}, onCreated = { created = it }) }
        compose.onNodeWithTag(GroupsTags.NAME_FIELD).performTextInput("x".repeat(61))
        settle()
        compose.onNodeWithContentDescription("61 caractères sur 60").assertExists()
        click(GroupsTags.SAVE)
        compose.onNodeWithTag(GroupsTags.NAME_ERROR).assertExists()
        assertEquals(null, created)
    }

    @Test
    fun joinFormatsTheCodeAndOpensTheGroup() {
        var opened: UUID? = null
        show { JoinGroupSheet(session(MockScenario.EMPTY_GROUPS), onDismiss = {}, onOpenGroup = { opened = it }) }
        compose.onNodeWithTag(GroupsTags.CODE_FIELD).performTextInput("lyla s-2")
        settle()
        compose.onNodeWithText("LYLA-S2").assertExists()
        compose.onNodeWithTag(GroupsTags.SAVE).assertIsNotEnabled()
        compose.onNodeWithTag(GroupsTags.CODE_FIELD).performTextInput("34")
        settle()
        compose.onNodeWithTag(GroupsTags.SAVE).assertIsEnabled()
        click(GroupsTags.SAVE)
        compose.onNodeWithText("Vous avez rejoint « ${DemoData.lilasGroupName} ».").assertExists()
        click(GroupsTags.OPEN_GROUP)
        assertEquals(lilas, opened)
    }

    @Test
    fun joiningAgainSaysAlreadyMember() {
        show { JoinGroupSheet(session(), onDismiss = {}, onOpenGroup = {}) }
        compose.onNodeWithTag(GroupsTags.CODE_FIELD).performTextInput(DemoData.lilasInviteCode)
        settle()
        click(GroupsTags.SAVE)
        compose.onNodeWithText("Déjà membre").assertExists()
    }

    @Test
    fun invalidCodeShowsTheError() {
        show { JoinGroupSheet(session(MockScenario.EMPTY_GROUPS), onDismiss = {}, onOpenGroup = {}) }
        compose.onNodeWithTag(GroupsTags.CODE_FIELD).performTextInput("ZZZZ2222")
        settle()
        click(GroupsTags.SAVE)
        compose.onNodeWithText("Code d’invitation invalide.").assertExists()
    }

    @Test
    fun groupScreenNavigatesToMembersAndTasks() {
        val router = Router().apply { showGroup(lilas) }
        show { GroupDetailScreen(lilas, session(), router) }
        click(GroupsTags.MEMBERS)
        click(GroupsTags.MEMBERS) // Second tap: no second push.
        assertEquals(listOf(AppRoute.Group(lilas), AppRoute.Members(lilas)), router.state.value.groupsPath)
        router.pop()
        click(GroupsTags.taskRow("Payer le loyer"))
        assertEquals(
            listOf(AppRoute.Group(lilas), AppRoute.Task(lilas, DemoData.TaskIds.payerLoyer)),
            router.state.value.groupsPath,
        )
    }

    @Test
    fun filterChipsFilterAndReset() {
        show { GroupDetailScreen(lilas, session(), Router()) }
        compose.onNodeWithText("5 tâches").assertExists()
        click(GroupsTags.filterChip("todo"))
        compose.onNodeWithText("3 tâches sur 5").assertExists()
        click(GroupsTags.filterChip("done"))
        click(GroupsTags.filterChip("overdue"))
        compose.onNodeWithText("Aucun résultat").assertExists()
        click(GroupsTags.RESET_FILTER)
        compose.onNodeWithText("5 tâches").assertExists()
    }

    @Test
    fun renameThenDeleteTheGroup() {
        val session = session()
        val router = Router().apply { showGroup(lilas) }
        show { GroupDetailScreen(lilas, session, router) }
        click(GroupsTags.DETAIL_MENU)
        click(GroupsTags.RENAME)
        compose.onNodeWithTag(GroupsTags.RENAME_FIELD).performTextClearance()
        compose.onNodeWithTag(GroupsTags.RENAME_FIELD).performTextInput("Coloc des Lilas")
        click(GroupsTags.RENAME_CONFIRM)
        val renamed = runBlocking { session.services.groups.myGroups() }.first { it.id == lilas }
        assertEquals("Coloc des Lilas", renamed.group.name)

        click(GroupsTags.DETAIL_MENU)
        click(GroupsTags.DELETE)
        click(GroupsTags.DELETE_CONFIRM)
        assertFalse(runBlocking { session.services.groups.myGroups() }.any { it.id == lilas })
        assertEquals(emptyList<AppRoute>(), router.state.value.groupsPath)
    }

    @Test
    fun memberCannotSeeAdminActions() {
        show { GroupDetailScreen(sport, session(), Router()) }
        compose.onNodeWithTag(GroupsTags.INVITE).assertDoesNotExist()
        click(GroupsTags.DETAIL_MENU)
        compose.onNodeWithTag(GroupsTags.RENAME).assertDoesNotExist()
        compose.onNodeWithTag(GroupsTags.DELETE).assertDoesNotExist()
        compose.onNodeWithTag(GroupsTags.MENU_MEMBERS).assertExists()
    }

    @Test
    fun inviteSheetRegeneratesTheCode() {
        val session = session()
        show { InviteCodeSheet(lilas, session, onDismiss = {}) }
        compose.onNodeWithTag(GroupsTags.INVITE_CODE).assertExists()
        click(GroupsTags.REGENERATE_CODE)
        click(GroupsTags.REGENERATE_CONFIRM)
        val code = runBlocking { session.services.groups.inviteCode(lilas) }
        assertNotEquals(DemoData.lilasInviteCode, code.value)
        compose.onNodeWithText(code.formatted).assertExists()
    }

    @Test
    fun lastAdminCannotLeaveButCanPromote() {
        val session = session()
        show { MembersScreen(lilas, session, Router()) }
        reveal("members.list", "members.leave")
        compose.onNodeWithTag("members.leave").assertIsNotEnabled()
        compose.onNodeWithText("Vous êtes le seul admin : nommez d’abord un autre admin.").assertExists()
        reveal("members.list", "members.actions.${DemoData.ines.displayName}")
        click("members.actions.${DemoData.ines.displayName}")
        click("members.role")
        reveal("members.list", "members.leave")
        val ines = runBlocking { session.services.groups.members(lilas) }.first { it.user.id == DemoData.ines.id }
        assertEquals(MemberRole.ADMIN, ines.role)
        compose.onNodeWithTag("members.leave").assertIsEnabled()
    }

    @Test
    fun removingAMemberAsksFirst() {
        val session = session()
        show { MembersScreen(lilas, session, Router()) }
        reveal("members.list", "members.actions.${DemoData.lucas.displayName}")
        click("members.actions.${DemoData.lucas.displayName}")
        click("members.remove")
        compose.onNodeWithText("Retirer ce membre ?").assertExists()
        click("members.removeConfirm")
        assertFalse(runBlocking { session.services.groups.members(lilas) }.any { it.user.id == DemoData.lucas.id })
        compose.onNodeWithTag("members.row.${DemoData.lucas.displayName}").assertDoesNotExist()
    }

    @Test
    fun statusButtonCyclesTheStatus() {
        val session = session()
        show { GroupDetailScreen(lilas, session, Router()) }
        compose.onNode(hasTestTag("tasks.status") and hasAnyAncestor(hasTestTag("tasks.row.Payer le loyer")))
            .performClick()
        settle()
        val task = runBlocking { session.services.tasks.task(DemoData.TaskIds.payerLoyer) }
        assertEquals(TaskStatus.IN_PROGRESS, task.status)
    }

    @Test
    fun longPressDeletesATaskAfterConfirmation() {
        val session = session()
        show { GroupDetailScreen(lilas, session, Router()) }
        compose.onNodeWithTag("tasks.row.Payer le loyer").performTouchInput { longClick() }
        settle()
        click(GroupsTags.TASK_DELETE)
        compose.onNodeWithText("Supprimer cette tâche ?").assertExists()
        click(GroupsTags.DELETE_TASK_CONFIRM)
        val tasks = runBlocking { session.services.tasks.tasks(lilas, false) }
        assertFalse(tasks.any { it.id == DemoData.TaskIds.payerLoyer })
        compose.onNodeWithText("4 tâches").assertExists()
    }

    @Test
    fun editorOpensFromTheMenuAndFromPlus() {
        show { GroupDetailScreen(lilas, session(), Router()) }
        compose.onNodeWithTag("tasks.row.Payer le loyer").performTouchInput { longClick() }
        settle()
        click(GroupsTags.TASK_EDIT)
        compose.onNodeWithTag("tasks.titleField").assertExists()
        compose.onNodeWithText("Modifier la tâche").assertExists()
        click("tasks.cancel")
        click(GroupsTags.TASKS_ADD)
        compose.onNodeWithText("Nouvelle tâche").assertExists()
    }

    @Test
    fun leavingRemovesTheGroupScreens() {
        val session = session()
        val router = Router().apply { showMembers(sport) }
        show { MembersScreen(sport, session, router) }
        click("members.leave")
        click("members.leaveConfirm")
        assertFalse(runBlocking { session.services.groups.myGroups() }.any { it.id == sport })
        assertTrue(router.state.value.groupsPath.isEmpty())
    }
}
