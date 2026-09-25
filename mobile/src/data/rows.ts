import { AppError } from '@/core/appError';
import type { Instant } from '@/core/calendar';
import { type ColorKey, storedColor } from '@/core/colorKey';
import {
  ACTIVITY_KINDS,
  type ActivityEvent,
  type AssignmentEvent,
  type ChecklistItem,
  FREQUENCIES,
  type GroupSummary,
  isOneOf,
  type JoinResult,
  MEMBER_ROLES,
  type Membership,
  type RecurrenceRule,
  makeRule,
  sortedChecklist,
  TASK_PRIORITIES,
  TASK_STATUSES,
  type TaskCompletion,
  type TaskItem,
  type TaskStatus,
  type TeamGroup,
  type UserProfile,
} from '@/core/models';
import { compareUuids, sortedUniqueUuids, type Uuid } from '@/core/uuid';

import { UNEXPECTED_ANSWER } from './errors';
import { parseTimestamp } from './postgresTimestamp';

// JSON rows returned by PostgREST (docs/CONTRACTS.md §4, docs/CONTRACTS-V2.md §5–§10; Swift `Rows.swift`). Column
// names are the SQL ones; embedded resources use the aliases of the `select` parameters.
//
// Forward compatibility (docs/CONTRACTS.md §9): an enum value added by a later version (a status, a priority, a role, a
// repetition frequency, an activity kind) makes its row unknown: a list read leaves the row out instead of failing the
// whole list, a single-row read fails. An unknown color reads as null (the automatic color).

/** A row holding an enum value this client does not know. */
export class UnknownEnumValue extends Error {
  constructor(field: string, value: string) {
    super(`Unknown ${field}: ${value}`);
    this.name = 'UnknownEnumValue';
  }
}

/** A malformed row (a missing field, a wrong type). */
class MalformedRow extends Error {
  constructor(what: string) {
    super(`Malformed row: ${what}`);
    this.name = 'MalformedRow';
  }
}

type Json = Record<string, unknown>;

function object(value: unknown, what: string): Json {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new MalformedRow(what);
  return value as Json;
}

function string(row: Json, key: string): string {
  const value = row[key];
  if (typeof value !== 'string') throw new MalformedRow(key);
  return value;
}

function optionalString(row: Json, key: string): string | null {
  const value = row[key];
  if (value === null || value === undefined) return null;
  if (typeof value !== 'string') throw new MalformedRow(key);
  return value;
}

function uuid(row: Json, key: string): Uuid {
  return string(row, key).toLowerCase();
}

function optionalUuid(row: Json, key: string): Uuid | null {
  return optionalString(row, key)?.toLowerCase() ?? null;
}

function timestamp(row: Json, key: string): Instant {
  const value = parseTimestamp(string(row, key));
  if (value === null) throw new MalformedRow(key);
  return value;
}

function optionalTimestamp(row: Json, key: string): Instant | null {
  const text = optionalString(row, key);
  if (text === null) return null;
  const value = parseTimestamp(text);
  if (value === null) throw new MalformedRow(key);
  return value;
}

function integer(row: Json, key: string): number {
  const value = row[key];
  if (typeof value !== 'number' || !Number.isInteger(value)) throw new MalformedRow(key);
  return value;
}

function optionalInteger(row: Json, key: string): number | null {
  const value = row[key];
  if (value === null || value === undefined) return null;
  if (typeof value !== 'number' || !Number.isInteger(value)) throw new MalformedRow(key);
  return value;
}

function boolean(row: Json, key: string): boolean {
  const value = row[key];
  if (typeof value !== 'boolean') throw new MalformedRow(key);
  return value;
}

function known<T extends string>(values: readonly T[], row: Json, key: string): T {
  const value = string(row, key);
  if (!isOneOf(values, value)) throw new UnknownEnumValue(key, value);
  return value;
}

