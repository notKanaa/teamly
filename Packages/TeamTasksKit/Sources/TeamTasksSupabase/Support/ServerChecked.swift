import Foundation

/// Text the adapters send unchecked, for the server to check at its turn: after checks the client cannot make (the
/// group or task exists, the caller's rights, the members of a rotation, the assignees), so that the first error is the
/// server's (docs/CONTRACTS-V2.md §3). This covers the emoji of `set_group_appearance`, the title of the checklist
/// RPCs and the checklist of `create_task`.
///
/// Postgres cannot receive U+0000: a request holding it fails as a whole with `22P05` (`.invalidInput`) before any
/// check. Such a value is invalid anyway, so it is replaced by another invalid value, which the server refuses with the
/// field's own error at the same point of its order.
enum ServerChecked {
    /// A checklist item title: the empty title stands for one holding U+0000 (`invalid_item_title`).
    static func title(_ raw: String) -> String {
        holdsNul(raw) ? "" : raw
    }

    /// A group emoji: U+0001, a C0 control, stands for one holding U+0000 (`invalid_emoji`). An empty text would not
    /// do: the server reads a blank emoji as « no emoji ».
    static func emoji(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return holdsNul(raw) ? "\u{1}" : raw
    }

    private static func holdsNul(_ value: String) -> Bool {
        value.unicodeScalars.contains("\u{0}")
    }
}
