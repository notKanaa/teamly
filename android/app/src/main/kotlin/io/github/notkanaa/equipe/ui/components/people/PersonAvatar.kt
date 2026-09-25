package io.github.notkanaa.equipe.ui.components.people

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.notkanaa.equipe.core.uuidString
import java.util.UUID

// Initials avatars: the one avatar of the app (group header, task rows, members, task screen, assignee picker), so a
// person looks the same on every screen. Port of GroupsInitials, GroupsPalette, GroupsInitialsBadge,
// GroupsPersonAvatar and GroupsAvatarStack (App/Sources/Components/Groups/GroupsBadges.swift).

/** Initials of a name: « Coloc' rue des Lilas » → « CR », « Camille Martin » → « CM », « ? » when it has none. */
object PersonInitials {
    /**
     * The first letter or digit (with its combining marks) of each word, words being separated by white space or « - »,
     * [maxLetters] at most, upper-cased; « ? » when the name contains no letter and no digit.
     */
    fun make(name: String, maxLetters: Int = 2): String {
        val initials = StringBuilder()
        var count = 0
        for (word in words(name)) {
            val first = firstLetter(word) ?: continue
            initials.append(first)
            count++
            if (count >= maxLetters) break
        }
        return initials.toString().uppercase().ifEmpty { "?" }
    }

    private fun words(name: String): List<String> {
        val words = ArrayList<String>()
        val current = StringBuilder()
        var index = 0
        while (index < name.length) {
            val codePoint = name.codePointAt(index)
            if (isSeparator(codePoint)) {
                if (current.isNotEmpty()) {
                    words.add(current.toString())
                    current.setLength(0)
                }
            } else {
                current.appendCodePoint(codePoint)
            }
            index += Character.charCount(codePoint)
        }
        if (current.isNotEmpty()) words.add(current.toString())
        return words
    }

    private fun firstLetter(word: String): String? {
        var index = 0
        while (index < word.length) {
            val codePoint = word.codePointAt(index)
            val next = index + Character.charCount(codePoint)
            if (Character.isLetter(codePoint) || isNumber(codePoint)) {
                var end = next
                while (end < word.length) {
                    val mark = word.codePointAt(end)
                    if (!isCombiningMark(mark)) break
                    end += Character.charCount(mark)
                }
                return word.substring(index, end)
            }
            index = next
        }
        return null
    }

    private fun isSeparator(codePoint: Int): Boolean =
        codePoint == '-'.code || Character.isWhitespace(codePoint) || Character.isSpaceChar(codePoint)

    private fun isNumber(codePoint: Int): Boolean = when (Character.getType(codePoint)) {
        Character.DECIMAL_DIGIT_NUMBER.toInt(), Character.LETTER_NUMBER.toInt(), Character.OTHER_NUMBER.toInt() -> true
        else -> false
    }

    private fun isCombiningMark(codePoint: Int): Boolean = when (Character.getType(codePoint)) {
        Character.NON_SPACING_MARK.toInt(), Character.COMBINING_SPACING_MARK.toInt(), Character.ENCLOSING_MARK.toInt() -> true
        else -> false
    }
}

/**
 * Stable colors of people and groups: the same id always gets the same color, on every launch and on both platforms
 * (djb2 hash of the upper-case UUID string modulo the palette size, exactly like the iOS `GroupsPalette`).
 *
 * Same hues and order as iOS (blue, indigo, purple, pink, orange, teal, green, red, brown) in darker shades: white
 * initials reach at least 5.1:1 (WCAG AA: 4.5:1) on every one of them, whatever the theme.
 */
object PersonPalette {
    val colors: List<Color> = listOf(
        Color(0xFF1565C0), // blue    5.8:1 with white
        Color(0xFF3949AB), // indigo  7.7:1
        Color(0xFF7B1FA2), // purple  8.2:1
        Color(0xFFC2185B), // pink    5.9:1
        Color(0xFFA85400), // orange  5.3:1
        Color(0xFF00796B), // teal    5.3:1
        Color(0xFF2E7D32), // green   5.1:1
        Color(0xFFC62828), // red     5.6:1
        Color(0xFF795548), // brown   6.5:1
    )

