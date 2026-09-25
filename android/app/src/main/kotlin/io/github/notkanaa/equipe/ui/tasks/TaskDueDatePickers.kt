package io.github.notkanaa.equipe.ui.tasks

import android.content.res.Configuration
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimeInput
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TimePickerDialog
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset
import java.util.Locale

// Material 3 date and time pickers of the task editor, always in French (24 h) whatever the device language.

/**
 * Runs [content] with a French configuration and context, so that the Material pickers use French month and day names,
 * French strings (« Sélectionner une date ») and French date formats even on a device set to another language.
 * A dialog's window provides its own configuration and context again: wrap the dialog's content too.
 */
@Composable
internal fun FrenchLocale(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val french = remember(configuration) {
        Configuration(configuration).apply { setLocale(Locale.FRANCE) }
    }
    val frenchContext = remember(context, french) { context.createConfigurationContext(french) }
    CompositionLocalProvider(
        LocalConfiguration provides french,
        LocalContext provides frenchContext,
        content = content,
    )
}

/**
 * Date picker dialog of the due date. [initialDate] and the result are calendar days (the caller combines them with the
 * time of day in the app's time zone). Years 1970 to 2100 (or the initial year), inside the accepted due-date range.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TaskDatePickerDialog(initialDate: LocalDate, onDismiss: () -> Unit, onConfirm: (LocalDate) -> Unit) {
    FrenchLocale {
        // The picker requires its initial month inside the year range: dates outside 1970–9999 cannot be due dates anyway.
        val shownDate = remember(initialDate) {
            val first = LocalDate.of(MIN_YEAR, 1, 1)
            val last = LocalDate.of(LAST_YEAR, 12, 31)
            when {
                initialDate.isBefore(first) -> first
                initialDate.isAfter(last) -> last
                else -> initialDate
            }
        }
        val initialMillis = remember(shownDate) { shownDate.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli() }
        val yearRange = remember(shownDate) { IntRange(MIN_YEAR, maxOf(MAX_YEAR, shownDate.year)) }
        val state = rememberDatePickerState(
            initialSelectedDateMillis = initialMillis,
            initialDisplayedMonthMillis = initialMillis,
            yearRange = yearRange,
        )
        DatePickerDialog(
            onDismissRequest = onDismiss,
            confirmButton = {
                TextButton(
                    onClick = {
                        val millis = state.selectedDateMillis
                        if (millis != null) onConfirm(Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate())
                    },
                    enabled = state.selectedDateMillis != null,
                ) {
                    Text("OK")
                }
            },
            dismissButton = {
                TextButton(onClick = onDismiss) { Text("Annuler") }
            },
        ) {
            // The dialog's window provides its own configuration and context: French again inside it.
            FrenchLocale { DatePicker(state = state, showModeToggle = true) }
        }
    }
}

/** Time picker dialog of the due date (24 h dial, or keyboard input). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TaskTimePickerDialog(initialTime: LocalTime, onDismiss: () -> Unit, onConfirm: (LocalTime) -> Unit) {
    FrenchLocale {
        val state = rememberTimePickerState(
            initialHour = initialTime.hour,
            initialMinute = initialTime.minute,
            is24Hour = true,
        )
        var showsKeyboardInput by remember { mutableStateOf(false) }
        TimePickerDialog(
            onDismissRequest = onDismiss,
            confirmButton = {
                TextButton(onClick = { onConfirm(LocalTime.of(state.hour, state.minute)) }) { Text("OK") }
            },
            title = { Text("Heure d’échéance") },
            modeToggleButton = {
                IconButton(onClick = { showsKeyboardInput = !showsKeyboardInput }) {
                    Icon(
                        imageVector = if (showsKeyboardInput) Icons.Outlined.Schedule else Icons.Outlined.Keyboard,
                        contentDescription = if (showsKeyboardInput) "Choisir sur le cadran" else "Saisir au clavier",
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = onDismiss) { Text("Annuler") }
            },
        ) {
            Box(Modifier.fillMaxWidth().padding(top = 8.dp), contentAlignment = Alignment.Center) {
                FrenchLocale { if (showsKeyboardInput) TimeInput(state = state) else TimePicker(state = state) }
            }
        }
    }
}

/** First year of the accepted due dates (`InputValidation.dueDateRange` starts on 1970-01-01 UTC). */
private const val MIN_YEAR = 1970

/** Last year offered by default (extended to the task's year if later). */
private const val MAX_YEAR = 2100

/** Last year of the accepted due dates (`InputValidation.dueDateRange` ends before 10000-01-01 UTC). */
private const val LAST_YEAR = 9999
