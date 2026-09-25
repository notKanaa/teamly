import Foundation
import Testing
@testable import TeamTasksCore

/// French typography of the user-facing strings: the app layer writes the apostrophe ’ (U+2019), so the strings of
/// the package shown on the same screens must too (review UX-05).
@MainActor
@Suite struct WordingTests {
    static let paris = TimeZone(identifier: "Europe/Paris")!
    static let calendar = Calendar.frenchGregorian(timeZone: paris)

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// The error cases added by docs/CONTRACTS-V2.md §3.
    static let v2Errors: [AppError] = [
        .invalidAppearance, .invalidRecurrence, .recurrenceNeedsDueDate, .invalidRotation, .invalidChecklistItem,
        .tooManyChecklistItems,
    ]

    @Test func userFacingStringsUseTheTypographicApostrophe() {
        let formatter = FrenchDateFormatter(timeZone: Self.paris)
        let now = Self.date(2026, 9, 24, 10)
        let errors: [AppError] = [
            .notAuthenticated, .invalidCredentials, .emailAlreadyUsed, .weakPassword, .invalidEmail, .otpInvalid,
            .emailRateLimited, .emailNotConfirmed, .invalidDisplayName, .invalidName, .invalidTitle, .invalidDetails,
            .invalidInput, .invalidCode, .rateLimited, .lastAdmin, .notMember, .cannotRemoveSelf, .assigneeNotMember,
            .tooManyAssignees, .forbidden, .forbiddenFields, .notFound, .conflict, .network, .misconfigured,
        ] + Self.v2Errors
        let shown: [String] = errors.map(\.messageFR)
            + DueBucket.allCases.map(\.title)
            + ReminderLeadTime.allCases.map(\.label)
            + [
                AssignmentNotifier.rotationTurnTitle,
                AssignmentNotifier.rotationTurnBody(taskTitle: "Sortir les poubelles", groupName: "Coloc’ rue des Lilas"),
                formatter.relativeDay(now, relativeTo: now),
                DateText.relative(now, now: now, calendar: Self.calendar),
                GroupsListViewModel.emptyMessage,
                GroupDetailViewModel.emptyMessage,
                GroupDetailViewModel.goneMessage,
                TaskDetailViewModel.goneMessage,
                TaskEditorViewModel.invalidDueDateMessage,
                TaskEditorViewModel.departedAssigneesMessage,
                PasswordResetViewModel.resentMessage,
                PasswordResetViewModel.recoveryEndedMessage,
                SettingsViewModel.pushDisabledExplanation,
                SettingsViewModel.pushPrivacyNote,
            ]
            + SettingsViewModel.pushInstructionSteps
        #expect(DueBucket.today.title == "Aujourd’hui")
        let ascii = shown.filter { $0.contains("'") }
        #expect(ascii.isEmpty, "ASCII apostrophes in user-facing strings: \(ascii)")
    }

