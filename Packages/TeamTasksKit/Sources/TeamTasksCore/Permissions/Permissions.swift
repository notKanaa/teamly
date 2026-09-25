import Foundation

/// Client-side mirror of the server permission matrix (docs/CONTRACTS.md § Permissions, docs/CONTRACTS-V2.md §4).
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

    /// v2: change the recurrence or the rotation, which are task fields: the rights of `canEdit` (admin or creator).
    public static func canEditRecurrence(_ task: TaskItem, userId: UUID, role: MemberRole?) -> Bool {
        canEdit(task, userId: userId, role: role)
    }

    /// v2: add, rename, delete, check or uncheck checklist items: the rights of `canChangeStatus` (admin, creator or
    /// assignee).
    public static func canManageChecklist(_ task: TaskItem, userId: UUID, role: MemberRole?) -> Bool {
        canChangeStatus(task, userId: userId, role: role)
    }
}

public enum GroupPermissions {
    public static func canRename(role: MemberRole?) -> Bool { role == .admin }
    public static func canDelete(role: MemberRole?) -> Bool { role == .admin }
    public static func canSeeInviteCode(role: MemberRole?) -> Bool { role == .admin }
    public static func canManageMembers(role: MemberRole?) -> Bool { role == .admin }
    public static func canLeave(role: MemberRole?) -> Bool { role != nil }
    /// v2: set the group's color and emoji: admins only.
    public static func canSetAppearance(role: MemberRole?) -> Bool { role == .admin }
    /// v2: read the activity feed and the weekly recap: every member.
    public static func canSeeActivity(role: MemberRole?) -> Bool { role != nil }
}
