@file:OptIn(ExperimentalMaterial3Api::class)

package io.github.notkanaa.equipe.ui.groups

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.CornerSize
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.TopAppBarScrollBehavior
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.max
import androidx.compose.ui.unit.sp
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.viewmodel.AppRoute
import io.github.notkanaa.equipe.core.viewmodel.ErrorState
import io.github.notkanaa.equipe.core.viewmodel.LoadState
import io.github.notkanaa.equipe.core.viewmodel.Router
import io.github.notkanaa.equipe.core.viewmodel.label
import kotlinx.coroutines.launch

// Building blocks shared by the « Groupes » tab (list, sheets, group screen) and the « Membres » screen: private color
// tokens (never the shell's theme objects), test tags (the iOS AccessibilityID strings), grouped cards, placeholders
// (iOS ContentUnavailableView / GroupsLoadStateView), dialogs, the large top app bar and the share sheet.

// region Tokens

/** Font scale from which rows stack their parts vertically (the iOS accessibility text sizes). */
internal const val LARGE_FONT_SCALE: Float = 1.5f

/** Horizontal margin of the cards, and of the text inside them. */
internal val CardMargin: Dp = 16.dp

/** Background of a screen and of its cards (iOS grouped list: light grey behind white cards, black behind dark cards). */
@Immutable
internal data class GroupedSurfaces(val screen: Color, val card: Color)

/**
 * The grouped-list colors of the app, the same as the task screens' (`groupedBackgroundColor` / `groupedCardColor` of
 * ui.components.tasks), so that nothing changes when a task is opened from a group: `surfaceContainerLowest` (white)
 * cards on `surfaceContainer` (light grey) in light mode, `surfaceContainerHigh` cards on `surfaceContainerLowest`
 * (near black) in dark mode.
 */
@Composable
@ReadOnlyComposable
internal fun groupedSurfaces(): GroupedSurfaces {
    val scheme = MaterialTheme.colorScheme
    return if (GroupsColors.isDark) {
        GroupedSurfaces(screen = scheme.surfaceContainerLowest, card = scheme.surfaceContainerHigh)
    } else {
        GroupedSurfaces(screen = scheme.surfaceContainer, card = scheme.surfaceContainerLowest)
    }
}

/** Text tints of the « Groupes » tab, with WCAG AA contrast (4.5:1) in light AND dark mode. */
internal object GroupsColors {
    /** The current Material scheme is dark (whatever the system setting). */
    val isDark: Boolean
        @Composable @ReadOnlyComposable
        get() = MaterialTheme.colorScheme.background.luminance() < 0.5f

    /** Selected filter chip: the brand blue in both modes, 4.8:1 with white text. */
    val accentFill: Color = Color(0xFF416CD9)
    val onAccentFill: Color = Color.White

    /** « Admin » capsule text: 4.6:1 or more inside its 15 % capsule on the cards (iOS PaletteAccentText). */
    val accentText: Color
        @Composable @ReadOnlyComposable
        get() = if (isDark) Color(0xFF8FB0FF) else Color(0xFF2F59C4)

    /** « Membre » capsule text: 4.6:1 or more inside its 15 % capsule on the cards (iOS PaletteGray). */
    val gray: Color
        @Composable @ReadOnlyComposable
        get() = if (isDark) Color(0xFFAEAEB2) else Color(0xFF5F5F64)

    /** Success icon of the join sheet (iOS green): 6:1 or more on the sheet. */
    val success: Color
        @Composable @ReadOnlyComposable
        get() = if (isDark) Color(0xFF30D158) else Color(0xFF19702F)
}

// endregion

// region Test tags (App/Sources/Shared/AccessibilityID*.swift)

/** The iOS `AccessibilityID.Groups` / `AccessibilityID.Tasks` strings used by the « Groupes » tab. */
internal object GroupsTags {
    const val LIST = "groups.list"
    const val CREATE = "groups.create"
    const val JOIN = "groups.join"
    const val NAME_FIELD = "groups.nameField"
    const val CODE_FIELD = "groups.codeField"
    const val SAVE = "groups.save"
    const val MEMBERS = "groups.members"
    const val INVITE = "groups.invite"
    const val INVITE_CODE = "groups.inviteCode"

