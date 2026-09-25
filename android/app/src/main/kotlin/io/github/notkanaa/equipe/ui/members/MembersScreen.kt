@file:OptIn(ExperimentalMaterial3Api::class)

package io.github.notkanaa.equipe.ui.members

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.AddModerator
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.PersonRemove
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material.icons.filled.RemoveModerator
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.viewmodel.MembersState
import io.github.notkanaa.equipe.core.viewmodel.MembersViewModel
import io.github.notkanaa.equipe.core.viewmodel.Router
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import io.github.notkanaa.equipe.ui.components.people.PersonAvatar
import io.github.notkanaa.equipe.ui.groups.CardMargin
import io.github.notkanaa.equipe.ui.groups.ConfirmationDialog
import io.github.notkanaa.equipe.ui.groups.ContentUnavailable
import io.github.notkanaa.equipe.ui.groups.ErrorAlert
import io.github.notkanaa.equipe.ui.groups.GroupsLargeTopBar
import io.github.notkanaa.equipe.ui.groups.GroupsText
import io.github.notkanaa.equipe.ui.groups.LARGE_FONT_SCALE
import io.github.notkanaa.equipe.ui.groups.LoadStateView
import io.github.notkanaa.equipe.ui.groups.RefreshableContent
import io.github.notkanaa.equipe.ui.groups.RegenerateCodeDialog
import io.github.notkanaa.equipe.ui.groups.RoleBadge
import io.github.notkanaa.equipe.ui.groups.RowSpinner
import io.github.notkanaa.equipe.ui.groups.ScrollablePlaceholder
import io.github.notkanaa.equipe.ui.groups.SectionFooter
import io.github.notkanaa.equipe.ui.groups.SectionHeader
import io.github.notkanaa.equipe.ui.groups.groupedItemShape
import io.github.notkanaa.equipe.ui.groups.groupedSurfaces
import io.github.notkanaa.equipe.ui.groups.shareText
import io.github.notkanaa.equipe.ui.groups.windowTestTags
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID

// Port of App/Sources/Features/Members/MembersView.swift.

/**
 * « Membres » screen: for admins the invite code (share, regenerate); the members (admins first, then by name) with
 * « Membre depuis le … », their role and, for admins, their actions (« Nommer admin » / « Retirer le rôle d’admin »,
 * « Retirer du groupe » with a confirmation); « Quitter le groupe » for everyone, disabled with the explanation for
 * the last admin. Leaves the group's screens when the group is gone or left (`router.removeRoutesForGroup(groupId)`).
 */