    /** Index in [colors] of [id]: djb2 over the UTF-8 bytes of `uuidString`, 64-bit wrapping, unsigned remainder. */
    fun index(id: UUID): Int {
        var hash = 5381L
        for (byte in id.uuidString.toByteArray(Charsets.UTF_8)) {
            hash = hash * 33 + (byte.toInt() and 0xFF)
        }
        return java.lang.Long.remainderUnsigned(hash, colors.size.toLong()).toInt()
    }

    fun color(id: UUID): Color = colors[index(id)]
}

/**
 * A person's initials on their color (derived from [userId]), in a circle. Decorative: hidden from TalkBack (the row
 * that shows it says the name). The initials keep their size relative to the avatar at every font scale.
 */
@Composable
fun PersonAvatar(userId: UUID, name: String, size: Dp = 36.dp, modifier: Modifier = Modifier) {
    val initials = remember(name) { PersonInitials.make(name) }
    InitialsBadge(
        text = initials,
        color = PersonPalette.color(userId),
        size = size,
        shape = CircleShape,
        modifier = modifier,
    )
}

/**
 * A few people as [PersonAvatar]s side by side (the first [maxVisible]), then « +N ». Decorative (hidden from
 * TalkBack); an empty list shows a neutral person icon.
 */
@Composable
fun PersonAvatarStack(
    people: List<Pair<UUID, String>>,
    modifier: Modifier = Modifier,
    maxVisible: Int = 3,
    size: Dp = 26.dp,
) {
    Row(
        modifier = modifier.clearAndSetSemantics { },
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (people.isEmpty()) {
            Icon(
                imageVector = Icons.Outlined.Person,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(size),
            )
        } else {
            for ((id, name) in people.take(maxVisible)) {
                PersonAvatar(userId = id, name = name, size = size)
            }
            val hidden = people.size - maxVisible
            if (hidden > 0) {
                val tint = MaterialTheme.colorScheme.onSurfaceVariant
                Box(
                    modifier = Modifier
                        .size(size)
                        .clip(CircleShape)
                        .background(tint.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center,
                ) {
                    FittedInitials(text = "+$hidden", color = tint, size = size)
                }
            }
        }
    }
}

/**
 * Initials (or any short text) in white on [color] (a subtle top-to-bottom darkening, like the iOS `color.gradient`,
 * that only increases the contrast), clipped to [shape]. Decorative: hidden from TalkBack.
 */
@Composable
fun InitialsBadge(text: String, color: Color, size: Dp, shape: Shape, modifier: Modifier = Modifier) {
    val brush = remember(color) { Brush.verticalGradient(listOf(color, lerp(color, Color.Black, 0.14f))) }
    Box(
        modifier = modifier
            .size(size)
            .clip(shape)
            .background(brush)
            .clearAndSetSemantics { },
        contentAlignment = Alignment.Center,
    ) {
        FittedInitials(text = text, color = Color.White, size = size)
    }
}

/** Semibold text at 38 % of [size] (shrunk to fit, never wrapped), independent of the font scale like on iOS. */
@Composable
private fun FittedInitials(text: String, color: Color, size: Dp) {
    val density = LocalDensity.current
    val maxFontSize = with(density) { (size * 0.38f).toSp() }
    val minFontSize = with(density) { (size * 0.19f).toSp() }
    BasicText(
        text = text,
        style = TextStyle(
            color = color,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
            fontSize = maxFontSize,
        ),
        maxLines = 1,
        softWrap = false,
        autoSize = TextAutoSize.StepBased(minFontSize = minFontSize, maxFontSize = maxFontSize, stepSize = 0.5.sp),
    )
}