    const val ROW_PREFIX = "groups.row."
    fun row(name: String): String = ROW_PREFIX + name
    const val EMPTY = "groups.empty"
    const val EMPTY_CREATE = "groups.empty.create"
    const val EMPTY_JOIN = "groups.empty.join"
    const val LOADING = "groups.loading"
    const val RETRY = "groups.retry"

    const val CANCEL = "groups.cancel"
    const val NAME_ERROR = "groups.nameError"
    const val JOIN_RESULT = "groups.joinResult"
    const val OPEN_GROUP = "groups.openGroup"

    const val DETAIL_MENU = "groups.detail.menu"
    const val SORT_PICKER = "groups.detail.sort"

    /** One option of the sort section (Android: the iOS picker is a section of the menu). */
    fun sortOption(rawValue: String): String = "$SORT_PICKER.$rawValue"
    const val INCLUDE_OLD_DONE = "groups.detail.includeOldDone"
    const val RESET_FILTER = "groups.detail.resetFilter"

    /** « Réinitialiser les filtres » of the options menu (no identifier on iOS). */
    const val MENU_RESET_FILTER = "groups.detail.menu.resetFilter"
    const val MENU_MEMBERS = "groups.detail.menu.members"
    const val MENU_INVITE = "groups.detail.menu.invite"
    const val RENAME = "groups.detail.rename"
    const val RENAME_FIELD = "groups.detail.renameField"
    const val RENAME_CONFIRM = "groups.detail.renameConfirm"
    const val DELETE = "groups.detail.delete"
    const val DELETE_CONFIRM = "groups.detail.deleteConfirm"
    const val FILTER_CHIP_PREFIX = "groups.filter."
    fun filterChip(key: String): String = FILTER_CHIP_PREFIX + key
    const val EMPTY_TASKS = "groups.detail.empty"
    const val CREATE_FIRST_TASK = "groups.detail.createFirstTask"
    const val DELETE_TASK_CONFIRM = "groups.detail.deleteTaskConfirm"

    /** « Modifier » / « Supprimer » of a task's long-press menu (no identifier on iOS). */
    const val TASK_EDIT = "groups.detail.task.edit"
    const val TASK_DELETE = "groups.detail.task.delete"

    const val SHARE_CODE = "groups.invite.share"
    const val REGENERATE_CODE = "groups.invite.regenerate"
    const val REGENERATE_CONFIRM = "groups.invite.regenerateConfirm"
    const val DONE = "groups.done"

    // AccessibilityID.Tasks, on the group screen.
    const val TASKS_LIST = "tasks.list"
    const val TASKS_ADD = "tasks.add"
    const val TASKS_FILTER = "tasks.filter"
    fun taskRow(title: String): String = "tasks.row.$title"
}

// endregion

// region Texts

/** French counts and spoken forms of the « Groupes » tab. */
internal object GroupsText {
    /** « 1 tâche », « 3 tâches » (0 takes the singular in French). */
    fun taskCount(count: Int): String = if (count <= 1) "$count tâche" else "$count tâches"

    /** « 1 membre », « 3 membres ». */
    fun memberCount(count: Int): String = if (count <= 1) "$count membre" else "$count membres"

    /**
     * What TalkBack reads for an invite code: its characters one by one (« L Y L A tiret S 2 3 4 »), not a word and a
     * number (iOS `speechSpellsOutCharacters()`).
     */
    fun spelledOut(code: String): String = code.map { if (it == '-') "tiret" else it.toString() }.joinToString(" ")

    const val SHARE_SUBJECT: String = "Invitation dans Équipe"
    const val GONE_TITLE: String = "Groupe indisponible"
}

// endregion

// region Navigation and platform

/**
 * Exposes the test tags of a separate window (bottom sheet, dialog, menu) as resource ids, like the activity's root
 * does for the main window only (UI Automator tests).
 */
@OptIn(ExperimentalComposeUiApi::class)
internal fun Modifier.windowTestTags(): Modifier = semantics { testTagsAsResourceId = true }

/** Pushes [route] on the selected tab (like an iOS NavigationLink), unless it is already on top (double tap). */
internal fun Router.pushOnce(route: AppRoute) {
    if (state.value.currentRoute != route) push(route)
}

