import TeamTasksCore

/// The « n/60 » counter of « Nouveau groupe », measured like the validation (docs/CONTRACTS.md §1): code points of
/// the trimmed name. `String.count` (grapheme clusters of the raw text) would call « 👍🏽 » × 31 valid (31/60 for 62
/// code points) and a name followed by spaces too long.
enum CreateGroupNameCounter {
    static let maxLength = Limits.groupName.upperBound

    static func length(of name: String) -> Int {
        InputValidation.length(InputValidation.trimmed(name))
    }

    static func isTooLong(_ name: String) -> Bool {
        length(of: name) > maxLength
    }
}
