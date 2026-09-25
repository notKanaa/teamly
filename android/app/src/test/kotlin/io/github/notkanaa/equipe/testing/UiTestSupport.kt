package io.github.notkanaa.equipe.testing

import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.hasAnySibling
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.printToString
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.captureScreenRoboImage
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.mocks.MockClock
import io.github.notkanaa.equipe.mocks.MockScenario
import io.github.notkanaa.equipe.navigation.TabTestTags
import io.github.notkanaa.equipe.ui.auth.AuthTestTags
import io.github.notkanaa.equipe.ui.components.tasks.TaskTestTags
import io.github.notkanaa.equipe.ui.groups.GroupsTags
import org.robolectric.Shadows.shadowOf
import java.time.Duration

/**
 * The actions of the UI tests on the whole app (port of the iOS UI tests' `EquipeApp` helpers): launch on the
 * in-memory backend, queries by test tag (the iOS accessibility identifiers), waits, taps, text entry, scrolling and
 * navigation.
 *
 * Waits run on virtual time: each step advances the Compose clock (animations, effects) and the main looper's clock
 * (the coroutines of the app's main-thread scopes, e.g. the realtime debounce), so nothing depends on the machine's
 * speed. Nodes are looked up in every window (dialogs, bottom sheets and menus included): by test tag in the unmerged
 * tree (a tag inside a merged row is found too), by matcher in the merged tree (a button with its icon and label).
 */
class EquipeUi(val compose: AndroidComposeTestRule<*, out ComponentActivity>) {
    /** Launches the whole app on a fresh in-memory backend in [scenario] (iOS `EquipeApp.launch`). */
    fun launch(
        scenario: MockScenario,
        notifications: NotificationAuthorization = NotificationAuthorization.AUTHORIZED,
        clock: MockClock = MockClock(DemoTime.now),
    ): MockApp {
        val app = MockApp(scenario, notifications, clock)
        app.launch(compose)
        settle()
        return app
    }

    // region Waits