    /// Guard: no string literal of TeamTasksCore or TeamTasksSupabase contains the ASCII apostrophe (the demo data
    /// of TeamTasksMocks mirrors `supabase/seed.sql` and is not scanned).
    @Test func sourceStringLiteralsUseTheTypographicApostrophe() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Logic
            .deletingLastPathComponent() // TeamTasksCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        var offenders: [String] = []
        var scanned = 0
        for target in ["TeamTasksCore", "TeamTasksSupabase"] {
            let directory = packageRoot.appendingPathComponent("Sources").appendingPathComponent(target)
            let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                scanned += 1
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() where !line.contains("emailLocalCharacters") {
                    for literal in Self.stringLiterals(in: line) where literal.contains("'") {
                        offenders.append("\(file.lastPathComponent):\(index + 1): \(literal)")
                    }
                }
            }
        }
        #expect(scanned > 20, "sources not found under \(packageRoot.path)")
        #expect(offenders.isEmpty, "use ’ instead of ': \(offenders)")
    }

    /// The contents of the `"…"` literals of one line of Swift, ignoring what follows `//`.
    static func stringLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var current: String?
        var escaped = false
        var previous: Character?
        for character in line {
            if var literal = current {
                if escaped {
                    escaped = false
                    literal.append(character)
                } else if character == "\\" {
                    escaped = true
                    literal.append(character)
                } else if character == "\"" {
                    literals.append(literal)
                    literal = ""
                    current = nil
                    previous = character
                    continue
                } else {
                    literal.append(character)
                }
                current = literal
            } else if character == "\"" {
                current = ""
            } else if character == "/", previous == "/" {
                break
            }
            previous = character
        }
        return literals
    }

    @Test func literalScanner() {
        #expect(Self.stringLiterals(in: #"let a = "l’eau" + "d'accord" // "c'est""#) == ["l’eau", "d'accord"])
        #expect(Self.stringLiterals(in: #"x("a \"b\" c", "d")"#) == [#"a \"b\" c"#, "d"])
        #expect(Self.stringLiterals(in: "/// « Aujourd'hui »").isEmpty)
    }

    // MARK: - No-break spaces (review UX-14)

    /// French typography: a no-break space (U+00A0, or the narrow U+202F) before « ? ! : ; » and inside « », so that
    /// the punctuation never starts a line.
    @Test func userFacingStringsUseNoBreakSpaces() throws {
        let code = try #require(InviteCode("LYLAS234"))
        let shown: [String] = ([
            AppError.notAuthenticated, .invalidCredentials, .emailAlreadyUsed, .weakPassword, .invalidEmail, .otpInvalid,
            .emailRateLimited, .emailNotConfirmed, .invalidDisplayName, .invalidName, .invalidTitle, .invalidDetails,
            .invalidInput, .invalidCode, .rateLimited, .lastAdmin, .notMember, .cannotRemoveSelf, .assigneeNotMember,
            .tooManyAssignees, .forbidden, .forbiddenFields, .notFound, .conflict, .network, .misconfigured,
        ] + Self.v2Errors).map(\.messageFR) + [
            AssignmentNotifier.rotationTurnTitle,
            AssignmentNotifier.rotationTurnBody(taskTitle: "Sortir les poubelles", groupName: "Coloc’ rue des Lilas"),
            AssignmentNotifier.rotationTurnBody(taskTitle: "Vaisselle", groupName: nil),
            SettingsViewModel.deleteAccountWarning,
            SettingsViewModel.pushPrivacyNote,
            SettingsViewModel.pushDisabledExplanation,
            TaskEditorViewModel.departedAssigneesMessage,
            MembersViewModel.shareText(groupName: "Coloc", code: code),
        ] + SettingsViewModel.pushInstructionSteps
        let problems = shown.flatMap { text in Self.typographyProblems(in: text).map { "\($0) in « \(text) »" } }
        #expect(problems.isEmpty, "\(problems)")
        #expect(AppError.lastAdmin.messageFR == "Vous êtes le seul admin\u{00A0}: nommez d’abord un autre admin.")
        #expect(AppError.cannotRemoveSelf.messageFR == "Utilisez «\u{00A0}Quitter le groupe\u{00A0}» pour vous retirer vous-même.")
    }

    /// Guard: no string literal of TeamTasksCore has a plain space (or no space) before « ? ! : ; » or inside « ».
    /// Interpolations are left out; `\u{00A0}` escapes count as no-break spaces.
    @Test func sourceStringLiteralsUseNoBreakSpaces() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Logic
            .deletingLastPathComponent() // TeamTasksCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("TeamTasksCore")
        var offenders: [String] = []
        var scanned = 0
        var withGuillemets = 0
        let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            scanned += 1
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                for text in Self.literalTexts(in: line) {
                    if text.contains("«") { withGuillemets += 1 }
                    for problem in Self.typographyProblems(in: text) {
                        offenders.append("\(file.lastPathComponent):\(index + 1): \(problem) in « \(text) »")
                    }
                }
            }
        }
        #expect(scanned > 20, "sources not found under \(directory.path)")
        #expect(withGuillemets > 5, "the scanner found no « » literal: is it still reading the sources?")
        #expect(offenders.isEmpty, "use a no-break space (\\u{00A0}): \(offenders)")
    }

    static func isNoBreakSpace(_ character: Character?) -> Bool {
        character == "\u{00A0}" || character == "\u{202F}"
    }

    /// What breaks the French spacing rules in `text`: a plain space before « ? ! : ; », « not followed or » not
    /// preceded by a no-break space.
    static func typographyProblems(in text: String) -> [String] {
        let characters = Array(text)
        var problems: [String] = []
        for (index, character) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if "?!:;".contains(character), previous == " " {
                problems.append("plain space before « \(character) »")
            }
            if character == "«", !isNoBreakSpace(next) {
                problems.append("no no-break space after «")
            }
            if character == "»", !isNoBreakSpace(previous) {
                problems.append("no no-break space before »")
            }
        }
        return problems
    }

    /// The texts of the `"…"` literals of one line of Swift, as shown: escapes decoded (`\u{00A0}` included), each
    /// interpolation `\(…)` replaced by `_`; what follows `//` outside a literal is ignored.
    static func literalTexts(in line: String) -> [String] {
        let characters = Array(line)
        var texts: [String] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" { break }
            guard character == "\"" else {
                index += 1
                continue
            }
            var text = ""
            index += 1
            while index < characters.count, characters[index] != "\"" {
                guard characters[index] == "\\", index + 1 < characters.count else {
                    text.append(characters[index])
                    index += 1
                    continue
                }
                let escaped = characters[index + 1]
                if escaped == "(" {
                    index = endOfInterpolation(in: characters, openingAt: index + 1)
                    text.append("_")
                } else if escaped == "u", let escape = unicodeEscape(in: characters, braceAt: index + 2) {
                    text.append(Character(escape.scalar))
                    index = escape.end
                } else {
                    text.append(escaped)
                    index += 2
                }
            }
            texts.append(text)
            index += 1
        }
        return texts
    }

    /// Index just after the `)` closing the parenthesis at `open` (nested parentheses and literals included).
    private static func endOfInterpolation(in characters: [Character], openingAt open: Int) -> Int {
        var depth = 0
        var inLiteral = false
        var index = open
        while index < characters.count {
            let character = characters[index]
            if inLiteral {
                if character == "\\" {
                    index += 1
                } else if character == "\"" {
                    inLiteral = false
                }
            } else if character == "\"" {
                inLiteral = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return index
    }

    /// The scalar of `\u{XXXX}` whose `{` is at `brace`, and the index just after its `}`.
    private static func unicodeEscape(in characters: [Character], braceAt brace: Int) -> (scalar: Unicode.Scalar, end: Int)? {
        guard brace < characters.count, characters[brace] == "{",
              let close = characters[brace...].firstIndex(of: "}"),
              let value = UInt32(String(characters[(brace + 1)..<close]), radix: 16),
              let scalar = Unicode.Scalar(value)
        else { return nil }
        return (scalar, close + 1)
    }

    @Test func noBreakSpaceScanner() {
        #expect(Self.literalTexts(in: #"let a = "Vous\u{00A0}: \(x ? "a" : "b") !" // "c ?""#) == ["Vous\u{00A0}: _ !"])
        #expect(Self.literalTexts(in: #"f("«\u{00A0}\(name)\u{00A0}»", "a \"b\"")"#) == ["«\u{00A0}_\u{00A0}»", #"a "b""#])
        #expect(Self.typographyProblems(in: "Vous\u{00A0}: _ !") == ["plain space before « ! »"])
        #expect(Self.typographyProblems(in: "« x»").count == 2)
        #expect(Self.typographyProblems(in: "«\u{00A0}x\u{202F}»\u{00A0}?").isEmpty)
        #expect(Self.typographyProblems(in: "https://ntfy.sh 20:00").isEmpty)
    }
}
