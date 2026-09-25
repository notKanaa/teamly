import type { Instant } from './calendar';
import { type ColorKey, resolvedColor } from './colorKey';
import { compareUuids, type Uuid } from './uuid';

// Models of TeamTasksCore (Swift), as plain immutable objects. Timestamps are `Instant`s (epoch milliseconds), ids are
// lowercase UUID strings, and the enum values are the stored texts of the database.

// MARK: - Users

/** Authenticated account (Supabase Auth). */
export interface AuthUser {
  id: Uuid;
  email: string | null;
}

/** Public profile visible to co-members (`public.profiles`). */
export interface UserProfile {
  id: Uuid;
  displayName: string;
  /** v2: null = automatic (`resolvedColor`). */
  avatarColor: ColorKey | null;
  /** v2: null = the initials. */
  avatarEmoji: string | null;
  /** v2: only read by `myProfile` (null in the members list). */
  onboardedAt: Instant | null;
  /** v2: only read by `myProfile` (null in the members list). */
  createdAt: Instant | null;
}

export function makeProfile(fields: Pick<UserProfile, 'id' | 'displayName'> & Partial<UserProfile>): UserProfile {
  return {
    avatarColor: null,
    avatarEmoji: null,
    onboardedAt: null,
    createdAt: null,
    ...fields,
  };
}

export function profileColor(profile: UserProfile): ColorKey {
  return resolvedColor(profile.avatarColor, profile.id);
}

// MARK: - Groups

export const MEMBER_ROLES = ['admin', 'member'] as const;
export type MemberRole = (typeof MEMBER_ROLES)[number];

/** A group of people sharing tasks (`public.groups`). */
export interface TeamGroup {
  id: Uuid;
  name: string;
  createdBy: Uuid | null;
  createdAt: Instant;
  lastActivityAt: Instant;
  /** v2: null = automatic. */
  color: ColorKey | null;
  /** v2: null = none (the initials are shown). */
  emoji: string | null;
}

export function groupColor(group: TeamGroup): ColorKey {
  return resolvedColor(group.color, group.id);
}

/** A group as seen by the current user, with their role in it. */
export interface GroupSummary {
  group: TeamGroup;
  myRole: MemberRole;
}

/** A member of a group (`public.group_members` joined with `public.profiles`). */
export interface Membership {
  groupId: Uuid;
  user: UserProfile;
  role: MemberRole;
  joinedAt: Instant;
}

/** Result of joining a group with an invite code (an invalid code is an `invalidCode` error). */
export interface JoinResult {
  groupId: Uuid;
  groupName: string;
  alreadyMember: boolean;
}

// MARK: - Tasks

export const TASK_STATUSES = ['todo', 'in_progress', 'done'] as const;
export type TaskStatus = (typeof TASK_STATUSES)[number];

export const TASK_PRIORITIES = ['low', 'medium', 'high'] as const;
export type TaskPriority = (typeof TASK_PRIORITIES)[number];

export function priorityRank(priority: TaskPriority): number {
  switch (priority) {
    case 'low':
      return 0;
    case 'medium':
      return 1;
    case 'high':
      return 2;
  }
}

export const FREQUENCIES = ['daily', 'weekly', 'monthly'] as const;
export type Frequency = (typeof FREQUENCIES)[number];

/**
 * How a recurring task repeats (docs/CONTRACTS-V2.md §5, §6). On the wire a rule is `{freq, interval, weekdays, tz}`;
 * `monthDay` is set by the server and never sent.
 */
export interface RecurrenceRule {
  frequency: Frequency;
  /** Every `interval` days, weeks or months: 1…52. */
  interval: number;
  /** Weekly rules only: ISO weekdays (1 = Monday … 7 = Sunday), ascending and distinct; null = the due date's weekday. */
  weekdays: readonly number[] | null;
  /** IANA zone in which the occurrences keep their local time of day, exact case. */
  timeZoneId: string;
  /** Monthly rules: the day of month of the series, stored by the server; null = the local day of the due date. */
  monthDay: number | null;
}

/** A rule with its weekdays normalized (distinct, ascending), like Swift's `Set<Int>`. */
export function makeRule(
  fields: Pick<RecurrenceRule, 'frequency' | 'timeZoneId'> & {
    interval?: number;
    weekdays?: Iterable<number> | null;
    monthDay?: number | null;
  },
): RecurrenceRule {
  return {
    frequency: fields.frequency,
    interval: fields.interval ?? 1,
    weekdays: fields.weekdays == null ? null : Array.from(new Set(fields.weekdays)).sort((a, b) => a - b),
    timeZoneId: fields.timeZoneId,
    monthDay: fields.monthDay ?? null,
  };
}

/** One item of a task's checklist (`public.task_checklist_items`). */
export interface ChecklistItem {
  id: Uuid;
  title: string;
  /** 1-based and unique within the task; gaps are allowed. */
  position: number;
  isDone: boolean;
  doneAt: Instant | null;
  doneBy: Uuid | null;
}

/** Display order of a checklist: `position`, then id. */
export function sortedChecklist(items: readonly ChecklistItem[]): ChecklistItem[] {
  return [...items].sort((lhs, rhs) =>
    lhs.position !== rhs.position ? lhs.position - rhs.position : compareUuids(lhs.id, rhs.id),
  );
}