/** Opens the Android share sheet with [text] (iOS `ShareLink(item:subject:)`). */
internal fun shareText(context: Context, text: String, subject: String = GroupsText.SHARE_SUBJECT) {
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
        putExtra(Intent.EXTRA_SUBJECT, subject)
    }
    val chooser = Intent.createChooser(send, null)
    if (context.findActivity() == null) chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try {
        context.startActivity(chooser)
    } catch (error: ActivityNotFoundException) {
        // No app can share text: nothing to do.
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

// endregion

// region Scaffolding

/**
 * Large top app bar of the screens (iOS large titles): the title collapses into the bar when the content scrolls.
 * The expanded height grows with the font scale so that the large title is never clipped.
 */
@Composable
internal fun GroupsLargeTopBar(
    title: String,
    scrollBehavior: TopAppBarScrollBehavior,
    containerColor: Color,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    val typography = MaterialTheme.typography.headlineMedium
    val lineHeight = with(LocalDensity.current) { textHeight(typography.lineHeight, typography.fontSize).toDp() }
    LargeTopAppBar(
        title = {
            Text(
                text = title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.semantics { heading() },
            )
        },
        navigationIcon = {
            if (onBack != null) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Retour")
                }
            }
        },
        actions = actions,
        expandedHeight = max(
            TopAppBarDefaults.LargeAppBarExpandedHeight,
            TopAppBarDefaults.LargeAppBarCollapsedHeight + lineHeight + 44.dp,
        ),
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = containerColor,
            scrolledContainerColor = containerColor,
        ),
        scrollBehavior = scrollBehavior,
    )
}

/**
 * Pull-to-refresh content of a screen whose large top app bar collapses on scroll. The bar's nested-scroll connection
 * sits INSIDE the refresh box (scroll leftovers go to the nearest parent first): pulling down at the top of the list
 * first expands the large title, then refreshes ([onRefresh], e.g. the view model's `reload()`).
 */
@Composable
internal fun RefreshableContent(
    scrollBehavior: TopAppBarScrollBehavior,
    padding: PaddingValues,
    onRefresh: suspend () -> Unit,
    content: @Composable BoxScope.() -> Unit,
) {
    val scope = rememberCoroutineScope()
    var isRefreshing by remember { mutableStateOf(false) }
    PullToRefreshBox(
        isRefreshing = isRefreshing,
        onRefresh = {
            scope.launch {
                isRefreshing = true
                try {
                    onRefresh()
                } finally {
                    isRefreshing = false
                }
            }
        },
        modifier = Modifier
            .fillMaxSize()
            .padding(padding),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .nestedScroll(scrollBehavior.nestedScrollConnection),
            content = content,
        )
    }
}

/** Line height of a style in sp, or 1.3 × its font size when the typography sets none (or not in sp). */
private fun textHeight(lineHeight: TextUnit, fontSize: TextUnit): TextUnit = when {
    lineHeight.isSp -> lineHeight
    fontSize.isSp -> fontSize * 1.3f
    else -> 36.sp
}

/**
 * Full-size, vertically scrollable box whose content is centered in the viewport: placeholders stay centered and
 * pull-to-refresh still works on them.
 */
@Composable
internal fun ScrollablePlaceholder(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        val minHeight = if (constraints.hasBoundedHeight) maxHeight else 0.dp
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .heightIn(min = minHeight)
                .padding(horizontal = 32.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            content = content,
        )
    }
}

/**
 * Shape of the item [index] of a grouped card of [count] items (`MaterialTheme.shapes.large`, like the task screens'
 * cards): rounded top for the first, rounded bottom for the last.
 */
@Composable
@ReadOnlyComposable
internal fun groupedItemShape(index: Int, count: Int): Shape {
    val shape = MaterialTheme.shapes.large
    val square = CornerSize(0.dp)
    return when {
        count <= 1 -> shape
        index == 0 -> shape.copy(bottomStart = square, bottomEnd = square)
        index == count - 1 -> shape.copy(topStart = square, topEnd = square)
        else -> RectangleShape
    }
}

/** Section header above a card (« Inviter », « 5 tâches »): a TalkBack heading. */
@Composable
internal fun SectionHeader(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier
            .fillMaxWidth()
            .padding(start = CardMargin * 2, end = CardMargin * 2, top = 20.dp, bottom = 8.dp)
            .semantics { heading() },
    )
}

