@file:OptIn(ExperimentalMaterial3Api::class)

package io.github.notkanaa.equipe.ui.groups

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ConfirmationNumber
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.viewmodel.DateText
import io.github.notkanaa.equipe.core.viewmodel.GroupsListViewModel
import io.github.notkanaa.equipe.core.viewmodel.Router
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import io.github.notkanaa.equipe.ui.components.people.InitialsBadge
import io.github.notkanaa.equipe.ui.components.people.PersonInitials
import io.github.notkanaa.equipe.ui.components.people.PersonPalette
import kotlinx.coroutines.launch

// Port of App/Sources/Features/Groups/GroupsListView.swift and Components/Groups/GroupsListRow.swift.

/** Sheets of the groups list. */
private enum class GroupsListSheet { CREATE, JOIN }

/**
 * Root of the « Groupes » tab: the groups of the user (most recently active first) with their role and last activity,
 * « Rejoindre » and « + » (bottom sheets), an empty state inviting to create or join, pull-to-refresh. A tap shows the
 * group (`router.showGroup`), as does a successful creation or join.
 */
@Composable
fun GroupsListScreen(session: SessionModel, router: Router) {
    val scope = rememberCoroutineScope()
    val model = remember(session) { GroupsListViewModel(session, scope) }
    val state by model.state.collectAsStateWithLifecycle()
    LaunchedEffect(model) { model.autoRefresh() }

    var sheet by rememberSaveable { mutableStateOf<GroupsListSheet?>(null) }
    val surfaces = groupedSurfaces()
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()

    Scaffold(
        containerColor = surfaces.screen,
        topBar = {
            GroupsLargeTopBar(
                title = "Groupes",
                scrollBehavior = scrollBehavior,
                containerColor = surfaces.screen,
                actions = {
                    TextButton(
                        onClick = { sheet = GroupsListSheet.JOIN },
                        modifier = Modifier.testTag(GroupsTags.JOIN),
                    ) {
                        Text("Rejoindre")
                    }
                    IconButton(
                        onClick = { sheet = GroupsListSheet.CREATE },
                        modifier = Modifier.testTag(GroupsTags.CREATE),
                    ) {
                        Icon(Icons.Filled.Add, contentDescription = "Créer un groupe")
                    }
                },
            )
        },
    ) { padding ->
        RefreshableContent(scrollBehavior, padding, onRefresh = model::reload) {
            when {
                state.isEmpty -> ScrollablePlaceholder {
                    EmptyGroups(
                        onCreate = { sheet = GroupsListSheet.CREATE },
                        onJoin = { sheet = GroupsListSheet.JOIN },
                    )
                }
                !state.loadState.isLoaded -> ScrollablePlaceholder {
                    LoadStateView(state.loadState, onRetry = { scope.launch { model.reload() } })
                }
                else -> GroupsList(
                    groups = state.groups,
                    activityText = { summary ->
                        val now = session.platform.now()
                        val date = DateText.relativeLowercase(summary.group.lastActivityAt, now, session.platform.calendar)
                        "Dernière activité : $date"
                    },
                    cardColor = surfaces.card,
                    onOpen = { groupId -> router.showGroup(groupId) },
                )
            }
        }
    }

    when (sheet) {
        GroupsListSheet.CREATE -> CreateGroupSheet(
            session = session,
            onDismiss = { sheet = null },
            onCreated = { group ->
                sheet = null
                router.showGroup(group.id)
            },
        )
        GroupsListSheet.JOIN -> JoinGroupSheet(
            session = session,
            onDismiss = { sheet = null },
            onOpenGroup = { groupId ->
                sheet = null
                router.showGroup(groupId)
            },
        )
        null -> Unit
    }

    ErrorAlert(state.error, model::dismissError)
}