@Composable
fun MembersScreen(groupId: UUID, session: SessionModel, router: Router) {
    val scope = rememberCoroutineScope()
    val model = remember(session, groupId) { MembersViewModel(session, groupId, scope) }
    val state by model.state.collectAsStateWithLifecycle()
    LaunchedEffect(model) { model.autoRefresh() }
    LaunchedEffect(state.isGone) {
        if (state.isGone) router.removeRoutesForGroup(groupId)
    }

    var memberPendingRemoval by remember { mutableStateOf<Membership?>(null) }
    var memberPendingDemotion by remember { mutableStateOf<Membership?>(null) }
    var isConfirmingLeave by rememberSaveable { mutableStateOf(false) }
    var isConfirmingRegeneration by rememberSaveable { mutableStateOf(false) }
    val surfaces = groupedSurfaces()
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val context = LocalContext.current

    // Demoting oneself asks for a confirmation (the admin rights are lost); other role changes apply at once.
    val requestRoleChange: (Membership) -> Unit = { member ->
        if (state.isMe(member) && member.role == MemberRole.ADMIN) {
            memberPendingDemotion = member
        } else {
            session.scope.launch { model.toggleRole(member) }
        }
    }

    Scaffold(
        containerColor = surfaces.screen,
        topBar = {
            GroupsLargeTopBar(
                title = state.title,
                scrollBehavior = scrollBehavior,
                containerColor = surfaces.screen,
                onBack = { router.pop() },
            )
        },
    ) { padding ->
        RefreshableContent(scrollBehavior, padding, onRefresh = model::reload) {
            when {
                state.isGone -> ScrollablePlaceholder {
                    ContentUnavailable(
                        icon = Icons.Filled.Groups,
                        title = GroupsText.GONE_TITLE,
                        message = MembersViewModel.GONE_MESSAGE,
                    )
                }
                !state.loadState.isLoaded -> ScrollablePlaceholder {
                    LoadStateView(state.loadState, onRetry = { scope.launch { model.reload() } })
                }
                else -> MembersList(
                    state = state,
                    cardColor = surfaces.card,
                    now = session.platform.now(),
                    calendar = session.platform.calendar,
                    onShare = { text -> shareText(context, text) },
                    onRegenerate = { isConfirmingRegeneration = true },
                    onRoleChange = requestRoleChange,
                    onRemove = { member -> memberPendingRemoval = member },
                    onLeave = { if (!state.isLastAdmin) isConfirmingLeave = true },
                )
            }
        }
    }

    memberPendingRemoval?.let { member ->
        val name = member.user.displayName
        ConfirmationDialog(
            title = "Retirer ce membre ?",
            message = "$name n’aura plus accès à « ${state.groupName} ». " +
                "Ses assignations dans ce groupe seront retirées.",
            confirmLabel = "Retirer $name",
            confirmTag = MembersTags.REMOVE_CONFIRM,
            onConfirm = { session.scope.launch { model.remove(member) } },
            onDismiss = { memberPendingRemoval = null },
        )
    }
    memberPendingDemotion?.let { member ->
        ConfirmationDialog(
            title = "Retirer votre rôle d’admin ?",
            message = "Vous ne pourrez plus gérer les membres, le code d’invitation ni le nom du groupe.",
            confirmLabel = "Retirer mon rôle d’admin",
            confirmTag = MembersTags.SELF_DEMOTE_CONFIRM,
            onConfirm = { session.scope.launch { model.setRole(MemberRole.MEMBER, member) } },
            onDismiss = { memberPendingDemotion = null },
        )
    }
    if (isConfirmingLeave) {
        ConfirmationDialog(
            title = "Quitter le groupe ?",
            message = state.leaveConfirmationMessage,
            confirmLabel = if (state.isLastMember) "Quitter et supprimer le groupe" else "Quitter le groupe",
            confirmTag = MembersTags.LEAVE_CONFIRM,
            onConfirm = { session.scope.launch { model.leave() } },
            onDismiss = { isConfirmingLeave = false },
        )
    }
    if (isConfirmingRegeneration) {
        RegenerateCodeDialog(
            confirmTag = MembersTags.REGENERATE_CONFIRM,
            onConfirm = { session.scope.launch { model.regenerateInviteCode() } },
            onDismiss = { isConfirmingRegeneration = false },
        )
    }
    ErrorAlert(state.error, model::dismissError)
}

@Composable
private fun MembersList(
    state: MembersState,
    cardColor: Color,
    now: Instant,
    calendar: AppCalendar,
    onShare: (String) -> Unit,
    onRegenerate: () -> Unit,
    onRoleChange: (Membership) -> Unit,
    onRemove: (Membership) -> Unit,
    onLeave: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(MembersTags.LIST),
        contentPadding = PaddingValues(bottom = 24.dp),
    ) {
        if (state.canSeeInviteCode) {
            item(key = "inviteHeader") { SectionHeader("Inviter") }
            item(key = "invite") {
                InviteCard(state = state, cardColor = cardColor, onShare = onShare, onRegenerate = onRegenerate)
            }
            item(key = "inviteFooter") { SectionFooter("Toute personne qui a ce code peut rejoindre le groupe.") }
        }
        item(key = "membersHeader") {
            SectionHeader("« ${state.groupName} » · ${GroupsText.memberCount(state.members.size)}")
        }
        itemsIndexed(state.members, key = { _, member -> member.id }) { index, member ->
            MemberRow(
                member = member,
                state = state,
                joinedText = MembersJoinedText.sentence(member.joinedAt, now, calendar),
                shape = groupedItemShape(index, state.members.size),
                cardColor = cardColor,
                showDivider = index > 0,
                onRoleChange = onRoleChange,
                onRemove = onRemove,
            )
        }
        item(key = "leave") {
            Column(Modifier.padding(top = 32.dp)) {
                LeaveCard(state = state, cardColor = cardColor, onLeave = onLeave)
                when {
                    state.isLastAdmin -> SectionFooter(state.leaveConfirmationMessage)
                    state.isLastMember -> SectionFooter(
                        "Vous êtes le seul membre : quitter le groupe le supprimera avec toutes ses tâches.",
                    )
                    else -> Unit
                }
            }
        }
    }
}