    /** Lets the app settle for [millis] of virtual time: recompositions, effects, animations, main-thread messages. */
    fun settle(millis: Long = 1_000) {
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(millis)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis))
        compose.waitForIdle()
    }

    /**
     * Waits (virtual time, 100 ms steps) until [condition] holds; fails with [description] and what the screen shows
     * (the semantics trees of every window) after [timeoutMillis].
     */
    fun waitUntil(description: String, timeoutMillis: Long = 10_000, condition: () -> Boolean) {
        var waited = 0L
        while (!condition()) {
            if (waited >= timeoutMillis) {
                throw AssertionError("Timed out after $timeoutMillis ms waiting for $description.\n${screen()}")
            }
            settle(STEP_MILLIS)
            waited += STEP_MILLIS
        }
    }

    /** The semantics trees of every window (merged), for failure messages. */
    fun screen(): String = try {
        compose.onAllNodes(isRoot()).printToString(maxDepth = Int.MAX_VALUE).take(SCREEN_DUMP_LIMIT)
    } catch (error: Throwable) {
        "(unavailable: $error)"
    }

    /** Whether a node with [tag] is composed (in any window). */
    fun exists(tag: String): Boolean =
        compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()

    /** Whether some node matches [matcher] (merged tree: what TalkBack reads as one element). */
    fun exists(matcher: SemanticsMatcher): Boolean = compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty()

    /** Waits until a node with [tag] is composed. */
    fun waitFor(tag: String, timeoutMillis: Long = 10_000) {
        waitUntil("« $tag »", timeoutMillis) { exists(tag) }
    }

    /** Waits until some node matches [matcher] (merged tree). */
    fun waitFor(matcher: SemanticsMatcher, timeoutMillis: Long = 10_000) {
        waitUntil(matcher.description, timeoutMillis) { exists(matcher) }
    }

    /** Waits until no node with [tag] is composed any more (a closed sheet, a left screen). */
    fun waitForGone(tag: String, timeoutMillis: Long = 10_000) {
        waitUntil("« $tag » to go away", timeoutMillis) { !exists(tag) }
    }

    /** Waits until the node [tag] shows [text] (its text, its field's text or its description). */
    fun waitForText(tag: String, text: String, timeoutMillis: Long = 10_000) {
        waitUntil("« $text » in « $tag »", timeoutMillis) {
            compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes().any { text in texts(it) }
        }
    }

    // endregion

    // region Nodes and actions

    /** The one node with [tag]. */
    fun node(tag: String): SemanticsNodeInteraction = compose.onNodeWithTag(tag, useUnmergedTree = true)

    /** Everything the node [tag] shows: texts, field text, descriptions. */
    fun textOf(tag: String): String = texts(node(tag).fetchSemanticsNode()).joinToString(" ")

    /** Whether the toggleable node [tag] (checkbox, switch, selectable tile) is on / selected. */
    fun isOn(tag: String): Boolean {
        val config = node(tag).fetchSemanticsNode().config
        return config.getOrNull(SemanticsProperties.ToggleableState) == ToggleableState.On ||
            config.getOrNull(SemanticsProperties.Selected) == true
    }

    /**
     * Taps the node with [tag] once it is composed, after scrolling it into view (lazy lists included), then lets the
     * app settle.
     */
    fun tap(tag: String) {
        reveal(tag)
        node(tag).performClick()
        settle()
    }

    /** Taps the node matching [matcher] (merged tree: a button with its icon and label). */
    fun tap(matcher: SemanticsMatcher) {
        waitFor(matcher)
        compose.onNode(matcher).performClick()
        settle()
    }

    /** Types [text] at the end of the field [tag] (like the keyboard: character input, not a replacement). */
    fun type(tag: String, text: String) {
        reveal(tag)
        node(tag).performTextInput(text)
        settle()
    }

    /** Replaces the text of the field [tag]. */
    fun replaceText(tag: String, text: String) {
        reveal(tag)
        node(tag).performTextReplacement(text)
        settle()
    }

    /**
     * Waits until a node with [tag] is composed, scrolling the lazy lists on screen to it when it is not (an item below
     * the fold), then scrolls it into view in its scrollable container. Nothing to scroll for a node outside any
     * scrollable container (top app bar, dialog button, sheet header).
     */
    fun reveal(tag: String) {
        waitUntil("« $tag »") { exists(tag) || scrollListsTo(tag) }
        try {
            node(tag).performScrollTo()
            settle()
        } catch (error: AssertionError) {
            // Not in a scrollable container.
        }
    }

    /** Scrolls the lazy lists on screen until one composes a node with [tag]; whether one did. */
    private fun scrollListsTo(tag: String): Boolean {
        val lists = compose.onAllNodes(hasScrollToNodeAction(), useUnmergedTree = true)
        for (index in 0 until lists.fetchSemanticsNodes().size) {
            try {
                lists[index].performScrollToNode(hasTestTag(tag))
                settle()
                if (exists(tag)) return true
            } catch (error: AssertionError) {
                // Not in this list.
            }
        }
        return false
    }

    // endregion

    // region Navigation

    /** Waits for the signed-in app (its tab bar). */
    fun waitForTabBar() {
        waitFor(TabTestTags.MY_TASKS)
    }

    /** Selects a tab (`TabTestTags`). */
    fun openTab(tag: String) {
        waitForTabBar()
        tap(tag)
    }

    /** Waits for the groups list with the two demo groups (signed in as Camille). */
    fun waitForDemoGroups() {
        waitForTabBar()
        waitFor(GroupsTags.row(DemoData.lilasGroupName))
        waitFor(GroupsTags.row(DemoData.sportGroupName))
    }

    /** Opens a group from the groups list and waits until its screen is loaded (« + » shown). */
    fun openGroup(name: String) {
        tap(GroupsTags.row(name))
        waitFor(TaskTestTags.ADD_BUTTON)
    }

    /** Opens a task from the shown list and waits for its screen. */
    fun openTask(title: String) {
        tap(TaskTestTags.row(title))
        waitForText(TaskTestTags.DETAIL_TITLE, title)
    }

    /** Leaves the shown screen with its top app bar's back arrow (« Retour »). */
    fun goBack() {
        tap(hasContentDescription(BACK) and !hasAnySibling(hasText(ASSIGNEES_TITLE)))
    }

    /** In the task editor: « Assigner à » → selects [name] → back to the form. */
    fun assign(name: String) {
        tap(TaskTestTags.ASSIGNEES_BUTTON)
        waitFor(TaskTestTags.ASSIGNEE_LIST)
        val row = TaskTestTags.assigneeRow(name)
        tap(row)
        waitUntil("« $name » selected") { isOn(row) }
        tap(hasContentDescription(BACK) and hasAnySibling(hasText(ASSIGNEES_TITLE)))
        waitFor(TaskTestTags.ASSIGNEES_BUTTON)
    }

    /** Fills the login form and signs in; waits for the signed-in app. */
    fun signIn(email: String, password: String) {
        waitFor(AuthTestTags.LOGIN_SCREEN)
        replaceText(AuthTestTags.EMAIL, email)
        type(AuthTestTags.PASSWORD, password)
        tap(AuthTestTags.SIGN_IN)
        waitForTabBar()
    }

    // endregion

    private companion object {
        const val STEP_MILLIS = 100L
        const val SCREEN_DUMP_LIMIT = 20_000
        const val BACK = "Retour"
        const val ASSIGNEES_TITLE = "Assigner à"

        fun texts(node: SemanticsNode): List<String> {
            val config = node.config
            return config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text } +
                listOfNotNull(config.getOrNull(SemanticsProperties.EditableText)?.text) +
                config.getOrNull(SemanticsProperties.ContentDescription).orEmpty()
        }
    }
}

/**
 * Records a screenshot of the whole screen (every window: dialogs, bottom sheets and menus with their scrim) as
 * `<name>.png` in the screenshots folder of the build (`equipe.screenshotsDir`, set by app/build.gradle.kts).
 */
@OptIn(ExperimentalRoborazziApi::class)
fun capture(name: String) {
    val directory = System.getProperty("equipe.screenshotsDir") ?: "build/outputs/roborazzi"
    captureScreenRoboImage("$directory/$name.png")
}