@Composable
private fun GroupsList(
    groups: List<GroupSummary>,
    activityText: (GroupSummary) -> String,
    cardColor: Color,
    onOpen: (java.util.UUID) -> Unit,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(GroupsTags.LIST),
        contentPadding = PaddingValues(top = 8.dp, bottom = 24.dp),
    ) {
        itemsIndexed(groups, key = { _, summary -> summary.id }) { index, summary ->
            GroupRow(
                summary = summary,
                activityText = activityText(summary),
                shape = groupedItemShape(index, groups.size),
                cardColor = cardColor,
                showDivider = index > 0,
                onClick = { onOpen(summary.id) },
            )
        }
    }
}

/**
 * A group: colored initials, name and my role on one line (the role capsule goes under the name at large font
 * scales), then « Dernière activité : … » on the whole width, wrapped rather than cut. One TalkBack element.
 */
@Composable
private fun GroupRow(
    summary: GroupSummary,
    activityText: String,
    shape: Shape,
    cardColor: Color,
    showDivider: Boolean,
    onClick: () -> Unit,
) {
    val isLargeText = LocalDensity.current.fontScale >= LARGE_FONT_SCALE
    val name = summary.group.name
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = CardMargin)
            .clip(shape)
            .background(cardColor),
    ) {
        if (showDivider) HorizontalDivider(Modifier.padding(start = CardMargin + TileSize + 12.dp))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .testTag(GroupsTags.row(name))
                .clickable(onClickLabel = "ouvrir le groupe", role = Role.Button, onClick = onClick)
                .padding(horizontal = CardMargin, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            InitialsBadge(
                text = PersonInitials.make(name),
                color = PersonPalette.color(summary.id),
                size = TileSize,
                shape = RoundedCornerShape(TileSize * 0.28f),
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (isLargeText) {
                    Text(text = name, style = MaterialTheme.typography.titleMedium)
                    RoleBadge(summary.myRole)
                } else {
                    Row(verticalAlignment = Alignment.Top) {
                        Text(
                            text = name,
                            style = MaterialTheme.typography.titleMedium,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier
                                .weight(1f)
                                .alignByBaseline(),
                        )
                        Spacer(Modifier.width(8.dp))
                        RoleBadge(summary.myRole, Modifier.alignByBaseline())
                    }
                }
                ActivityLine(activityText)
            }
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** « Dernière activité : hier à 18:00 » after a clock icon that follows the font scale; never truncated. */
@Composable
private fun ActivityLine(text: String) {
    val style = MaterialTheme.typography.bodySmall
    val density = LocalDensity.current
    val iconSize = with(density) { if (style.fontSize.isSp) style.fontSize.toDp() else 12.dp }
    val lineHeight = with(density) { if (style.lineHeight.isSp) style.lineHeight.toDp() else iconSize * 1.3f }
    Row(verticalAlignment = Alignment.Top) {
        Icon(
            imageVector = Icons.Outlined.Schedule,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .padding(top = ((lineHeight - iconSize) / 2).coerceAtLeast(0.dp))
                .size(iconSize),
        )
        Spacer(Modifier.width(4.dp))
        Text(text = text, style = style, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** « Aucun groupe »: create or join with a code. */
@Composable
private fun EmptyGroups(onCreate: () -> Unit, onJoin: () -> Unit) {
    ContentUnavailable(
        icon = Icons.Filled.Groups,
        title = GroupsListViewModel.EMPTY_TITLE,
        message = GroupsListViewModel.EMPTY_MESSAGE,
        modifier = Modifier.testTag(GroupsTags.EMPTY),
    ) {
        Button(onClick = onCreate, modifier = Modifier.testTag(GroupsTags.EMPTY_CREATE)) {
            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
            Text("Créer un groupe", modifier = Modifier.padding(start = ButtonDefaults.IconSpacing))
        }
        OutlinedButton(onClick = onJoin, modifier = Modifier.testTag(GroupsTags.EMPTY_JOIN)) {
            Icon(
                Icons.Filled.ConfirmationNumber,
                contentDescription = null,
                modifier = Modifier.size(ButtonDefaults.IconSize),
            )
            Text("Rejoindre avec un code", modifier = Modifier.padding(start = ButtonDefaults.IconSpacing))
        }
    }
}

/** Size of the group initials tile. */
private val TileSize = 44.dp
