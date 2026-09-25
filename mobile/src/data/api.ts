import { AppError } from '@/core/appError';
import type { Instant } from '@/core/calendar';
import type { ColorKey } from '@/core/colorKey';
import { makeGroupOverview } from '@/core/groups';
import {
  normalizedEmail,
  trimmed,
  validateDisplayName,
  validateDueDate,
  validateEmail,
  validateEmoji,
  validateGroupName,
  validatePassword,
  validateRecurrence,
  validateRotation,
  validateSignUp,
  validateTaskDetails,
  validateTaskTitle,
} from '@/core/inputValidation';
import { Limits } from '@/core/limits';
import type {
  ActivityEvent,
  AuthUser,
  ChecklistItem,
  GroupSummary,
  JoinResult,
  MemberRole,
  Membership,
  RecurrenceRule,
  SignUpOutcome,
  TaskCompletion,
  TaskDraft,
  TaskItem,
  TaskStatus,
  TeamGroup,
  UserProfile,
} from '@/core/models';
import { sortedGroups, sortedMembers } from '@/core/nameOrder';
import type { GroupOverview } from '@/core/presentation';
import { sortedUniqueUuids, type Uuid } from '@/core/uuid';

import { mapAuthError } from './errors';
import { formatTimestamp } from './postgresTimestamp';
import { rpc, send, sendRaw, type QueryItem, type RestRequest } from './rest';
import {
  creationOrder,
  decodeActivity,
  decodeChecklistItem,
  decodeCompletion,
  decodeGroup,
  decodeJoinResult,
  decodeMember,
  decodeMyGroup,
  decodeMyTask,
  decodeOne,
  decodeOverviewTask,
  decodeProfile,
  decodeRows,
  decodeTask,
} from './rows';
import { requireSupabase } from './supabase';

// The services of the app on Supabase (docs/CONTRACTS.md, docs/CONTRACTS-V2.md; Swift adapters in
// Packages/TeamTasksKit/Sources/TeamTasksSupabase). Every read and RPC is the one of the contracts.

// MARK: - Auth

export function authUser(user: { id: string; email?: string | null }): AuthUser {
  return { id: user.id.toLowerCase(), email: user.email ?? null } as AuthUser;
}

export const auth = {
  /** Validated first: Supabase Auth alone accepts a blank or too long name. */
  async signUp(email: string, password: string, displayName: string): Promise<SignUpOutcome> {
    const input = validateSignUp(email, password, displayName);
    const { data, error } = await requireSupabase().auth.signUp({
      email: input.email,
      password,
      options: { data: { display_name: input.displayName } },
    });
    if (error) throw mapAuthError(error);
    return data.session === null ? 'confirmationRequired' : 'signedIn';
  },

  /** A malformed e-mail or an out-of-range password cannot match any account. */
  async signIn(email: string, password: string): Promise<void> {
    const normalized = normalizedEmail(email);
    try {
      validateEmail(normalized);
      validatePassword(password);
    } catch {
      throw new AppError('invalidCredentials');
    }
    const { error } = await requireSupabase().auth.signInWithPassword({ email: normalized, password });
    if (error) throw mapAuthError(error, 'signIn');
  },

  /** Local scope: only this device's session ends; a network failure still signs out locally. */
  async signOut(): Promise<void> {
    await requireSupabase().auth.signOut({ scope: 'local' });
  },

  async sendPasswordReset(email: string): Promise<void> {
    const valid = validateEmail(email);
    const { error } = await requireSupabase().auth.resetPasswordForEmail(valid);
    if (error) throw mapAuthError(error);
  },

  /** A valid 6-digit code opens a recovery session (the user is signed in). */
  async verifyRecoveryCode(email: string, code: string): Promise<void> {
    const normalized = normalizedEmail(email);
    const token = trimmed(code);
    if (normalized === '' || token === '') throw new AppError('otpInvalid');
    const { error } = await requireSupabase().auth.verifyOtp({ email: normalized, token, type: 'recovery' });
    if (error) throw mapAuthError(error, 'verifyOTP');
  },

  /** `same_password` is a success: the requested end state holds. */
  async updatePassword(newPassword: string): Promise<void> {
    validatePassword(newPassword);
    const { error } = await requireSupabase().auth.updateUser({ password: newPassword });
    if (error && (error as { code?: string }).code !== 'same_password') throw mapAuthError(error);
  },

  /** RPC `delete_my_account`, then local sign-out; an account already gone is a success. */
  async deleteAccount(): Promise<void> {
    const answer = await sendRaw(rpc('delete_my_account'));
    if (answer.error && !(answer.error.kind === 'notAuthenticated' && answer.status !== 401)) throw answer.error;
    await requireSupabase().auth.signOut({ scope: 'local' }).catch(() => undefined);
  },
};

// MARK: - Queries (docs/CONTRACTS.md §4.3)

