package io.github.notkanaa.equipe.ui.tasks

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.GroupOff
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.SearchOff
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.NameOrder
import io.github.notkanaa.equipe.core.viewmodel.AssigneeOption
import io.github.notkanaa.equipe.core.viewmodel.TaskEditorState
import io.github.notkanaa.equipe.core.viewmodel.TaskEditorViewModel
import io.github.notkanaa.equipe.core.viewmodel.label
import io.github.notkanaa.equipe.ui.components.people.PersonAvatar
import io.github.notkanaa.equipe.ui.components.tasks.GroupedCardItem
import io.github.notkanaa.equipe.ui.components.tasks.TaskMessageView
import io.github.notkanaa.equipe.ui.components.tasks.TaskSectionFooter
import io.github.notkanaa.equipe.ui.components.tasks.TaskTestTags
import io.github.notkanaa.equipe.ui.components.tasks.groupedCardColor
import java.util.UUID

/**
 * « Assigner à » page of the task editor (port of the iOS `TaskEditorAssigneePicker`): the group's members (admins first,
 * then by name) with a search field; a tap adds or removes an assignee (20 at most: the editor refuses more with a
 * message). « Tout retirer » clears the selection.
 */
@Composable
internal fun TaskEditorAssigneePicker(
    state: TaskEditorState,
    onToggle: (UUID) -> Unit,
    onClearAll: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val focusManager = LocalFocusManager.current
    var searchText by remember { mutableStateOf("") }
    val query = InputValidation.trimmed(searchText)
    val options = state.assigneeOptions
    val filtered = remember(options, query) { filterAssigneeOptions(options, query) }
    // Initials from the real name (the option of the current user reads « Camille Martin (vous) »).
    val displayNames = remember(state.members) { state.members.associate { it.user.id to it.user.displayName } }
    val cardColor = groupedCardColor()

    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp)
                .padding(horizontal = 4.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Retour")
            }
            Text(
                text = "Assigner à",
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() },
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            TextButton(onClick = onClearAll, enabled = state.assigneeIds.isNotEmpty()) {
                Text("Tout retirer")
            }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)

        OutlinedTextField(
            value = searchText,
            onValueChange = { searchText = it },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            placeholder = { Text("Rechercher un membre") },
            leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
            trailingIcon = if (searchText.isNotEmpty()) {
                {
                    IconButton(onClick = { searchText = "" }) {
                        Icon(Icons.Outlined.Close, contentDescription = "Effacer la recherche")
                    }
                }
            } else {
                null
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { focusManager.clearFocus() }),
            shape = MaterialTheme.shapes.extraLarge,
            colors = OutlinedTextFieldDefaults.colors(
                focusedContainerColor = cardColor,
                unfocusedContainerColor = cardColor,
            ),
        )

        state.assigneesError?.let { message ->
            FieldError(message, Modifier.padding(horizontal = 20.dp, vertical = 4.dp))
        }

        val listModifier = Modifier
            .weight(1f)
            .fillMaxWidth()
            .testTag(TaskTestTags.ASSIGNEE_LIST)
        if (filtered.isEmpty()) {
            // Outside the lazy list: the message view scrolls by itself.
            if (options.isEmpty()) {
                TaskMessageView(
                    icon = Icons.Outlined.GroupOff,
                    title = "Aucun membre",
                    message = "Ce groupe n’a pas encore de membres à assigner.",
                    modifier = listModifier,
                )
            } else {
                TaskMessageView(
                    icon = Icons.Outlined.SearchOff,
                    title = "Aucun résultat",
                    message = "Aucun membre ne correspond à « $query ».",
                    modifier = listModifier,
                )
            }
        } else {
            LazyColumn(
                modifier = listModifier,
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
            ) {
                itemsIndexed(filtered, key = { _, option -> option.id.toString() }) { index, option ->
                    GroupedCardItem(index = index, count = filtered.size, dividerStartIndent = 64.dp) {
                        AssigneeOptionRow(
                            option = option,
                            avatarName = displayNames[option.id] ?: option.name,
                            isBlocked = !option.isSelected && state.assigneeLimitReached,
                            onToggle = { onToggle(option.id) },
                        )
                    }
                }
                item(key = "summary") {
                    TaskSectionFooter(assigneeSelectionSummary(state.assigneeIds.size))
                }
            }
        }
    }
}

/** A member: initials, name (« (vous) »), « Admin », checkbox. Dimmed when the limit of 20 is reached. */
@Composable
private fun AssigneeOptionRow(option: AssigneeOption, avatarName: String, isBlocked: Boolean, onToggle: () -> Unit) {
    val description = if (option.role == MemberRole.ADMIN) "${option.name}, ${option.role.label}" else option.name
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .toggleable(value = option.isSelected, role = Role.Checkbox, onValueChange = { onToggle() })
            .testTag(TaskTestTags.assigneeRow(option.name))
            .semantics { contentDescription = description }
            .heightIn(min = 56.dp)
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .alpha(if (isBlocked) 0.45f else 1f),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PersonAvatar(userId = option.id, name = avatarName, size = 36.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(option.name, style = MaterialTheme.typography.bodyLarge)
            if (option.role == MemberRole.ADMIN) {
                Text(
                    text = option.role.label,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Checkbox(checked = option.isSelected, onCheckedChange = null)
    }
}

/** Case- and accent-insensitive search on the displayed name (iOS `localizedStandardContains`). */
internal fun filterAssigneeOptions(options: List<AssigneeOption>, query: String): List<AssigneeOption> {
    if (query.isEmpty()) return options
    val key = NameOrder.key(query)
    return options.filter { NameOrder.key(it.name).contains(key) }
}

/** « 2 personnes sélectionnées sur 20 au maximum. » */
internal fun assigneeSelectionSummary(count: Int): String {
    val selected = if (count > 1) "$count personnes sélectionnées" else "$count personne sélectionnée"
    return "$selected sur ${TaskEditorViewModel.MAX_ASSIGNEES} au maximum."
}

