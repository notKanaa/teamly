package io.github.notkanaa.equipe.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F

/**
 * French typography of the user-facing strings of the logic package (port of the logic parts of
 * Logic/WordingTests.swift; the AppError messages are checked by AppErrorTest): the apostrophe is ’ (U+2019), never the
 * ASCII one (review UX-05), and a no-break space (U+00A0 or U+202F) comes before « ? ! : ; » and inside « » (review
 * UX-14).
 */
class LogicWordingTest {
    private fun shownStrings(): List<String> {
        val formatter = FrenchDateFormatter(F.paris)
        val now = F.date(2026, 9, 24, 10, 0)
        val planner = ReminderPlanner(F.parisCalendar)
        val reminder = planner.plan(
            listOf(F.task(1, title = "Sortir les poubelles", due = F.date(2026, 9, 24, 20, 0), groupName = "Coloc")),
            F.me,
            ReminderLeadTime.ONE_HOUR,
            now,
        ).single()
        return DueBucket.entries.map { it.title } +
            ReminderLeadTime.entries.map { it.label } +
            TaskStatusFilter.entries.map { it.label } +
            TaskSort.entries.map { it.label } +
            FrenchDateFormatter.WEEKDAY_NAMES +
            FrenchDateFormatter.MONTH_NAMES +
            listOf(
                formatter.relativeDay(now, now),
                formatter.relativeDateTime(F.date(2026, 9, 25, 9, 0), now),
                formatter.relativeDateTimeInSentence(F.date(2026, 9, 14, 10, 0), now),
                reminder.title,
                reminder.body,
                AssignmentNotifier.INDIVIDUAL_TITLE,
                AssignmentNotifier.SUMMARY_TITLE,
            )
    }

    @Test
    fun userFacingStringsUseTheTypographicApostrophe() {
        assertEquals("Aujourd’hui", DueBucket.TODAY.title)
        assertEquals("aujourd’hui", FrenchDateFormatter(F.paris).relativeDay(F.date(2026, 9, 24), F.date(2026, 9, 24)))
        val ascii = shownStrings().filter { it.contains('\'') }
        assertTrue("ASCII apostrophes in user-facing strings: $ascii", ascii.isEmpty())
    }

    @Test
    fun userFacingStringsUseNoBreakSpaces() {
        val problems = shownStrings().flatMap { text -> typographyProblems(text).map { "$it in « $text »" } }
        assertTrue("$problems", problems.isEmpty())
    }

    /** Guard: no string literal of the logic package has an ASCII apostrophe or breaks the no-break space rules. */
    @Test
    fun sourceStringLiteralsFollowTheFrenchTypography() {
        val directory = logicSourceDirectory()
        val files = directory.listFiles { file -> file.extension == "kt" }.orEmpty().sortedBy { it.name }
        assertTrue("sources not found under $directory", files.size >= 10)
        val offenders = ArrayList<String>()
        var literals = 0
        var withTypographicApostrophe = 0
        for (file in files) {
            for (literal in stringLiterals(file.readText())) {
                literals += 1
                if (literal.text.contains('’')) withTypographicApostrophe += 1
                if (literal.text.contains('\'')) offenders.add("${file.name}:${literal.line}: ASCII apostrophe in « ${literal.text} »")
                for (problem in typographyProblems(literal.text)) {
                    offenders.add("${file.name}:${literal.line}: $problem in « ${literal.text} »")
                }
            }
        }
        assertTrue("the scanner found no literal: is it still reading the sources?", literals > 50)
        assertTrue("no literal with ’ found: is it still reading the sources?", withTypographicApostrophe >= 3)
        assertTrue("use ’ and no-break spaces (\\u00A0): $offenders", offenders.isEmpty())
    }

    @Test
    fun literalScanner() {
        val code = listOf(
            "val a = \"l’eau\" + \"d'accord\" // \"c'est\"",
            "/* \"commentaire\" /* imbriqué */ \"toujours\" */",
            "val b = '\"' + \"x\\\"y\\u00A0z\" + \"\${f(\"n\")} et \$name!\"",
            "val c = \"\"\"brut \"cité\" \${x}\"\"\"",
        ).joinToString("\n")
        assertEquals(
            listOf("l’eau", "d'accord", "x\"y z", "n", "_ et _!", "brut \"cité\" _"),
            stringLiterals(code).map { it.text },
        )
        assertEquals(listOf(1, 1, 3, 3, 3, 4), stringLiterals(code).map { it.line })
        assertEquals(listOf("plain space before « ! »"), typographyProblems("Vous : _ !"))
        assertEquals(2, typographyProblems("« x»").size)
        assertTrue(typographyProblems("« x » ?").isEmpty())
        assertTrue(typographyProblems("https://ntfy.sh 20:00").isEmpty())
    }

    // region Helpers

    class Literal(val line: Int, val text: String)

