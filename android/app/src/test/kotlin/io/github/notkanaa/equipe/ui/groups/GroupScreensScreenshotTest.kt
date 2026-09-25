package io.github.notkanaa.equipe.ui.groups

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.GroupService
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.viewmodel.Router
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.mocks.MockScenario
import io.github.notkanaa.equipe.testing.capture
import io.github.notkanaa.equipe.testing.mockSession
import io.github.notkanaa.equipe.ui.members.MembersScreen
import io.github.notkanaa.equipe.ui.theme.EquipeTheme
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.GraphicsMode
import java.util.UUID

/**
 * Screenshots of the « Groupes » tab and « Membres » composed alone (real view models on the in-memory backend) in
 * states the app-level suite does not reach: dark mode, font scale 1.8, empty and failed states, sheets, menus and
 * dialogs. Written to app/build/outputs/roborazzi/groups/.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class GroupScreensScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private fun session(
        scenario: MockScenario = MockScenario.POPULATED,
        transform: (AppServices) -> AppServices = { it },
    ): SessionModel = mockSession(scenario, transform = transform)

    private enum class Theme { LIGHT, DARK }

    private fun render(theme: Theme = Theme.LIGHT, fontScale: Float = 1f, content: @Composable () -> Unit) {
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                EquipeTheme(darkTheme = theme == Theme.DARK) {
                    Surface(color = MaterialTheme.colorScheme.background, content = content)
                }
            }
        }
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(2_000)
        compose.waitForIdle()
    }

    private fun shoot(name: String) {
        capture("groups/$name")
    }

    @Test
    fun groupsListLight() {
        render { GroupsListScreen(session(), Router()) }
        shoot("01-groups-light")
    }

    @Test
    fun groupsListDark() {
        render(Theme.DARK) { GroupsListScreen(session(), Router()) }
        shoot("02-groups-dark")
    }

    @Test
    fun groupsListLargeFont() {
        render(fontScale = 1.8f) { GroupsListScreen(session(), Router()) }
        shoot("03-groups-font18")
    }

    @Test
    fun groupsListEmptyBaseline() {
        render { GroupsListScreen(session(MockScenario.EMPTY_GROUPS), Router()) }
        shoot("04-groups-empty")
    }

    @Test
    fun groupDetailLight() {
        render { GroupDetailScreen(DemoData.lilasGroupId, session(), Router()) }
        shoot("05-detail-light")
    }

    @Test
    fun groupDetailDark() {
        render(Theme.DARK) { GroupDetailScreen(DemoData.lilasGroupId, session(), Router()) }
        shoot("06-detail-dark")
    }

    @Test
    fun groupDetailMemberLargeFont() {
        render(fontScale = 1.8f) { GroupDetailScreen(DemoData.sportGroupId, session(), Router()) }
        shoot("07-detail-sport-font18")
    }

    @Test
    fun membersAdminLight() {
        render { MembersScreen(DemoData.lilasGroupId, session(), Router()) }
        shoot("08-members-admin-light")
    }

    @Test
    fun membersMemberDark() {
        render(Theme.DARK) { MembersScreen(DemoData.sportGroupId, session(), Router()) }
        shoot("09-members-member-dark")
    }

    @Test
    fun membersLargeFont() {
        render(fontScale = 1.8f) { MembersScreen(DemoData.lilasGroupId, session(), Router()) }
        shoot("10-members-font18")
    }

    @Test
    fun createSheet() {
        render { CreateGroupSheet(session(), onDismiss = {}, onCreated = {}) }
        compose.onNodeWithTag(GroupsTags.NAME_FIELD).performTextInput("Club de lecture")
        compose.waitForIdle()
        shoot("11-create-sheet")
    }

    @Test
    fun joinSheet() {
        render { JoinGroupSheet(session(), onDismiss = {}, onOpenGroup = {}) }
        compose.onNodeWithTag(GroupsTags.CODE_FIELD).performTextInput("lyl a-s2")
        compose.waitForIdle()
        shoot("12-join-sheet")
    }

    @Test
    fun inviteSheetDark() {
        render(Theme.DARK) { InviteCodeSheet(DemoData.lilasGroupId, session(), onDismiss = {}) }
        shoot("13-invite-sheet-dark")
    }

    @Test
    fun detailMenu() {
        render { GroupDetailScreen(DemoData.lilasGroupId, session(), Router()) }
        compose.onNodeWithTag(GroupsTags.DETAIL_MENU).performClick()
        compose.waitForIdle()
        shoot("14-detail-menu")
    }

    @Test
    fun renameDialog() {
        render { GroupDetailScreen(DemoData.lilasGroupId, session(), Router()) }
        compose.onNodeWithTag(GroupsTags.DETAIL_MENU).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(GroupsTags.RENAME).performClick()
        compose.waitForIdle()
        shoot("15-rename-dialog")
    }

    @Test
    fun noMatch() {
        render { GroupDetailScreen(DemoData.lilasGroupId, session(), Router()) }
        compose.onNodeWithTag(GroupsTags.filterChip("done")).performClick()
        compose.onNodeWithTag(GroupsTags.filterChip("overdue")).performScrollTo().performClick()
        compose.waitForIdle()
        shoot("16-no-match")
    }

    @Test
    fun emptyGroup() {
        val session = session()
        val group = runBlocking { session.services.groups.createGroup("Club de lecture") }
        render { GroupDetailScreen(group.id, session, Router()) }
        shoot("17-empty-group")
    }

    @Test
    fun joinResult() {
        render { JoinGroupSheet(session(MockScenario.EMPTY_GROUPS), onDismiss = {}, onOpenGroup = {}) }
        compose.onNodeWithTag(GroupsTags.CODE_FIELD).performTextInput(DemoData.lilasInviteCode.lowercase())
        compose.waitForIdle()
        compose.onNodeWithTag(GroupsTags.SAVE).performClick()
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
        shoot("18-join-result")
    }

    @Test
    fun memberActions() {
        render { MembersScreen(DemoData.lilasGroupId, session(), Router()) }
        compose.onNodeWithTag("members.actions.${DemoData.ines.displayName}").performClick()
        compose.waitForIdle()
        shoot("19-member-actions")
    }

    @Test
    fun failedLoad() {
        val failing = { services: AppServices ->
            services.copy(
                groups = object : GroupService by services.groups {
                    override suspend fun myGroups(): List<GroupSummary> = throw AppError.Network
                },
            )
        }
        render(Theme.DARK) { GroupsListScreen(session(transform = failing), Router()) }
        shoot("20-failed-load-dark")
    }

    @Test
    fun collapseThenReexpand() {
        render { GroupDetailScreen(DemoData.lilasGroupId, session(), Router()) }
        compose.onNodeWithTag(GroupsTags.TASKS_LIST).performTouchInput { swipeUp() }
        compose.waitForIdle()
        shoot("22-detail-collapsed")
        compose.onNodeWithTag(GroupsTags.TASKS_LIST).performTouchInput { swipeDown(durationMillis = 800) }
        compose.mainClock.advanceTimeBy(2_000)
        compose.waitForIdle()
        shoot("23-detail-reexpanded")
    }

    @Test
    fun goneGroup() {
        render { GroupDetailScreen(UUID.randomUUID(), session(), Router()) }
        shoot("21-gone")
    }
}
