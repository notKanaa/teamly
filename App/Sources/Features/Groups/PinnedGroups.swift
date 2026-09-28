import Foundation
import TeamTasksCore

/// The groups pinned at the top of the « Groupes » list (swipe right on a card, or its long-press menu): stored on this
/// device, per user, in the platform's `KeyValueStore`. The pinned groups come first, the most recently pinned first;
/// the others keep the list's order (most recently active first).
struct PinnedGroups {
    let store: any KeyValueStore
    let userId: UUID

    init(store: any KeyValueStore, userId: UUID) {
        self.store = store
        self.userId = userId
    }

    private var key: String { "groups.pinned.\(userId.uuidString)" }

    /// The pinned groups, the most recently pinned first.
    func load() -> [UUID] {
        store.value([UUID].self, forKey: key) ?? []
    }

    /// Pins or unpins `groupId`; returns the new list.
    @discardableResult
    func setPinned(_ isPinned: Bool, groupId: UUID) -> [UUID] {
        var ids = load().filter { $0 != groupId }
        if isPinned {
            ids.insert(groupId, at: 0)
        }
        store.setValue(ids, forKey: key)
        return ids
    }

    /// `groups` with the pinned ones first (in `pinned` order), then the others in their order.
    static func sorted(_ groups: [GroupSummary], pinned: [UUID]) -> [GroupSummary] {
        let rank = Dictionary(pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let pinnedGroups = groups.filter { rank[$0.id] != nil }.sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
        return pinnedGroups + groups.filter { rank[$0.id] == nil }
    }
}
