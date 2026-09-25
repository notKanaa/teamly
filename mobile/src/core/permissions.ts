import type { MemberRole, TaskItem } from './models';
import type { Uuid } from './uuid';

// Client-side mirror of the server permission matrix (docs/CONTRACTS.md §2, docs/CONTRACTS-V2.md §4). The server
// (RLS + triggers) is the source of truth; this only drives what the UI offers. `role` is the current user's role in
// the task's group; null means « not a member » (no rights).

export function canViewTasks(role: MemberRole | null): boolean {
  return role !== null;
}

export function canCreateTask(role: MemberRole | null): boolean {
  return role !== null;
}

/** Edit title, details, priority, due date, assignees (v2: recurrence and rotation too): admin or creator. */
export function canEditTask(task: TaskItem, userId: Uuid, role: MemberRole | null): boolean {
  if (role === null) return false;
  return role === 'admin' || task.createdBy === userId;
}

/** Change the status (v2: manage the checklist too): admin, creator or assignee. */
export function canChangeTaskStatus(task: TaskItem, userId: Uuid, role: MemberRole | null): boolean {
  if (role === null) return false;
  return canEditTask(task, userId, role) || task.assigneeIds.includes(userId);
}

export function canDeleteTask(task: TaskItem, userId: Uuid, role: MemberRole | null): boolean {
  return canEditTask(task, userId, role);
}

export function canEditRecurrence(task: TaskItem, userId: Uuid, role: MemberRole | null): boolean {
  return canEditTask(task, userId, role);
}

export function canManageChecklist(task: TaskItem, userId: Uuid, role: MemberRole | null): boolean {
  return canChangeTaskStatus(task, userId, role);
}

export const GroupPermissions = {
  canRename: (role: MemberRole | null) => role === 'admin',
  canDelete: (role: MemberRole | null) => role === 'admin',
  canSeeInviteCode: (role: MemberRole | null) => role === 'admin',
  canManageMembers: (role: MemberRole | null) => role === 'admin',
  canLeave: (role: MemberRole | null) => role !== null,
  /** v2: set the group's color and emoji. */
  canSetAppearance: (role: MemberRole | null) => role === 'admin',
  /** v2: read the activity feed and the weekly recap. */
  canSeeActivity: (role: MemberRole | null) => role !== null,
} as const;
