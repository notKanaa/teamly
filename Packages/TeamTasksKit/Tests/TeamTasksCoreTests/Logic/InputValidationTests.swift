import Foundation
import Testing
@testable import TeamTasksCore

@Suite struct InputValidationTests {
    /// The pinned trim list (docs/CONTRACTS.md §1), the same on every platform.
    static let trimmed: [UInt32] = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680]
        + Array(UInt32(0x2000)...UInt32(0x200B)) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

    @Test func trimsExactlyThePinnedCodePoints() {
        var found: [UInt32] = []
        for value in UInt32(1)...0x3000 {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if InputValidation.trimmed("\(scalar)x\(scalar)") == "x" { found.append(value) }
        }
        #expect(found == Self.trimmed)
        for value: UInt32 in [0x1C, 0x1D, 0x1E, 0x1F, 0x180E, 0xFEFF] {
            let text = "\(Unicode.Scalar(value)!)x"
            #expect(InputValidation.trimmed(text) == text, "U+\(String(value, radix: 16)) is not trimmed")
        }
    }

    @Test func trimsCodePointsNotGraphemes() {
        // A combining accent after a space stays (like the SQL regexp, which works on code points).
        #expect(InputValidation.trimmed(" \u{301}x ") == "\u{301}x")
        #expect(InputValidation.trimmed("\u{3000}\u{200B} Titre \n\t") == "Titre")
        #expect(InputValidation.trimmed(" \n ") == "")
        #expect(InputValidation.trimmed("") == "")
    }

    @Test func textFieldLimitsCountUnicodeScalars() throws {
        #expect(try InputValidation.displayName("  Zoé  ") == "Zoé")
        #expect(try InputValidation.displayName(String(repeating: "é", count: 50)).count == 50)
        #expect(throws: AppError.invalidDisplayName) { try InputValidation.displayName(String(repeating: "é", count: 51)) }
        #expect(throws: AppError.invalidDisplayName) { try InputValidation.displayName(" \u{200B} ") }
        #expect(throws: AppError.invalidName) { try InputValidation.groupName(String(repeating: "x", count: 61)) }
        #expect(try InputValidation.groupName(String(repeating: "x", count: 60)).count == 60)
        #expect(throws: AppError.invalidTitle) { try InputValidation.taskTitle("") }
        #expect(throws: AppError.invalidTitle) { try InputValidation.taskTitle(String(repeating: "x", count: 201)) }
        #expect(try InputValidation.taskDetails("   ") == nil)
        #expect(try InputValidation.taskDetails(" d ") == "d")
        #expect(throws: AppError.invalidDetails) { try InputValidation.taskDetails(String(repeating: "x", count: 5001)) }
    }

    /// Postgres `text` cannot hold U+0000.
    @Test func nulIsRejectedWithTheFieldsError() {
        #expect(throws: AppError.invalidDisplayName) { try InputValidation.displayName("a\u{0}") }
        #expect(throws: AppError.invalidName) { try InputValidation.groupName("a\u{0}") }
        #expect(throws: AppError.invalidTitle) { try InputValidation.taskTitle("a\u{0}b") }
        #expect(throws: AppError.invalidDetails) { try InputValidation.taskDetails("\u{0}") }
    }

    @Test func passwordsAreMeasuredInUTF8Bytes() throws {
        try InputValidation.password("éééé") // 8 bytes
        try InputValidation.password("😀😀") // 8 bytes
        try InputValidation.password(String(repeating: "a", count: 72))
        #expect(throws: AppError.weakPassword) { try InputValidation.password("abc1234") }
        #expect(throws: AppError.weakPassword) { try InputValidation.password("ééé1") }
        #expect(throws: AppError.invalidInput) { try InputValidation.password(String(repeating: "a", count: 73)) }
    }

    @Test func emailsAreNormalizedAndCheckedLikeSupabaseAuth() throws {
        #expect(try InputValidation.email("  Zoe.Leroy@Example.COM ") == "zoe.leroy@example.com")
        #expect(InputValidation.normalizedEmail(" A@B.fr\n") == "a@b.fr")
        for valid in ["user@localhost", ".x@example.com", "a..b@example.com", "o'neil+tag@sub-domain.example.fr", "1@2.3"] {
            #expect(try InputValidation.email(valid) == valid.lowercased())
        }
        let label63 = String(repeating: "a", count: 63)
        #expect(try InputValidation.email("x@\(label63).fr") == "x@\(label63).fr")
        for invalid in [
            "", "x", "x@", "@x.fr", "x@@x.fr", "x@y@z.fr", "x y@z.fr", "ü@x.fr", "x@exämple.fr", "x@-x.fr", "x@x-.fr",
            "x@x..fr", "x@.x.fr", "x@x.fr.", "x@\(label63)a.fr", "x@x_y.fr", "\(String(repeating: "a", count: 251))@x.fr",
        ] {
            #expect(throws: AppError.invalidEmail, "\(invalid)") { try InputValidation.email(invalid) }
        }
    }

    @Test func signUpChecksEmailThenPasswordThenName() throws {
        #expect(throws: AppError.invalidEmail) { try InputValidation.signUp(email: "x", password: "court", displayName: "") }
        #expect(throws: AppError.weakPassword) { try InputValidation.signUp(email: "a@b.fr", password: "court", displayName: "") }
        #expect(throws: AppError.invalidDisplayName) { try InputValidation.signUp(email: "a@b.fr", password: "motdepasse", displayName: " ") }
        let input = try InputValidation.signUp(email: " A@B.fr ", password: "motdepasse", displayName: " Zoé ")
        #expect(input.email == "a@b.fr")
        #expect(input.displayName == "Zoé")
    }
}