function optionalArray(row: Json, key: string): unknown[] | null {
  const value = row[key];
  if (value === null || value === undefined) return null;
  if (!Array.isArray(value)) throw new MalformedRow(key);
  return value;
}

function color(row: Json, key: string): ColorKey | null {
  return storedColor(optionalString(row, key));
}

// MARK: - Decoding entry points

/** One row (an RPC result, a single-row read): any problem is an unexpected answer. */
export function decodeOne<Row>(value: unknown, decode: (row: Json) => Row): Row {
  try {
    return decode(object(value, 'row'));
  } catch {
    throw AppError.unknown(UNEXPECTED_ANSWER);
  }
}

/** A list read: rows with an unknown enum value are left out; any other problem fails the whole list. */
export function decodeRows<Row>(value: unknown, decode: (row: Json) => Row): Row[] {
  if (!Array.isArray(value)) throw AppError.unknown(UNEXPECTED_ANSWER);
  const rows: Row[] = [];
  for (const entry of value) {
    try {
      rows.push(decode(object(entry, 'row')));
    } catch (error) {
      if (error instanceof UnknownEnumValue || (error as Error | null)?.name === 'UnknownEnumValue') continue;
      throw AppError.unknown(UNEXPECTED_ANSWER);
    }
  }
  return rows;
}

// MARK: - Rows

/** `public.groups` row (`create_group`, `rename_group`, `set_group_appearance`, embedded `group:groups(*)`). */
export function decodeGroup(row: Json): TeamGroup {
  return {
    id: uuid(row, 'id'),
    name: string(row, 'name'),
    createdBy: optionalUuid(row, 'created_by'),
    createdAt: timestamp(row, 'created_at'),
    lastActivityAt: timestamp(row, 'last_activity_at'),
    color: color(row, 'color'),
    emoji: optionalString(row, 'emoji'),
  };
}

/** `group_members?select=role,group:groups(*)`. */
export function decodeMyGroup(row: Json): GroupSummary {
  const myRole = known(MEMBER_ROLES, row, 'role');
  return { group: decodeGroup(object(row.group, 'group')), myRole };
}

/** `profiles?select=id,display_name,avatar_color,avatar_emoji[,onboarded_at,created_at]` (absent keys read as null). */
export function decodeProfile(row: Json): UserProfile {
  return {
    id: uuid(row, 'id'),
    displayName: string(row, 'display_name'),
    avatarColor: color(row, 'avatar_color'),
    avatarEmoji: optionalString(row, 'avatar_emoji'),
    onboardedAt: optionalTimestamp(row, 'onboarded_at'),
    createdAt: optionalTimestamp(row, 'created_at'),
  };
}

/** `group_members?select=[group_id,]user_id,role,joined_at,profile:profiles(…)`. */
export function decodeMember(row: Json, groupId?: Uuid): Membership {
  const role = known(MEMBER_ROLES, row, 'role');
  const userId = uuid(row, 'user_id');
  const profile = row.profile === null || row.profile === undefined ? null : object(row.profile, 'profile');
  return {
    groupId: groupId ?? uuid(row, 'group_id'),
    user: {
      id: userId,
      displayName: profile === null ? '' : string(profile, 'display_name'),
      avatarColor: profile === null ? null : color(profile, 'avatar_color'),
      avatarEmoji: profile === null ? null : optionalString(profile, 'avatar_emoji'),
      onboardedAt: null,
      createdAt: null,
    },
    role,
    joinedAt: timestamp(row, 'joined_at'),
  };
}

/** `join_group_by_code` result: `{status, group_id, group_name}`; `invalid_code` is returned (not raised). */
export function decodeJoinResult(value: unknown): JoinResult {
  const row = decodeOne(value, (json) => json);
  switch (row.status) {
    case 'joined':
    case 'already_member': {
      const groupId = typeof row.group_id === 'string' ? row.group_id.toLowerCase() : null;
      const groupName = typeof row.group_name === 'string' ? row.group_name : null;
      if (groupId === null || groupName === null) throw AppError.unknown(UNEXPECTED_ANSWER);
      return { groupId, groupName, alreadyMember: row.status === 'already_member' };
    }
    case 'invalid_code':
      throw new AppError('invalidCode');
    default:
      throw AppError.unknown(UNEXPECTED_ANSWER);
  }
}

