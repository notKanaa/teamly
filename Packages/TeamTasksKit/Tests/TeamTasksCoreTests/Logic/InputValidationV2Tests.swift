import Foundation
import Testing
@testable import TeamTasksCore

/// docs/CONTRACTS-V2.md §1, §3, §5: the cases of pgTAP `12_v2_appearance_onboarding`, `13_v2_recurrence`,
/// `14_v2_spawn_rotation` and `15_v2_checklist` that the client can check.
@Suite struct InputValidationV2Tests {
    // MARK: Emoji

    @Test func emojiIsTrimmedAndBlankMeansNone() throws {
        #expect(try InputValidation.emoji(nil) == nil)
        #expect(try InputValidation.emoji(" \t🏠 ") == "🏠")
        #expect(try InputValidation.emoji(" \u{200B}\u{3000} ") == nil)
        #expect(try InputValidation.emoji("") == nil)
    }

    @Test func emojiSequencesAreAccepted() throws {
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        #expect(family.unicodeScalars.count == 7)
        #expect(try InputValidation.emoji(family) == family)
        #expect(try InputValidation.emoji("🇫🇷") == "🇫🇷")
        #expect(try InputValidation.emoji("1\u{FE0F}\u{20E3}") == "1\u{FE0F}\u{20E3}")
        #expect(try InputValidation.emoji("⚽") == "⚽")
        // Any code point outside the forbidden set counts, like the SQL rule (the clients offer a curated grid).
        #expect(try InputValidation.emoji("x") == "x")
    }

    @Test func emojiHasAtMostSixteenCodePoints() throws {
        let sixteen = String(repeating: "😀", count: 16)
        #expect(try InputValidation.emoji(sixteen) == sixteen)
        #expect(throws: AppError.invalidAppearance) { try InputValidation.emoji(String(repeating: "😀", count: 17)) }
    }

    @Test(arguments: [
        "😀 😀", "😀\u{00A0}😀", "😀\u{200B}😀", "😀\u{7}", "😀\u{85}😀", "😀\u{9F}", "😀\u{1F}", "\u{0}", "😀\u{0}", "x y",
    ])
    func emojiRefusesSpacesAndControls(_ value: String) {
        #expect(throws: AppError.invalidAppearance) { try InputValidation.emoji(value) }
    }

    /// Exactly U+0000–U+0020, U+007F–U+00A0, U+1680, U+2000–U+200B, U+2028, U+2029, U+202F, U+205F, U+3000.
    @Test func forbiddenEmojiCodePointsArePinned() {
        let expected: [UInt32] = Array(UInt32(0)...0x20) + Array(UInt32(0x7F)...0xA0) + [0x1680]
            + Array(UInt32(0x2000)...0x200B) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
        var found: [UInt32] = []
        for value in UInt32(0)...0x3100 {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if InputValidation.isForbiddenInEmoji(scalar) { found.append(value) }
        }
        #expect(found == expected)
        #expect(!InputValidation.isForbiddenInEmoji("\u{200D}"))
        #expect(!InputValidation.isForbiddenInEmoji("\u{FE0F}"))
    }

    // MARK: Color

    @Test func colorKeysAreExact() throws {
        #expect(try InputValidation.colorKey(nil) == nil)
        for key in ColorKey.allCases {
            #expect(try InputValidation.colorKey(key.rawValue) == key)
        }
        for invalid in ["Coral", "", "red", " coral", "CORAL"] {
            #expect(throws: AppError.invalidAppearance, "\(invalid)") { try InputValidation.colorKey(invalid) }
        }
    }

    // MARK: Recurrence

    private func rule(
        _ frequency: RecurrenceRule.Frequency = .daily,
        interval: Int = 1,
        weekdays: Set<Int>? = nil,
        tz: String = "Europe/Paris"
    ) -> RecurrenceRule {
        RecurrenceRule(frequency: frequency, interval: interval, weekdays: weekdays, timeZoneId: tz)
    }

    @Test func intervalIsOneToFiftyTwo() throws {
        #expect(try InputValidation.recurrence(rule(interval: 1)) == rule(interval: 1))
        #expect(try InputValidation.recurrence(rule(interval: 52)) == rule(interval: 52))
        for interval in [0, 53, -1] {
            #expect(throws: AppError.invalidRecurrence) { try InputValidation.recurrence(rule(interval: interval)) }
        }
    }