    private fun logicSourceDirectory(): File {
        val relative = "src/main/kotlin/io/github/notkanaa/equipe/core/logic"
        val start = File(System.getProperty("user.dir")).absoluteFile
        val candidates = listOf(File(start, relative), File(start, "core/$relative"), File(start, "android/core/$relative"))
        return candidates.firstOrNull { it.isDirectory } ?: candidates.first()
    }

    /** What breaks the French spacing rules in [text]. */
    private fun typographyProblems(text: String): List<String> {
        fun isNoBreakSpace(character: Char?): Boolean = character == ' ' || character == ' '
        val problems = ArrayList<String>()
        text.forEachIndexed { index, character ->
            val previous = text.getOrNull(index - 1)
            val next = text.getOrNull(index + 1)
            if (character in "?!:;" && previous == ' ') problems.add("plain space before « $character »")
            if (character == '«' && !isNoBreakSpace(next)) problems.add("no no-break space after «")
            if (character == '»' && !isNoBreakSpace(previous)) problems.add("no no-break space before »")
        }
        return problems
    }

    /**
     * The string literals of Kotlin source [code], as shown: escapes decoded (` ` included), each template
     * (`${…}`, `$name`) replaced by `_`. Comments (nested block comments included) and character literals are skipped;
     * the literals nested in templates are returned too.
     */
    private fun stringLiterals(code: String): List<Literal> {
        val literals = ArrayList<Literal>()
        var index = 0

        fun lineAt(position: Int): Int = 1 + (0 until position).count { code[it] == '\n' }

        fun skipBlockComment() {
            var depth = 0
            while (index < code.length) {
                when {
                    code.startsWith("/*", index) -> {
                        depth += 1
                        index += 2
                    }
                    code.startsWith("*/", index) -> {
                        depth -= 1
                        index += 2
                        if (depth == 0) return
                    }
                    else -> index += 1
                }
            }
        }

        fun skipCharLiteral() {
            index += 1 // opening '
            if (index < code.length && code[index] == '\\') {
                index += if (index + 1 < code.length && code[index + 1] == 'u') 6 else 2
            } else {
                index += 1
            }
            if (index < code.length && code[index] == '\'') index += 1
        }

        lateinit var lexString: (Boolean) -> Unit

        /** Code until the `}` closing a template (or the end when [untilBrace] is false). */
        fun lexCode(untilBrace: Boolean) {
            var depth = 0
            while (index < code.length) {
                val character = code[index]
                when {
                    code.startsWith("//", index) -> while (index < code.length && code[index] != '\n') index += 1
                    code.startsWith("/*", index) -> skipBlockComment()
                    code.startsWith("\"\"\"", index) -> lexString(true)
                    character == '"' -> lexString(false)
                    character == '\'' -> skipCharLiteral()
                    character == '{' -> {
                        depth += 1
                        index += 1
                    }
                    character == '}' -> {
                        index += 1
                        if (untilBrace && depth == 0) return
                        depth -= 1
                    }
                    else -> index += 1
                }
            }
        }

        lexString = { raw ->
            val line = lineAt(index)
            index += if (raw) 3 else 1
            val text = StringBuilder()
            var closed = false
            while (index < code.length && !closed) {
                val character = code[index]
                when {
                    raw && code.startsWith("\"\"\"", index) -> {
                        // A raw string ends at the last quote of a run of three or more.
                        var end = index + 3
                        while (end < code.length && code[end] == '"') end += 1
                        repeat(end - index - 3) { text.append('"') }
                        index = end
                        closed = true
                    }
                    !raw && character == '"' -> {
                        index += 1
                        closed = true
                    }
                    !raw && character == '\\' && index + 1 < code.length -> {
                        val escaped = code[index + 1]
                        if (escaped == 'u' && index + 5 < code.length) {
                            text.append(code.substring(index + 2, index + 6).toInt(16).toChar())
                            index += 6
                        } else {
                            text.append(
                                when (escaped) {
                                    't' -> '\t'
                                    'n' -> '\n'
                                    'r' -> '\r'
                                    'b' -> '\b'
                                    else -> escaped
                                },
                            )
                            index += 2
                        }
                    }
                    character == '$' && index + 1 < code.length && code[index + 1] == '{' -> {
                        index += 2
                        lexCode(untilBrace = true)
                        text.append('_')
                    }
                    character == '$' && index + 1 < code.length && (code[index + 1].isLetter() || code[index + 1] == '_') -> {
                        index += 1
                        while (index < code.length && (code[index].isLetterOrDigit() || code[index] == '_')) index += 1
                        text.append('_')
                    }
                    else -> {
                        text.append(character)
                        index += 1
                    }
                }
            }
            literals.add(Literal(line, text.toString()))
        }

        lexCode(untilBrace = false)
        return literals.sortedWith(compareBy<Literal> { it.line })
    }

    // endregion
}
