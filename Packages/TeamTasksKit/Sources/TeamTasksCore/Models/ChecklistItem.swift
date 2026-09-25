import Foundation

/// One item of a task's checklist (`public.task_checklist_items`, docs/CONTRACTS-V2.md §2, §5).
///
/// Items are edited one by one with the checklist operations of `TaskService`, with the rights of « change status »
/// (`TaskPermissions.canManageChecklist`). A new occurrence of a recurring task copies them, unchecked.
public struct ChecklistItem: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Trimmed, 1–`Limits.checklistItemTitleMax` code points.
    public var title: String
    /// 1-based and unique within the task; gaps are allowed (deleted items keep the others' positions).
    public var position: Int
    public var isDone: Bool
    /// When the item was checked; nil unless `isDone`.
    public var doneAt: Date?
    /// Who checked the item; nil unless `isDone`, or when that account was deleted.
    public var doneBy: UUID?

    public init(
        id: UUID,
        title: String,
        position: Int,
        isDone: Bool = false,
        doneAt: Date? = nil,
        doneBy: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.position = position
        self.isDone = isDone
        self.doneAt = doneAt
        self.doneBy = doneBy
    }

    /// Display order of a checklist: `position`, then `id.uuidString` (reads return the items unordered).
    public static func sorted(_ items: [ChecklistItem]) -> [ChecklistItem] {
        items.sorted { lhs, rhs in
            lhs.position != rhs.position ? lhs.position < rhs.position : lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