/** `task_checklist_items` row (embedded or returned by the checklist RPCs). */
export function decodeChecklistItem(row: Json): ChecklistItem {
  return {
    id: uuid(row, 'id'),
    title: string(row, 'title'),
    position: integer(row, 'position'),
    isDone: boolean(row, 'done'),
    doneAt: optionalTimestamp(row, 'done_at'),
    doneBy: optionalUuid(row, 'done_by'),
  };
}

/** The rule of the `repeat_*` columns; null when `repeat_freq` is NULL (or absent: a v1 server). */
function decodeRecurrence(row: Json): RecurrenceRule | null {
  if (row.repeat_freq === null || row.repeat_freq === undefined) return null;
  const frequency = known(FREQUENCIES, row, 'repeat_freq');
  const timeZoneId = optionalString(row, 'repeat_tz');
  if (timeZoneId === null) throw new MalformedRow('repeat_freq without repeat_tz');
  const weekdays = optionalArray(row, 'repeat_weekdays');
  return makeRule({
    frequency,
    interval: optionalInteger(row, 'repeat_interval') ?? 1,
    weekdays: weekdays === null ? null : weekdays.map((day) => {
      if (typeof day !== 'number') throw new MalformedRow('repeat_weekdays');
      return day;
    }),
    timeZoneId,
    monthDay: optionalInteger(row, 'repeat_month_day'),
  });
}

function uuidList(value: unknown[] | null, what: string): Uuid[] {
  return (value ?? []).map((entry) => {
    if (typeof entry !== 'string') throw new MalformedRow(what);
    return entry.toLowerCase();
  });
}

/**
 * `public.tasks` row, bare (RPC results) or with the embedded `assignees` and `checklist` of the task reads.
 * `assigneeIds` / `checklist` default to the embedded ones; assignees are sorted, the checklist in display order.
 */
export function decodeTask(row: Json, overrides: { assigneeIds?: Uuid[]; checklist?: ChecklistItem[] } = {}): TaskItem {
  const status = known(TASK_STATUSES, row, 'status');
  const priority = known(TASK_PRIORITIES, row, 'priority');
  const recurrence = decodeRecurrence(row);
  const embeddedAssignees = (optionalArray(row, 'assignees') ?? []).map((entry) => uuid(object(entry, 'assignee'), 'user_id'));
  const embeddedChecklist = (optionalArray(row, 'checklist') ?? []).map((entry) => decodeChecklistItem(object(entry, 'item')));
  return {
    id: uuid(row, 'id'),
    groupId: uuid(row, 'group_id'),
    title: string(row, 'title'),
    details: optionalString(row, 'details'),
    status,
    priority,
    dueAt: optionalTimestamp(row, 'due_at'),
    createdBy: optionalUuid(row, 'created_by'),
    createdAt: timestamp(row, 'created_at'),
    updatedAt: timestamp(row, 'updated_at'),
    completedAt: optionalTimestamp(row, 'completed_at'),
    assigneeIds: sortedUniqueUuids(overrides.assigneeIds ?? embeddedAssignees),
    myAssignedAt: null,
    myAssignedBy: null,
    groupName: null,
    recurrence,
    rotation: uuidList(optionalArray(row, 'rotation'), 'rotation'),
    turnUserId: optionalUuid(row, 'turn_user_id'),
    seriesId: optionalUuid(row, 'series_id'),
    nextOccurrenceId: optionalUuid(row, 'next_occurrence_id'),
    completedBy: optionalUuid(row, 'completed_by'),
    checklist: sortedChecklist(overrides.checklist ?? embeddedChecklist),
    groupColor: null,
    groupEmoji: null,
  };
}

