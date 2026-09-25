import type { FrenchCalendar, Instant } from '@/core/calendar';
import { relativeDateTime } from '@/core/frenchDate';
import type { TaskItem } from '@/core/models';
import type { Uuid } from '@/core/uuid';

// The local notifications of docs/CONTRACTS.md §7 and docs/CONTRACTS-V2.md §8, §11, as pure functions (Swift
// `ReminderLeadTime`, `ReminderPlanner`, `AssignmentNotifier`, `WeeklyRecapNotifier`). `scheduler.ts` applies them.

/** A notification to show, now (`fireAt` null) or at `fireAt`. */
export interface LocalNotification {
  id: string;
  title: string;
  body: string;
  fireAt: Instant | null;
  /** `taskId` and `groupId` (a tap opens the task); empty for a summary or the recap. */
  data: { taskId?: Uuid; groupId?: Uuid };
}

// MARK: - Lead time (Réglages › Rappels d’échéance)

export const REMINDER_LEAD_TIMES = ['atDueTime', 'fifteenMinutes', 'oneHour', 'oneDay', 'off'] as const;
export type ReminderLeadTime = (typeof REMINDER_LEAD_TIMES)[number];

/** Default when nothing is stored: 1 hour before. */
export const DEFAULT_LEAD_TIME: ReminderLeadTime = 'oneHour';

export function isReminderLeadTime(value: unknown): value is ReminderLeadTime {
  return typeof value === 'string' && (REMINDER_LEAD_TIMES as readonly string[]).includes(value);
}

/** The label of the settings picker. */
export function leadTimeLabel(leadTime: ReminderLeadTime): string {
  switch (leadTime) {
    case 'atDueTime':
      return 'À l’heure de l’échéance';
    case 'fifteenMinutes':
      return '15 minutes avant';
    case 'oneHour':
      return '1 heure avant';
    case 'oneDay':
      return '1 jour avant';
    case 'off':
      return 'Aucun rappel';
  }
}

/**
 * When the reminder of a task due at `dueAt` fires; null when reminders are off. « 1 jour avant » is one calendar day
 * earlier at the same wall-clock time (23 or 25 hours across a daylight saving change).
 */
export function reminderFireDate(leadTime: ReminderLeadTime, dueAt: Instant, calendar: FrenchCalendar): Instant | null {
  switch (leadTime) {
    case 'atDueTime':
      return dueAt;
    case 'fifteenMinutes':
      return dueAt - 15 * 60_000;
    case 'oneHour':
      return dueAt - 60 * 60_000;
    case 'oneDay':
      return calendar.addingDays(-1, dueAt);
    case 'off':
      return null;
  }
}

// MARK: - Due-date reminders

export const REMINDER_PREFIX = 'due-';
/** Leaves room below the iOS limit of 64 pending requests for the other notifications. */
export const REMINDER_MAX_PENDING = 60;
export const REMINDER_TITLE = 'Échéance proche';

/** `due-<taskId>-<dueEpochSeconds>`: the id changes with the due date, so the reminder is replaced. */
export function reminderId(taskId: Uuid, dueAt: Instant): string {
  return `${REMINDER_PREFIX}${taskId}-${Math.floor(dueAt / 1000)}`;
}

/**
 * The reminders that should be pending: my tasks, not done, with a due date, whose fire date is strictly after `now`;
 * the soonest first (then by id), at most `maxPending`. The body reads « Titre — Groupe, demain à 18:00 ».
 */
