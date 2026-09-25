package io.github.notkanaa.equipe.ui.theme

import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

// Colours of « Équipe », close to the iOS app: a light grey grouped background with white cards (dark: black
// background, dark grey cards) and the brand blue.
//
// The surface roles follow the Material tonal ladder (light: lowest = white … highest = darkest grey; dark: lowest =
// black … highest = lightest grey), so that the screens can pick them without knowing the theme:
//
//                         light      dark
//   background, surface   #F2F2F7    #000000    screens, top app bars (they blend in, like iOS large titles)
//   surfaceContainerLowest #FFFFFF   #000000
//   surfaceContainerLow   #F7F7FA    #0E0E10
//   surfaceContainer      #F2F2F7    #151517
//   surfaceContainerHigh  #ECECF1    #1C1C1E    (dialogs)
//   surfaceContainerHighest #E5E5EA  #2C2C2E    (filled fields)
//
// Grouped screens: background = light surfaceContainer / dark surfaceContainerLowest, cards = light
// surfaceContainerLowest / dark surfaceContainerHigh (what the task screens use; the shell's own screens use
// [EquipeExtendedColors.card]).
//
// Text contrast (WCAG AA, 4.5:1): every text colour passes on the background and on the cards in both themes, except
// the light brand primary #416CD9 on the grey background (4.3:1): accent-coloured text drawn directly on the
// background uses [EquipeExtendedColors.accentText] (#2F59C4 in light mode, like the iOS PaletteAccentText).

/** Brand colours (app icon, splash screen, brand mark). */
object EquipeBrand {
    /** Accent blue of the app icon, start of the brand gradient (#416CD9). */
    val Blue: Color = Color(0xFF416CD9)

    /** Indigo end of the brand gradient (#5838B3). */
    val Indigo: Color = Color(0xFF5838B3)

    /** Gradient of the app icon, top-start to bottom-end. */
    val gradient: Brush get() = Brush.linearGradient(listOf(Blue, Indigo))
}

/** Colours Material 3 has no role for, readable (AA) in the current theme. */
@Immutable
data class EquipeExtendedColors(
    /** Cards and rows on the grouped background: #FFFFFF light, #1C1C1E dark. */
    val card: Color,
    /** Accent-coloured text on the background or a card (links, text buttons): #2F59C4 light, #6894F4 dark. */
    val accentText: Color,
    /** Success (done, password changed): #19702F light, #30D158 dark. */
    val success: Color,
    /** Warning (configuration problems): #9C4C00 light, #FF9F0A dark. */
    val warning: Color,
)

internal val LightExtendedColors = EquipeExtendedColors(
    card = Color(0xFFFFFFFF),
    accentText = Color(0xFF2F59C4),
    success = Color(0xFF19702F),
    warning = Color(0xFF9C4C00),
)

internal val DarkExtendedColors = EquipeExtendedColors(
    card = Color(0xFF1C1C1E),
    accentText = Color(0xFF6894F4),
    success = Color(0xFF30D158),
    warning = Color(0xFFFF9F0A),
)

internal val EquipeLightColors = lightColorScheme(
    primary = Color(0xFF416CD9),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFDCE3FB),
    onPrimaryContainer = Color(0xFF10307A),
    inversePrimary = Color(0xFF6894F4),
    secondary = Color(0xFF4A5A85),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFDCE3FB),
    onSecondaryContainer = Color(0xFF10307A),
    tertiary = Color(0xFF5838B3),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFEADDFF),
    onTertiaryContainer = Color(0xFF25005A),
    background = Color(0xFFF2F2F7),
    onBackground = Color(0xFF111114),
    surface = Color(0xFFF2F2F7),
    onSurface = Color(0xFF111114),
    surfaceVariant = Color(0xFFE5E5EA),
    onSurfaceVariant = Color(0xFF636368),
    surfaceTint = Color(0xFF416CD9),
    inverseSurface = Color(0xFF2C2C2E),
    inverseOnSurface = Color(0xFFF2F2F7),
    error = Color(0xFFC4221A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),
    outline = Color(0xFF7C7C80),
    outlineVariant = Color(0xFFD1D1D6),
    scrim = Color(0xFF000000),
    surfaceBright = Color(0xFFFFFFFF),
    surfaceDim = Color(0xFFDCDCE1),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF7F7FA),
    surfaceContainer = Color(0xFFF2F2F7),
    surfaceContainerHigh = Color(0xFFECECF1),
    surfaceContainerHighest = Color(0xFFE5E5EA),
)

internal val EquipeDarkColors = darkColorScheme(
    primary = Color(0xFF6894F4),
    onPrimary = Color(0xFF00174B),
    primaryContainer = Color(0xFF274AA8),
    onPrimaryContainer = Color(0xFFDCE3FB),
    inversePrimary = Color(0xFF416CD9),
    secondary = Color(0xFFB6C4EC),
    onSecondary = Color(0xFF1B2B55),
    secondaryContainer = Color(0xFF2A3F7A),
    onSecondaryContainer = Color(0xFFDCE3FB),
    tertiary = Color(0xFFCDBDFF),
    onTertiary = Color(0xFF35158A),
    tertiaryContainer = Color(0xFF4A2EA0),
    onTertiaryContainer = Color(0xFFEADDFF),
    background = Color(0xFF000000),
    onBackground = Color(0xFFF2F2F7),
    surface = Color(0xFF000000),
    onSurface = Color(0xFFF2F2F7),
    surfaceVariant = Color(0xFF2C2C2E),
    onSurfaceVariant = Color(0xFFAEAEB2),
    surfaceTint = Color(0xFF6894F4),
    inverseSurface = Color(0xFFE5E5EA),
    inverseOnSurface = Color(0xFF1C1C1E),
    error = Color(0xFFFF6961),
    onError = Color(0xFF5C0002),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    outline = Color(0xFF8E8E93),
    outlineVariant = Color(0xFF38383A),
    scrim = Color(0xFF000000),
    surfaceBright = Color(0xFF3A3A3C),
    surfaceDim = Color(0xFF000000),
    surfaceContainerLowest = Color(0xFF000000),
    surfaceContainerLow = Color(0xFF0E0E10),
    surfaceContainer = Color(0xFF151517),
    surfaceContainerHigh = Color(0xFF1C1C1E),
    surfaceContainerHighest = Color(0xFF2C2C2E),
)