const PROFILE_SELECT = 'id,display_name,avatar_color,avatar_emoji';
const TASK_SELECT =
  '*,assignees:task_assignees(user_id),checklist:task_checklist_items(id,title,position,done,done_at,done_by)';
const MY_TASKS_SELECT = `${TASK_SELECT},mine:task_assignees!inner(assigned_at,assigned_by,user_id),group:groups(name,color,emoji)`;

function get(path: string, ...query: QueryItem[]): RestRequest {
  return { path, query };
}

function inList(ids: readonly Uuid[]): string {
  return `in.(${ids.join(',')})`;
}

function doneSinceFilter(since: Instant): QueryItem {
  return ['or', `(status.neq.done,completed_at.gte.${formatTimestamp(since)})`];
}

/** `p_recurrence`: `{}` = no repetition; `monthDay` is never sent. */
function recurrenceParam(rule: RecurrenceRule | null): Record<string, unknown> {
  if (rule === null) return {};
  return {
    freq: rule.frequency,
    interval: rule.interval,
    tz: rule.timeZoneId,
    weekdays: rule.weekdays === null ? null : [...rule.weekdays].sort((a, b) => a - b),
  };
}

/** A text holding U+0000 is sent as one the server refuses with the same error. */
function serverCheckedTitle(raw: string): string {
  return raw.includes('\u0000') ? '' : raw;
}

function serverCheckedEmoji(raw: string | null): string | null {
  return raw !== null && raw.includes('\u0000') ? '\u0001' : raw;
}

// MARK: - Profile

export const profiles = {
  /** No visible profile means the account no longer exists. */
  async mine(): Promise<UserProfile> {
    const rows = decodeRows(
      await send((me) => get('profiles', ['select', `${PROFILE_SELECT},onboarded_at,created_at`], ['id', `eq.${me}`])),
      decodeProfile,
    );
    if (rows[0] === undefined) throw new AppError('notAuthenticated');
    return rows[0];
  },

  async update(fields: Record<string, unknown>): Promise<UserProfile> {
    const rows = decodeRows(
      await send((me) => ({
        method: 'PATCH',
        path: 'profiles',
        query: [['select', PROFILE_SELECT], ['id', `eq.${me}`]],
        body: fields,
        prefer: 'return=representation',
      })),
      decodeProfile,
    );
    if (rows[0] === undefined) throw new AppError('forbidden');
    return rows[0];
  },

  updateDisplayName(name: string): Promise<UserProfile> {
    return profiles.update({ display_name: validateDisplayName(name) });
  },

  updateAvatar(color: ColorKey | null, emoji: string | null): Promise<UserProfile> {
    return profiles.update({ avatar_color: color, avatar_emoji: validateEmoji(emoji) });
  },

  async completeOnboarding(): Promise<void> {
    await send(() => rpc('complete_onboarding'));
  },
};

// MARK: - Groups