/** Admins: the invite code, « Partager le code », « Générer un nouveau code ». */
@Composable
private fun InviteCard(state: MembersState, cardColor: Color, onShare: (String) -> Unit, onRegenerate: () -> Unit) {
    val code = state.inviteCodeText ?: "—"
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = CardMargin)
            .clip(groupedItemShape(0, 1))
            .background(cardColor),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = CardMargin, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Filled.QrCode, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Text("Code d’invitation", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
            SelectionContainer {
                Text(
                    text = code,
                    style = MaterialTheme.typography.titleMedium.copy(
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Bold,
                    ),
                    maxLines = 1,
                    softWrap = false,
                    modifier = Modifier
                        .testTag(MembersTags.INVITE_CODE)
                        .semantics { contentDescription = GroupsText.spelledOut(code) },
                )
            }
        }
        state.shareText?.let { text ->
            HorizontalDivider(Modifier.padding(start = ActionTextInset))
            ActionRow(
                icon = Icons.Filled.Share,
                title = "Partager le code",
                tag = MembersTags.SHARE_CODE,
                onClick = { onShare(text) },
            )
        }
        HorizontalDivider(Modifier.padding(start = ActionTextInset))
        ActionRow(
            icon = Icons.Filled.Autorenew,
            title = "Générer un nouveau code",
            tag = MembersTags.REGENERATE_CODE,
            enabled = !state.isRegeneratingCode,
            isBusy = state.isRegeneratingCode,
            busyDescription = "Génération d’un nouveau code",
            onClick = onRegenerate,
        )
    }
}

/**
 * A member: avatar, name (« (vous) »), « Membre depuis le … », role capsule (a spinner while their role or
 * membership changes) as one TalkBack element; for admins the « … » actions menu. At large font scales the avatar,
 * the texts and the role go under each other instead of being cut.
 */
@Composable
private fun MemberRow(
    member: Membership,
    state: MembersState,
    joinedText: String,
    shape: Shape,
    cardColor: Color,
    showDivider: Boolean,
    onRoleChange: (Membership) -> Unit,
    onRemove: (Membership) -> Unit,
) {
    val name = member.user.displayName
    val isBusy = member.id in state.busyMemberIds
    val isLargeText = LocalDensity.current.fontScale >= LARGE_FONT_SCALE
    val canChangeRole = state.canChangeRole(member)
    val canRemove = state.canRemove(member)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = CardMargin)
            .clip(shape)
            .background(cardColor)
            .testTag(MembersTags.row(name)),
    ) {
        if (showDivider) HorizontalDivider(Modifier.padding(start = CardMargin + AvatarSize + 12.dp))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    start = CardMargin,
                    end = if (canChangeRole || canRemove) 4.dp else CardMargin,
                    top = 10.dp,
                    bottom = 10.dp,
                ),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val info = Modifier
                .weight(1f)
                .semantics(mergeDescendants = true) { }
            val texts = @Composable { modifier: Modifier ->
                Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = state.displayName(member),
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = if (state.isMe(member)) FontWeight.SemiBold else FontWeight.Normal,
                        maxLines = if (isLargeText) Int.MAX_VALUE else 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = joinedText,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = if (isLargeText) Int.MAX_VALUE else 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            val role = @Composable {
                if (isBusy) RowSpinner(contentDescription = "Mise à jour") else RoleBadge(member.role)
            }
            if (isLargeText) {
                Column(info, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    PersonAvatar(userId = member.user.id, name = name, size = AvatarSize)
                    texts(Modifier)
                    role()
                }
            } else {
                Row(
                    modifier = info,
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    PersonAvatar(userId = member.user.id, name = name, size = AvatarSize)
                    texts(Modifier.weight(1f))
                    role()
                }
            }
            if (canChangeRole || canRemove) {
                MemberActionsMenu(
                    member = member,
                    state = state,
                    enabled = !isBusy,
                    canChangeRole = canChangeRole,
                    canRemove = canRemove,
                    onRoleChange = onRoleChange,
                    onRemove = onRemove,
                )
            }
        }
    }
}