    @Test func weekdaysOnlyOnWeeklyRules() throws {
        #expect(try InputValidation.recurrence(rule(.weekly, weekdays: [1, 3, 5])).weekdays == [1, 3, 5])
        #expect(try InputValidation.recurrence(rule(.weekly, weekdays: Set(1...7))).weekdays == Set(1...7))
        #expect(try InputValidation.recurrence(rule(.weekly)).weekdays == nil)
        let invalid: [RecurrenceRule] = [
            rule(.daily, weekdays: [1]), rule(.monthly, weekdays: [1]), rule(.weekly, weekdays: []),
            rule(.weekly, weekdays: [0]), rule(.weekly, weekdays: [8]), rule(.weekly, weekdays: [1, 8]),
        ]
        for value in invalid {
            #expect(throws: AppError.invalidRecurrence, "\(value)") { try InputValidation.recurrence(value) }
        }
    }

    @Test func timeZonesAreExactIANANames() throws {
        for valid in ["Europe/Paris", "UTC", "America/Argentina/Buenos_Aires", "America/New_York", "Asia/Tokyo"] {
            #expect(InputValidation.isValidTimeZoneId(valid), "\(valid)")
            #expect(try InputValidation.recurrence(rule(tz: valid)).timeZoneId == valid)
        }
        for invalid in ["", "Europe/Pariss", "europe/paris", "EUROPE/PARIS", "posix/Europe/Paris", "right/Europe/Paris",
                        "Factory", "UTC+3", "GMT+3", "CEST", "Europe/Paris ", "Mars/Olympus_Mons"] {
            #expect(!InputValidation.isValidTimeZoneId(invalid), "\(invalid)")
            #expect(throws: AppError.invalidRecurrence, "\(invalid)") { try InputValidation.recurrence(rule(tz: invalid)) }
        }
    }

    @Test func aRecurrenceNeedsADueDateAfterItsShape() throws {
        let due = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(try InputValidation.recurrence(nil, dueAt: nil) == nil)
        #expect(try InputValidation.recurrence(nil, dueAt: due) == nil)
        #expect(try InputValidation.recurrence(rule(), dueAt: due) == rule())
        #expect(throws: AppError.recurrenceNeedsDueDate) { try InputValidation.recurrence(rule(), dueAt: nil) }
        // The shape first.
        #expect(throws: AppError.invalidRecurrence) { try InputValidation.recurrence(rule(interval: 0), dueAt: nil) }
    }

    // MARK: Rotation

    @Test func rotationRules() throws {
        let ids = (0..<21).map { _ in UUID() }
        let weekly = rule(.weekly)
        #expect(try InputValidation.rotation([], recurrence: nil) == [])
        #expect(try InputValidation.rotation([], recurrence: weekly) == [])
        #expect(try InputValidation.rotation(Array(ids.prefix(2)), recurrence: weekly) == Array(ids.prefix(2)))
        #expect(try InputValidation.rotation(Array(ids.prefix(20)), recurrence: weekly) == Array(ids.prefix(20)))
        let invalid: [([UUID], RecurrenceRule?)] = [
            (Array(ids.prefix(2)), nil), // without recurrence
            ([ids[0]], weekly), // 1 user
            (ids, weekly), // 21 users
            ([ids[0], ids[1], ids[0]], weekly), // duplicates
        ]
        for (value, recurrence) in invalid {
            #expect(throws: AppError.invalidRotation) { try InputValidation.rotation(value, recurrence: recurrence) }
        }
    }

    // MARK: Checklist

    @Test func checklistItemTitles() throws {
        #expect(try InputValidation.checklistItemTitle("  Premier ") == "Premier")
        #expect(try InputValidation.checklistItemTitle(String(repeating: "é", count: 200)).unicodeScalars.count == 200)
        for invalid in ["", " \n ", String(repeating: "é", count: 201), "a\u{0}"] {
            #expect(throws: AppError.invalidChecklistItem) { try InputValidation.checklistItemTitle(invalid) }
        }
    }

    @Test func checklistChecksEveryTitleThenTheCount() throws {
        #expect(try InputValidation.checklist([]) == [])
        #expect(try InputValidation.checklist(["  Premier ", "Deuxième", "Troisième"]) == ["Premier", "Deuxième", "Troisième"])
        let thirty = Array(repeating: "x", count: 30)
        #expect(try InputValidation.checklist(thirty) == thirty)
        #expect(throws: AppError.tooManyChecklistItems) { try InputValidation.checklist(thirty + ["x"]) }
        #expect(throws: AppError.invalidChecklistItem) { try InputValidation.checklist(thirty + ["x", String(repeating: "y", count: 201)]) }
        #expect(throws: AppError.invalidChecklistItem) { try InputValidation.checklist(["Ok", "  "]) }
    }
}