export const groups = {
  /** Most recently active first, ties by name then id. */
  async mine(): Promise<GroupSummary[]> {
    const rows = decodeRows(
      await send((me) => get('group_members', ['select', 'role,group:groups(*)'], ['user_id', `eq.${me}`])),
      decodeMyGroup,
    );
    return sortedGroups(rows);
  },

  async create(name: string, color: ColorKey | null = null, emoji: string | null = null): Promise<GroupSummary> {
    const validName = validateGroupName(name);
    const validEmoji = validateEmoji(emoji);
    const group = decodeOne(
      await send(() => rpc('create_group', { p_name: validName, p_color: color, p_emoji: validEmoji })),
      decodeGroup,
    );
    return { group, myRole: 'admin' };
  },

  /** `invalid_code` is returned, not raised: it becomes `invalidCode`. */
  async join(code: string): Promise<JoinResult> {
    return decodeJoinResult(await send(() => rpc('join_group_by_code', { p_code: code })));
  },

  async rename(groupId: Uuid, name: string): Promise<TeamGroup> {
    const validName = validateGroupName(name);
    return decodeOne(await send(() => rpc('rename_group', { p_group_id: groupId, p_name: validName })), decodeGroup);
  },

  async setAppearance(groupId: Uuid, color: ColorKey | null, emoji: string | null): Promise<TeamGroup> {
    return decodeOne(
      await send(() =>
        rpc('set_group_appearance', { p_group_id: groupId, p_color: color, p_emoji: serverCheckedEmoji(emoji) }),
      ),
      decodeGroup,
    );
  },

  async delete(groupId: Uuid): Promise<void> {
    await send(() => rpc('delete_group', { p_group_id: groupId }));
  },

  /** Admins first, then by name. Non-members read an empty list. */
  async members(groupId: Uuid): Promise<Membership[]> {
    const rows = decodeRows(
      await send(() =>
        get(
          'group_members',
          ['select', `user_id,role,joined_at,profile:profiles(${PROFILE_SELECT})`],
          ['group_id', `eq.${groupId}`],
        ),
      ),
      (row) => decodeMember(row, groupId),
    );
    return sortedMembers(rows);
  },

  /** Only the group's admins can read the code: 0 rows → `forbidden`. */
  async inviteCode(groupId: Uuid): Promise<string> {
    const rows = await send(() => get('group_invites', ['select', 'code'], ['group_id', `eq.${groupId}`]));
    const code = Array.isArray(rows) ? (rows[0] as { code?: unknown } | undefined)?.code : undefined;
    if (code === undefined) throw new AppError('forbidden');
    if (typeof code !== 'string') throw AppError.unknown('code d’invitation inattendu');
    return code;
  },

  async regenerateInviteCode(groupId: Uuid): Promise<string> {
    const code = await send(() => rpc('regenerate_invite_code', { p_group_id: groupId }));
    if (typeof code !== 'string') throw AppError.unknown('code d’invitation inattendu');
    return code;
  },

  async setRole(groupId: Uuid, userId: Uuid, role: MemberRole): Promise<void> {
    await send(() => rpc('set_member_role', { p_group_id: groupId, p_user_id: userId, p_role: role }));
  },

  async removeMember(groupId: Uuid, userId: Uuid): Promise<void> {
    await send(() => rpc('remove_member', { p_group_id: groupId, p_user_id: userId }));
  },

  async leave(groupId: Uuid): Promise<void> {
    await send(() => rpc('leave_group', { p_group_id: groupId }));
  },

  /** Newest first, at most `activityFeedMax` events. */
  async activity(groupId: Uuid): Promise<ActivityEvent[]> {
    const rows = decodeRows(
      await send(() =>
        get(
          'group_activity',
          ['select', 'id,kind,actor_id,subject_id,task_id,task_title,item_title,created_at'],
          ['group_id', `eq.${groupId}`],
          ['order', 'id.desc'],
          ['limit', String(Limits.activityFeedMax)],
        ),
      ),
      decodeActivity,
    );
    return rows.sort((a, b) => b.id - a.id);
  },

  /**
   * The overviews of the groups list (docs/CONTRACTS-V2.md §10): members and task states of every group in two reads.
   * A read that fills a whole page may be truncated: its last group is then left out (shown without overview).
   */
  async overviews(groupIds: readonly Uuid[], doneSince: Instant): Promise<GroupOverview[]> {
    const ids = [...new Set(groupIds)].sort();
    if (ids.length === 0) return [];
    const limit = String(Limits.readRowsMax);
    const [memberRows, taskRows] = await Promise.all([
      send(() =>
        get(
          'group_members',
          ['select', `group_id,user_id,role,joined_at,profile:profiles(${PROFILE_SELECT})`],
          ['group_id', inList(ids)],
          ['order', 'group_id.asc'],
          ['limit', limit],
        ),
      ),
      send(() =>
        get(
          'tasks',
          ['select', 'group_id,status,completed_at'],
          ['group_id', inList(ids)],
          doneSinceFilter(doneSince),
          ['order', 'group_id.asc'],
          ['limit', limit],
        ),
      ),
    ]);
    const incomplete = new Set<Uuid>();
    for (const raw of [memberRows, taskRows]) {
      if (Array.isArray(raw) && raw.length >= Limits.readRowsMax) {
        const last = (raw[raw.length - 1] as { group_id?: string }).group_id?.toLowerCase();
        if (last) incomplete.add(last);
      }
    }
    const members = decodeRows(memberRows, (row) => decodeMember(row));
    const tasks = decodeRows(taskRows, decodeOverviewTask);
    return groupIds.flatMap((groupId) => {
      const groupMembers = members.filter((member) => member.groupId === groupId);
      if (groupMembers.length === 0 || incomplete.has(groupId)) return [];
      return [makeGroupOverview(groupId, groupMembers, tasks.filter((task) => task.groupId === groupId), doneSince)];
    });
  },
};

// MARK: - Tasks

/** The draft's fields, checked in the server's order (docs/CONTRACTS-V2.md §3). */
function draftParams(draft: TaskDraft, operation: 'create' | 'update'): Record<string, unknown> {
  const title = validateTaskTitle(draft.title);
  const details = validateTaskDetails(draft.details);
  const dueAt = validateDueDate(draft.dueAt);
  const recurrence = validateRecurrence(draft.recurrence, dueAt);
  const rotation =
    operation === 'update' && recurrence === null ? [...draft.rotation] : validateRotation(draft.rotation, recurrence);
  return {
    p_title: title,
    p_details: details,
    p_priority: draft.priority,
    p_due_at: dueAt === null ? null : formatTimestamp(dueAt),
    p_assignee_ids: sortedUniqueUuids(draft.assigneeIds),
    p_recurrence: recurrenceParam(recurrence),
    p_rotation: rotation,
  };
}