/** « … » of a member (admins): change the role, remove from the group. */
@Composable
private fun MemberActionsMenu(
    member: Membership,
    state: MembersState,
    enabled: Boolean,
    canChangeRole: Boolean,
    canRemove: Boolean,
    onRoleChange: (Membership) -> Unit,
    onRemove: (Membership) -> Unit,
) {
    var isExpanded by remember { mutableStateOf(false) }
    val name = member.user.displayName
    Box {
        IconButton(
            onClick = { isExpanded = true },
            enabled = enabled,
            modifier = Modifier.testTag(MembersTags.actions(name)),
        ) {
            Icon(
                imageVector = Icons.Filled.MoreHoriz,
                contentDescription = "Actions pour $name",
                tint = if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        DropdownMenu(
            expanded = isExpanded,
            onDismissRequest = { isExpanded = false },
            modifier = Modifier.windowTestTags(),
        ) {
            if (canChangeRole) {
                DropdownMenuItem(
                    text = { Text(state.roleActionTitle(member)) },
                    onClick = {
                        isExpanded = false
                        onRoleChange(member)
                    },
                    leadingIcon = {
                        Icon(
                            imageVector = if (member.role == MemberRole.ADMIN) {
                                Icons.Filled.RemoveModerator
                            } else {
                                Icons.Filled.AddModerator
                            },
                            contentDescription = null,
                        )
                    },
                    modifier = Modifier.testTag(MembersTags.ROLE),
                )
            }
            if (canRemove) {
                DropdownMenuItem(
                    text = { Text("Retirer du groupe", color = MaterialTheme.colorScheme.error) },
                    onClick = {
                        isExpanded = false
                        onRemove(member)
                    },
                    leadingIcon = {
                        Icon(Icons.Filled.PersonRemove, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                    },
                    modifier = Modifier.testTag(MembersTags.REMOVE),
                )
            }
        }
    }
}

/** « Quitter le groupe » (everyone): red, disabled for the last admin (the footer says why) and while leaving. */
@Composable
private fun LeaveCard(state: MembersState, cardColor: Color, onLeave: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = CardMargin)
            .clip(groupedItemShape(0, 1))
            .background(cardColor),
    ) {
        ActionRow(
            icon = Icons.AutoMirrored.Filled.Logout,
            title = "Quitter le groupe",
            tag = MembersTags.LEAVE,
            enabled = !state.isLeaving && !state.isLastAdmin,
            isBusy = state.isLeaving,
            busyDescription = "Départ du groupe",
            tint = MaterialTheme.colorScheme.error,
            onClick = onLeave,
        )
    }
}

/** A button row of a card: icon and title in the accent (or [tint]) color, a spinner while [isBusy]. */
@Composable
private fun ActionRow(
    icon: ImageVector,
    title: String,
    tag: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    isBusy: Boolean = false,
    busyDescription: String? = null,
    tint: Color = MaterialTheme.colorScheme.primary,
) {
    val color = if (enabled) tint else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = CardMargin, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = color)
        Text(text = title, style = MaterialTheme.typography.bodyLarge, color = color, modifier = Modifier.weight(1f))
        if (isBusy) RowSpinner(contentDescription = busyDescription)
    }
}

/** Size of the members' avatars. */
private val AvatarSize: Dp = 40.dp

/** Start of the texts of the action rows (after their icon): where their separators begin. */
private val ActionTextInset: Dp = CardMargin + 24.dp + 12.dp

/** The iOS `AccessibilityID.Members` strings. */
internal object MembersTags {
    const val LIST = "members.list"
    const val ROW_PREFIX = "members.row."

    /** A member cell, by display name (without « (vous) »). */
    fun row(name: String): String = ROW_PREFIX + name
    const val ACTIONS_PREFIX = "members.actions."

    /** The « … » menu of a member cell (admins), by display name. */
    fun actions(name: String): String = ACTIONS_PREFIX + name
    const val ROLE = "members.role"
    const val REMOVE = "members.remove"
    const val REMOVE_CONFIRM = "members.removeConfirm"
    const val SELF_DEMOTE_CONFIRM = "members.selfDemoteConfirm"
    const val INVITE_CODE = "members.inviteCode"
    const val SHARE_CODE = "members.shareCode"
    const val REGENERATE_CODE = "members.regenerateCode"
    const val REGENERATE_CONFIRM = "members.regenerateConfirm"
    const val LEAVE = "members.leave"
    const val LEAVE_CONFIRM = "members.leaveConfirm"
}