export function planReminders(fields: {
  tasks: readonly TaskItem[];
  userId: Uuid;
  leadTime: ReminderLeadTime;
  now: Instant;
  calendar: FrenchCalendar;
  maxPending?: number;
}): LocalNotification[] {
  const maxPending = Math.max(0, fields.maxPending ?? REMINDER_MAX_PENDING);
  if (fields.leadTime === 'off' || maxPending === 0) return [];
  const seen = new Set<Uuid>();
  const reminders: LocalNotification[] = [];
  for (const task of fields.tasks) {
    if (task.status === 'done' || task.dueAt === null || !task.assigneeIds.includes(fields.userId)) continue;
    if (seen.has(task.id)) continue;
    seen.add(task.id);
    const fireAt = reminderFireDate(fields.leadTime, task.dueAt, fields.calendar);
    if (fireAt === null || fireAt <= fields.now) continue;
    const when = relativeDateTime(task.dueAt, fireAt, fields.calendar);
    const body = task.groupName ? `${task.title} — ${task.groupName}, ${when}` : `${task.title}, ${when}`;
    reminders.push({
      id: reminderId(task.id, task.dueAt),
      title: REMINDER_TITLE,
      body,
      fireAt,
      data: { taskId: task.id, groupId: task.groupId },
    });
  }
  reminders.sort((a, b) => (a.fireAt ?? 0) - (b.fireAt ?? 0) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return reminders.slice(0, maxPending);
}

/** What to cancel and what to schedule so that the pending reminders become `desired`. */
export function reconcileReminders(
  pendingIds: readonly string[],
  desired: readonly LocalNotification[],
): { cancel: string[]; schedule: LocalNotification[] } {
  const wanted = new Set(desired.map((notification) => notification.id));
  const pending = new Set(pendingIds.filter((id) => id.startsWith(REMINDER_PREFIX)));
  return {
    cancel: [...pending].filter((id) => !wanted.has(id)),
    schedule: desired.filter((notification) => !pending.has(notification.id)),
  };
}

// MARK: - New assignments

export const ASSIGNMENT_MAX_INDIVIDUAL = 5;
export const ASSIGNMENT_REMEMBERED_LIMIT = 200;
/** Every check re-reads this much before the cursor: `assigned_at` is a transaction start time. */
export const ASSIGNMENT_OVERLAP_MS = 2 * 60_000;
export const ASSIGNMENT_TITLE = 'Nouvelle tâche';
export const ASSIGNMENTS_SUMMARY_TITLE = 'Nouvelles tâches';
export const ROTATION_TURN_TITLE = 'C’est ton tour';

/** `« <task> » dans « <group> »`, or `« <task> »` when the group is unknown. */
export function rotationTurnBody(taskTitle: string, groupName: string | null): string {
  const task = `«\u{a0}${taskTitle}\u{a0}»`;
  return groupName ? `${task} dans «\u{a0}${groupName}\u{a0}»` : task;
}

/** What this device remembers of the assignments it handled (per user, in AsyncStorage). */
export interface AssignmentState {
  /** The latest server `assigned_at` handled; null before the first check (history is never notified). */
  cursor: Instant | null;
  /** Handled assignments, oldest first: `<taskId>@<assignedAt>`. */
  handled: string[];
}

export const EMPTY_ASSIGNMENT_STATE: AssignmentState = { cursor: null, handled: [] };

function assignmentKey(task: TaskItem): string {
  return `${task.id}@${task.myAssignedAt ?? 0}`;
}

/**
 * The tasks newly assigned to me by someone else in a successfully loaded « Mes tâches » list, their notifications,
 * and the next state. Up to `maxIndividual` tasks get one `assigned-<taskId>` notification each (« C’est ton tour »
 * for a turn handed out by the server); more get one `summary-<epochSeconds>` notification. The first check only
 * records the history.
 */
export function planAssignments(fields: {
  tasks: readonly TaskItem[];
  userId: Uuid;
  state: AssignmentState;
  now: Instant;
  maxIndividual?: number;
}): { notifications: LocalNotification[]; state: AssignmentState } {
  const { userId, state, now } = fields;
  const maxIndividual = Math.max(0, fields.maxIndividual ?? ASSIGNMENT_MAX_INDIVIDUAL);
  const assigned = fields.tasks.filter(
    (task) => task.status !== 'done' && task.myAssignedAt !== null && task.myAssignedBy !== userId,
  );
  const latest = assigned.reduce<Instant | null>(
    (max, task) => (max === null || (task.myAssignedAt ?? 0) > max ? task.myAssignedAt : max),
    null,
  );

  if (state.cursor === null) {
    // First check: the existing assignments are history. The cursor starts now at the latest (server) date seen.
    const handled = assigned.map(assignmentKey).slice(-ASSIGNMENT_REMEMBERED_LIMIT);
    return { notifications: [], state: { cursor: Math.max(latest ?? 0, now - ASSIGNMENT_OVERLAP_MS), handled } };
  }

  const handledSet = new Set(state.handled);
  const since = state.cursor - ASSIGNMENT_OVERLAP_MS;
  const fresh = assigned
    .filter((task) => (task.myAssignedAt ?? 0) > since && !handledSet.has(assignmentKey(task)))
    .sort((a, b) => (a.myAssignedAt ?? 0) - (b.myAssignedAt ?? 0) || (a.id < b.id ? -1 : 1));
  const handled = [...state.handled.filter((key) => !fresh.some((task) => key.startsWith(`${task.id}@`))), ...fresh.map(assignmentKey)];
  const next: AssignmentState = {
    cursor: Math.max(state.cursor, latest ?? state.cursor),
    handled: handled.slice(-ASSIGNMENT_REMEMBERED_LIMIT),
  };
  if (fresh.length === 0) return { notifications: [], state: next };

  if (fresh.length > maxIndividual) {
    const groupIds = new Set(fresh.map((task) => task.groupId));
    const single = groupIds.size === 1 ? fresh[0]?.groupId : undefined;
    return {
      notifications: [
        {
          id: `summary-${Math.floor(now / 1000)}`,
          title: ASSIGNMENTS_SUMMARY_TITLE,
          body: `${fresh.length} nouvelles tâches assignées`,
          fireAt: null,
          data: single ? { groupId: single } : {},
        },
      ],
      state: next,
    };
  }
  const notifications = fresh.map((task): LocalNotification => {
    const isTurn = task.myAssignedBy === null && task.rotation.length > 0;
    return {
      id: `assigned-${task.id}`,
      title: isTurn ? ROTATION_TURN_TITLE : ASSIGNMENT_TITLE,
      body: isTurn ? rotationTurnBody(task.title, task.groupName) : task.groupName ? `${task.title} — ${task.groupName}` : task.title,
      fireAt: null,
      data: { taskId: task.id, groupId: task.groupId },
    };
  });
  return { notifications, state: next };
}

// MARK: - Weekly recap

export const RECAP_ID = 'recap-weekly';
export const RECAP_TITLE = 'Le récap de la semaine est prêt';
export const RECAP_BODY = 'Qui a fait quoi cette semaine, avec le podium de chaque groupe.';
/** Monday (expo-notifications counts 1 = Sunday) at 09:00. */
export const RECAP_SCHEDULE = { weekday: 2, hour: 9, minute: 0 } as const;

// MARK: - Taps

/** The route a tapped notification opens: its task, else « Mes tâches » (a summary), else « Groupes » (the recap). */
export function notificationRoute(id: string, data: unknown): string {
  const taskId = typeof data === 'object' && data !== null ? (data as { taskId?: unknown }).taskId : undefined;
  if (typeof taskId === 'string' && taskId !== '') return `/task/${taskId.toLowerCase()}`;
  if (id.startsWith('summary-')) return '/my-tasks';
  return '/';
}
