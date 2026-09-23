import Foundation

/// 8-character group invite code using an unambiguous alphabet (no 0/O/1/I).
/// Must stay in sync with `private.generate_invite_code()` and the `group_invites.code` check constraint.
public struct InviteCode: Sendable, Hashable, CustomStringConvertible {
    public static let alphabet: Set<Character> = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    public static let length = 8

    /// Normalized value, e.g. `ABCDEFGH`.
    public let value: String

    /// Accepts user input such as `abcd-efgh` or ` ABCD EFGH `. Returns nil if it cannot be a valid code.
    public init?(_ input: String) {
        let normalized = InviteCode.normalize(input)
        guard normalized.count == InviteCode.length,
              normalized.allSatisfy({ InviteCode.alphabet.contains($0) })
        else { return nil }
        value = normalized
    }

    /// Uppercases, then keeps only the Unicode scalars A–Z and 0–9 (same rule as the SQL `join_group_by_code`,
    /// which works per code point: "L\u{301}YLAS234" → "LYLAS234").
    public static func normalize(_ input: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in input.uppercased().unicodeScalars
        where ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Display form, e.g. `ABCD-EFGH`.
    public var formatted: String {
        let mid = value.index(value.startIndex, offsetBy: InviteCode.length / 2)
        return "\(value[..<mid])-\(value[mid...])"
    }

    public var description: String { formatted }
}
