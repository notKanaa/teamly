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

    // MARK: v3 (docs/CONTRACTS-V3.md)

    /// v3 « Relancer » (§1): any member, on a task not done that has at least one assignee other than the user.
    public static func canNudge(_ task: TaskItem, userId: UUID, role: MemberRole?) -> Bool {
        role != nil && task.status != .done && task.assigneeIds.contains { $0 != userId }
    }

    /// v3 « Échanger mon tour » (§3): the user holds the turn of a pending rotating occurrence. The candidates are
    /// `turnSwapCandidates(_:userId:memberIds:)`.
    public static func canRequestTurnSwap(_ task: TaskItem, userId: UUID, role: MemberRole?) -> Bool {
        role != nil && task.status != .done && task.hasRotation && task.turnUserId == userId
    }

    /// v3: who may take the user's turn: the current members listed in the rotation, the user excepted, in turn order.
    public static func turnSwapCandidates(_ task: TaskItem, userId: UUID, memberIds: Set<UUID>) -> [UUID] {
        task.rotation.filter { $0 != userId && memberIds.contains($0) }
    }

    /// v3: accept or decline a swap: only the member it was proposed to, while it is pending.
    public static func canRespond(to swap: TurnSwap, userId: UUID) -> Bool {
        swap.isPending && swap.toUserId == userId
    }

    /// v3: withdraw a swap: only its author, while it is pending.
    public static func canCancel(_ swap: TurnSwap, userId: UUID) -> Bool {
        swap.isPending && swap.fromUserId == userId
    }

    /// v3 comments (§5): every member may comment.
    public static func canComment(role: MemberRole?) -> Bool { role != nil }

    /// v3: delete a comment: its author (still a member) or an admin of the group.
    public static func canDelete(_ comment: TaskComment, userId: UUID, role: MemberRole?) -> Bool {
        guard let role else { return false }
        return role == .admin || comment.authorId == userId
    }

    /// v3 photos (§6): add one with the rights of « change status » (admin, creator or assignee), up to
    /// `Limits.photosPerTaskMax` photos.
    public static func canAddPhoto(_ task: TaskItem, userId: UUID, role: MemberRole?) -> Bool {
        canChangeStatus(task, userId: userId, role: role) && task.photos.count < Limits.photosPerTaskMax
    }

    /// v3: delete a photo: its uploader (still a member) or an admin of the group.
    public static func canDelete(_ photo: TaskPhoto, userId: UUID, role: MemberRole?) -> Bool {
        guard let role else { return false }
        return role == .admin || photo.uploadedBy == userId
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
    /// v3 « Bravo » (docs/CONTRACTS-V3.md §4): every member may react to the events of the feed.
    public static func canReact(role: MemberRole?) -> Bool { role != nil }
}