/** Explanation under a card. */
@Composable
internal fun SectionFooter(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier
            .fillMaxWidth()
            .padding(start = CardMargin * 2, end = CardMargin * 2, top = 8.dp, bottom = 4.dp),
    )
}

// endregion

// region Components

/** « Admin » / « Membre » capsule; TalkBack reads « Rôle : Admin ». */
@Composable
internal fun RoleBadge(role: MemberRole, modifier: Modifier = Modifier) {
    val tint = if (role == MemberRole.ADMIN) GroupsColors.accentText else GroupsColors.gray
    Text(
        text = role.label,
        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
        color = tint,
        maxLines = 1,
        softWrap = false,
        modifier = modifier
            .clearAndSetSemantics { contentDescription = "Rôle : ${role.label}" }
            .background(tint.copy(alpha = 0.15f), CircleShape)
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

/** iOS ContentUnavailableView: icon, title, message and actions, centered. */
@Composable
internal fun ContentUnavailable(
    icon: ImageVector,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    iconTint: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    messageModifier: Modifier = Modifier,
    actions: @Composable ColumnScope.() -> Unit = {},
) {
    Column(
        modifier = modifier.widthIn(max = 480.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(48.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold),
            textAlign = TextAlign.Center,
            modifier = Modifier
                .padding(top = 8.dp)
                .semantics { heading() },
        )
        Text(
            text = message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = messageModifier,
        )
        Column(
            modifier = Modifier.padding(top = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
            content = actions,
        )
    }
}

/** First-load placeholder: a spinner while loading, or the failure with « Réessayer ». Nothing once loaded. */
@Composable
internal fun LoadStateView(loadState: LoadState, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    val failure = loadState.failureMessage
    if (failure != null) {
        ContentUnavailable(
            icon = Icons.Outlined.WarningAmber,
            title = "Chargement impossible",
            message = failure,
            modifier = modifier,
        ) {
            Button(onClick = onRetry, modifier = Modifier.testTag(GroupsTags.RETRY)) {
                Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
                Text("Réessayer", modifier = Modifier.padding(start = ButtonDefaults.IconSpacing))
            }
        }
    } else if (!loadState.isLoaded) {
        Column(
            modifier = modifier
                .testTag(GroupsTags.LOADING)
                .semantics(mergeDescendants = true) { },
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            CircularProgressIndicator()
            Text(
                text = "Chargement…",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** « Erreur » alert of a view model's error (the shared convention of the screens). */
@Composable
internal fun ErrorAlert(error: ErrorState?, onDismiss: () -> Unit) {
    if (error == null) return
    AlertDialog(
        modifier = Modifier.windowTestTags(),
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK") } },
        title = { Text("Erreur") },
        text = { Text(error.message) },
    )
}

/** Confirmation of an action (iOS confirmationDialog): « Annuler » and the action, red when destructive. */
@Composable
internal fun ConfirmationDialog(
    title: String,
    message: String,
    confirmLabel: String,
    confirmTag: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    destructive: Boolean = true,
) {
    AlertDialog(
        modifier = Modifier.windowTestTags(),
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(
                onClick = {
                    onConfirm()
                    onDismiss()
                },
                colors = if (destructive) {
                    ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                } else {
                    ButtonDefaults.textButtonColors()
                },
                modifier = Modifier.testTag(confirmTag),
            ) {
                Text(confirmLabel)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Annuler") } },
        title = { Text(title) },
        text = { Text(message) },
    )
}

/** Small spinner in a row (busy member, code being regenerated, leaving). */
@Composable
internal fun RowSpinner(contentDescription: String? = null, modifier: Modifier = Modifier) {
    CircularProgressIndicator(
        strokeWidth = 2.dp,
        modifier = modifier
            .size(20.dp)
            .then(
                if (contentDescription != null) {
                    Modifier.semantics { this.contentDescription = contentDescription }
                } else {
                    Modifier
                },
            ),
    )
}

/** Monospaced digits (« 15/60 » does not jitter while typing). */
internal val TabularNumbers: TextStyle = TextStyle(fontFeatureSettings = "tnum")

// endregion
