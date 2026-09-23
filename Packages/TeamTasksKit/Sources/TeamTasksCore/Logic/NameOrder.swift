import Foundation

/// Name order shared by every backend implementation (docs/CONTRACTS.md §4.3), so the mocks and the Supabase
/// adapters return `myGroups` and `members` in exactly the same order.
public enum NameOrder {
    /// Case- and diacritic-insensitive key (fr_FR folding).
    public static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    /// Folded order first, then exact order; nil when both names are identical.
    public static func precedes(_ lhs: String, _ rhs: String) -> Bool? {
        let left = key(lhs)
        let right = key(rhs)
        if left != right { return left < right }
        if lhs != rhs { return lhs < rhs }
        return nil
    }

    /// `myGroups`: most recently active first, then name, then id.
    public static func sortedGroups(_ groups: [GroupSummary]) -> [GroupSummary] {
        groups.sorted { lhs, rhs in
            if lhs.group.lastActivityAt != rhs.group.lastActivityAt {
                return lhs.group.lastActivityAt > rhs.group.lastActivityAt
            }
            if let order = precedes(lhs.group.name, rhs.group.name) { return order }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// `members`: admins first, then display name, then user id.
    public static func sortedMembers(_ members: [Membership]) -> [Membership] {
        members.sorted { lhs, rhs in
            if lhs.role != rhs.role { return lhs.role == .admin }
            if let order = precedes(lhs.user.displayName, rhs.user.displayName) { return order }
            return lhs.user.id.uuidString < rhs.user.id.uuidString
        }
    }
}
