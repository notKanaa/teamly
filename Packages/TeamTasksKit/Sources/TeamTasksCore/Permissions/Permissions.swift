import Foundation

/// Client-side mirror of the server permission matrix (docs/CONTRACTS.md § Permissions).
/// The server (RLS + triggers) is the source of truth; this only drives what the UI offers.
/// `role` is the current user's role in the task's group; nil means "not a member" (no rights).
public enum TaskPermissions {
    public static func canView(role: MemberRole?) -> Bool { role != nil }

    public static func canCreate(role: MemberRole?) -> Bool { role != nil }

    /// Edit title, details, priority, due date and assignees.
    public static func canEdit(_ task: TaskItem, userId: UUID, role: MemberRole?) -> Bool {
        guard let role else { return false }
        return role == .admin || task.createdBy == userId
    }

    public static func canChangeStatus(_ task: TaskItem, userId: UUID, role: MemberRole?) -> Bool {
        guard role != nil else { return false }
        return canEdit(task, userId: userId, role: role) || task.assigneeIds.contains(userId)
    }

    public static func canDelete(_ task: TaskItem, userId: UUID, role: MemberRole?) -> Bool {
        canEdit(task, userId: userId, role: role)
    }
}

public enum GroupPermissions {
    public static func canRename(role: MemberRole?) -> Bool { role == .admin }
    public static func canDelete(role: MemberRole?) -> Bool { role == .admin }
    public static func canSeeInviteCode(role: MemberRole?) -> Bool { role == .admin }
    public static func canManageMembers(role: MemberRole?) -> Bool { role == .admin }
    public static func canLeave(role: MemberRole?) -> Bool { role != nil }
}