/** A task of a group (`public.tasks` + its assignees and checklist). */
export interface TaskItem {
  id: Uuid;
  groupId: Uuid;
  title: string;
  details: string | null;
  status: TaskStatus;
  priority: TaskPriority;
  dueAt: Instant | null;
  createdBy: Uuid | null;
  createdAt: Instant;
  updatedAt: Instant;
  completedAt: Instant | null;
  /** Sorted user ids of the assignees. */
  assigneeIds: Uuid[];
  /** Only filled by the « Mes tâches » reads: when the current user was assigned (« Nouveau »). */
  myAssignedAt: Instant | null;
  /** Only filled by the « Mes tâches » reads: who assigned the current user. */
  myAssignedBy: Uuid | null;
  /** Only filled by the « Mes tâches » reads. */
  groupName: string | null;
  /** v2: the repetition rule; null = a plain task. */
  recurrence: RecurrenceRule | null;
  /** v2: « À tour de rôle », in turn order; empty = no rotation. */
  rotation: Uuid[];
  /** v2: whose turn this occurrence is. */
  turnUserId: Uuid | null;
  seriesId: Uuid | null;
  nextOccurrenceId: Uuid | null;
  /** v2: who completed the task. */
  completedBy: Uuid | null;
  /** v2: the checklist, in display order. */
  checklist: ChecklistItem[];
  /** v2, « Mes tâches » reads only: the group's color (null = automatic). */
  groupColor: ColorKey | null;
  /** v2, « Mes tâches » reads only: the group's emoji. */
  groupEmoji: string | null;
}

export function makeTask(
  fields: Pick<TaskItem, 'id' | 'groupId' | 'title' | 'createdBy' | 'createdAt' | 'updatedAt'> & Partial<TaskItem>,
): TaskItem {
  return {
    details: null,
    status: 'todo',
    priority: 'medium',
    dueAt: null,
    completedAt: null,
    assigneeIds: [],
    myAssignedAt: null,
    myAssignedBy: null,
    groupName: null,
    recurrence: null,
    rotation: [],
    turnUserId: null,
    seriesId: null,
    nextOccurrenceId: null,
    completedBy: null,
    checklist: [],
    groupColor: null,
    groupEmoji: null,
    ...fields,
  };
}

export function isRecurring(task: TaskItem): boolean {
  return task.recurrence !== null;
}

export function hasRotation(task: TaskItem): boolean {
  return task.rotation.length > 0;
}

export function isAssigned(task: TaskItem, userId: Uuid): boolean {
  return task.assigneeIds.includes(userId);
}

/** True when the task is not done and its due date is strictly before `now`. */
export function isOverdue(task: TaskItem, now: Instant): boolean {
  return task.status !== 'done' && task.dueAt !== null && task.dueAt < now;
}

/** Editable fields of a task (create / full edit). An update is a full edit of the recurrence and the rotation too. */
export interface TaskDraft {
  title: string;
  details: string;
  priority: TaskPriority;
  dueAt: Instant | null;
  assigneeIds: Uuid[];
  recurrence: RecurrenceRule | null;
  rotation: Uuid[];
  /** Create only: the titles of the initial checklist items. */
  checklist: string[];
}

export function makeDraft(fields: Partial<TaskDraft> = {}): TaskDraft {
  return {
    title: '',
    details: '',
    priority: 'medium',
    dueAt: null,
    assigneeIds: [],
    recurrence: null,
    rotation: [],
    checklist: [],
    ...fields,
  };
}

/** The draft of a full edit of `task`: its fields, assignees, recurrence and rotation (the checklist stays empty). */
export function draftFromTask(task: TaskItem): TaskDraft {
  return makeDraft({
    title: task.title,
    details: task.details ?? '',
    priority: task.priority,
    dueAt: task.dueAt,
    assigneeIds: [...task.assigneeIds],
    recurrence: task.recurrence,
    rotation: [...task.rotation],
  });
}

/** « A task was assigned to me » (notifications and catch-up). */
export interface AssignmentEvent {
  taskId: Uuid;
  groupId: Uuid;
  taskTitle: string;
  groupName: string;
  assignedBy: Uuid | null;
  assignedAt: Instant;
  dueAt: Instant | null;
  taskHasRotation: boolean;
}

/** A turn handed out by the server: `assignedBy` null on a task with a rotation (« C’est ton tour »). */
export function isRotationTurn(event: AssignmentEvent): boolean {
  return event.assignedBy === null && event.taskHasRotation;
}

// MARK: - Activity (v2)

export const ACTIVITY_KINDS = [
  'task_created',
  'task_completed',
  'turn_started',
  'checklist_item_done',
  'member_joined',
  'member_left',
] as const;
export type ActivityKind = (typeof ACTIVITY_KINDS)[number];

/** One event of a group's activity feed (`public.group_activity`). */
export interface ActivityEvent {
  id: number;
  kind: ActivityKind;
  actorId: Uuid | null;
  subjectId: Uuid | null;
  taskId: Uuid | null;
  taskTitle: string | null;
  itemTitle: string | null;
  createdAt: Instant;
}

/** A done task of a group, as read for the weekly recap. */
export interface TaskCompletion {
  taskId: Uuid;
  completedBy: Uuid | null;
  completedAt: Instant;
}

// MARK: - Auth and realtime

export type AuthState = { kind: 'unknown' } | { kind: 'signedOut' } | { kind: 'signedIn'; user: AuthUser };

export type SignUpOutcome = 'signedIn' | 'confirmationRequired';

export type RealtimeEvent =
  | { kind: 'connected' }
  | { kind: 'groupActivity'; groupId: Uuid }
  | { kind: 'membershipsChanged' }
  | { kind: 'assigned'; taskId: Uuid; groupId: Uuid; assignedBy: Uuid | null };

/** Enum-like guards used by the row decoders. */
export function isOneOf<T extends string>(values: readonly T[], value: unknown): value is T {
  return typeof value === 'string' && (values as readonly string[]).includes(value);
}