/** A « Mes tâches » row: also `mine:task_assignees!inner(…)` and `group:groups(name,color,emoji)`. */
export function decodeMyTask(row: Json): TaskItem {
  const task = decodeTask(row);
  const mine = optionalArray(row, 'mine')?.[0];
  const mineRow = mine === undefined ? null : object(mine, 'mine');
  const group = row.group === null || row.group === undefined ? null : object(row.group, 'group');
  return {
    ...task,
    myAssignedAt: mineRow === null ? null : timestamp(mineRow, 'assigned_at'),
    myAssignedBy: mineRow === null ? null : optionalUuid(mineRow, 'assigned_by'),
    groupName: group === null ? null : string(group, 'name'),
    groupColor: group === null ? null : color(group, 'color'),
    groupEmoji: group === null ? null : optionalString(group, 'emoji'),
  };
}

/** Deterministic order of task lists (the server order is unspecified; screens sort with `sortTasks`). */
export function creationOrder(lhs: TaskItem, rhs: TaskItem): number {
  if (lhs.createdAt !== rhs.createdAt) return lhs.createdAt - rhs.createdAt;
  return compareUuids(lhs.id, rhs.id);
}

/** `task_assignees?select=task_id,group_id,assigned_by,assigned_at,task:tasks(title,due_at,rotation,group:groups(name))`. */
export function decodeAssignment(row: Json): AssignmentEvent | null {
  if (row.task === null || row.task === undefined) return null;
  const task = object(row.task, 'task');
  const group = task.group === null || task.group === undefined ? null : object(task.group, 'group');
  return {
    taskId: uuid(row, 'task_id'),
    groupId: uuid(row, 'group_id'),
    taskTitle: string(task, 'title'),
    groupName: group === null ? '' : string(group, 'name'),
    assignedBy: optionalUuid(row, 'assigned_by'),
    assignedAt: timestamp(row, 'assigned_at'),
    dueAt: optionalTimestamp(task, 'due_at'),
    taskHasRotation: (optionalArray(task, 'rotation') ?? []).length > 0,
  };
}

/** `group_activity?select=id,kind,actor_id,subject_id,task_id,task_title,item_title,created_at`. */
export function decodeActivity(row: Json): ActivityEvent {
  return {
    id: integer(row, 'id'),
    kind: known(ACTIVITY_KINDS, row, 'kind'),
    actorId: optionalUuid(row, 'actor_id'),
    subjectId: optionalUuid(row, 'subject_id'),
    taskId: optionalUuid(row, 'task_id'),
    taskTitle: optionalString(row, 'task_title'),
    itemTitle: optionalString(row, 'item_title'),
    createdAt: timestamp(row, 'created_at'),
  };
}

/** `tasks?select=group_id,status,completed_at` (the groups overview). */
export function decodeOverviewTask(row: Json): { groupId: Uuid; status: TaskStatus; completedAt: Instant | null } {
  return {
    groupId: uuid(row, 'group_id'),
    status: known(TASK_STATUSES, row, 'status'),
    completedAt: optionalTimestamp(row, 'completed_at'),
  };
}

/** `tasks?select=id,completed_by,completed_at&status=eq.done` (the weekly recap). */
export function decodeCompletion(row: Json): TaskCompletion {
  return {
    taskId: uuid(row, 'id'),
    completedBy: optionalUuid(row, 'completed_by'),
    completedAt: timestamp(row, 'completed_at'),
  };
}

/** The `group_id` of any row of a read over several groups (the groups overview pages on it). */
export function rowGroupId(value: unknown): Uuid | null {
  if (typeof value !== 'object' || value === null) return null;
  const groupId = (value as Json).group_id;
  return typeof groupId === 'string' ? groupId.toLowerCase() : null;
}