export const tasks = {
  /** Unless `includeOldDone`, done tasks completed more than 30 days ago are left out. */
  async ofGroup(groupId: Uuid, includeOldDone = false): Promise<TaskItem[]> {
    const query: QueryItem[] = [
      ['select', TASK_SELECT],
      ['group_id', `eq.${groupId}`],
    ];
    if (!includeOldDone) query.push(doneSinceFilter(Date.now() - Limits.oldDoneTaskDays * 86_400_000));
    const rows = decodeRows(await send(() => ({ path: 'tasks', query })), (row) => decodeTask(row));
    return rows.sort(creationOrder);
  },

  /** The tasks assigned to me, not done or done since `doneSince`. */
  async mine(doneSince: Instant): Promise<TaskItem[]> {
    const rows = decodeRows(
      await send((me) => get('tasks', ['select', MY_TASKS_SELECT], ['mine.user_id', `eq.${me}`], doneSinceFilter(doneSince))),
      decodeMyTask,
    );
    return rows.sort(creationOrder);
  },

  /** 0 rows → `notFound`. */
  async get(taskId: Uuid): Promise<TaskItem> {
    const raw = await send(() => get('tasks', ['select', TASK_SELECT], ['id', `eq.${taskId}`]));
    if (!Array.isArray(raw)) throw AppError.unknown('réponse inattendue du serveur');
    if (raw.length === 0) throw new AppError('notFound');
    return decodeOne(raw[0], (row) => decodeTask(row));
  },

  /** A bare RPC row completed with the assignees and checklist of a read made right after. */
  async completed(row: TaskItem): Promise<TaskItem> {
    try {
      const current = await tasks.get(row.id);
      return { ...row, assigneeIds: current.assigneeIds, checklist: current.checklist };
    } catch (error) {
      if (AppError.isAppError(error) && error.kind === 'notFound') return { ...row, assigneeIds: [], checklist: [] };
      throw error;
    }
  },

  async create(groupId: Uuid, draft: TaskDraft): Promise<TaskItem> {
    const params = draftParams(draft, 'create');
    const row = decodeOne(
      await send(() =>
        rpc('create_task', { ...params, p_group_id: groupId, p_checklist: draft.checklist.map(serverCheckedTitle) }),
      ),
      (json) => decodeTask(json),
    );
    return tasks.completed(row).catch(() => row);
  },

  async update(taskId: Uuid, draft: TaskDraft): Promise<TaskItem> {
    const params = draftParams(draft, 'update');
    const row = decodeOne(await send(() => rpc('update_task', { ...params, p_task_id: taskId })), (json) => decodeTask(json));
    return tasks.completed(row);
  },

  async setStatus(taskId: Uuid, status: TaskStatus): Promise<TaskItem> {
    const row = decodeOne(
      await send(() => rpc('set_task_status', { p_task_id: taskId, p_status: status })),
      (json) => decodeTask(json),
    );
    return tasks.completed(row);
  },

  async delete(taskId: Uuid): Promise<void> {
    await send(() => rpc('delete_task', { p_task_id: taskId }));
  },

  async addChecklistItem(taskId: Uuid, title: string): Promise<ChecklistItem> {
    return decodeOne(
      await send(() => rpc('add_checklist_item', { p_task_id: taskId, p_title: serverCheckedTitle(title) })),
      decodeChecklistItem,
    );
  },

  async renameChecklistItem(itemId: Uuid, title: string): Promise<ChecklistItem> {
    return decodeOne(
      await send(() => rpc('rename_checklist_item', { p_item_id: itemId, p_title: serverCheckedTitle(title) })),
      decodeChecklistItem,
    );
  },

  async setChecklistItemDone(itemId: Uuid, done: boolean): Promise<ChecklistItem> {
    return decodeOne(
      await send(() => rpc('set_checklist_item_done', { p_item_id: itemId, p_done: done })),
      decodeChecklistItem,
    );
  },

  async deleteChecklistItem(itemId: Uuid): Promise<void> {
    await send(() => rpc('delete_checklist_item', { p_item_id: itemId }));
  },

  /** The group's tasks completed at or after `since`, for the weekly recap. */
  async completions(groupId: Uuid, since: Instant): Promise<TaskCompletion[]> {
    const rows = decodeRows(
      await send(() =>
        get(
          'tasks',
          ['select', 'id,completed_by,completed_at'],
          ['group_id', `eq.${groupId}`],
          ['status', 'eq.done'],
          ['completed_at', `gte.${formatTimestamp(since)}`],
        ),
      ),
      decodeCompletion,
    );
    return rows.sort((a, b) => a.completedAt - b.completedAt || (a.taskId < b.taskId ? -1 : 1));
  },
};
