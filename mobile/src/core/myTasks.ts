import type { FrenchCalendar, Instant } from './calendar';
import { formatDay, relativeDateText } from './frenchDate';
import { capitalizingFirstLetter, frenchCount, isSingular } from './frenchText';
import { isTurnOf } from './groups';
import { isAssigned, isOverdue, type TaskItem } from './models';
import { makeTaskRow, type TaskRow } from './presentation';
import { type DueBucket, DueBucketBoundaries, dueBucketTitle } from './taskList';
import { uuidString, type Uuid } from './uuid';

// « Mes tâches » (Swift `MyTasksViewModel`, `DaySummary`), as pure functions over the loaded tasks.

export const MY_TASKS_EMPTY_TITLE = 'Aucune tâche';
export const MY_TASKS_EMPTY_MESSAGE = 'Les tâches qui te sont assignées apparaîtront ici.';
export const NEW_BADGE_TEXT = 'Nouveau';
export const DAY_SUMMARY_TITLE = 'Ta journée';

/** Storage key of the user's « last seen » date (the « Nouveau » badges). */
export function lastSeenKey(userId: Uuid): string {
  return `myTasks.lastSeen.${uuidString(userId)}`;
}

/**
 * Assigned to me by someone else (or by a since-deleted account) after `lastSeenAt`, not done. Tasks I created and
 * tasks I assigned to myself are never new.
 */
export function isNewTask(task: TaskItem, userId: Uuid, lastSeenAt: Instant | null): boolean {
  if (task.status === 'done' || task.createdBy === userId || task.myAssignedBy === userId) return false;
  if (task.myAssignedAt === null) return false;
  return lastSeenAt === null || task.myAssignedAt > lastSeenAt;
}

/** The mark stored by « tout vu »: now, or the latest assignment when the device clock is behind the server. */
export function seenMark(tasks: readonly TaskItem[], now: Instant): Instant {
  let latest = Number.NEGATIVE_INFINITY;
  for (const task of tasks) if (task.myAssignedAt !== null) latest = Math.max(latest, task.myAssignedAt);
  return Math.max(now, latest);
}

export interface MyTasksContext {
  /** Every task read: not done, and the done ones read (today's, or all of them with « Terminées »). */
  tasks: readonly TaskItem[];
  userId: Uuid;
  lastSeenAt: Instant | null;
  now: Instant;
  calendar: FrenchCalendar;
}

export function myTaskRow(task: TaskItem, context: MyTasksContext): TaskRow {
  return makeTaskRow({
    task,
    dueText: task.dueAt === null ? null : relativeDateText(task.dueAt, context.now, context.calendar),
    isOverdue: isOverdue(task, context.now),
    assigneesText: null,
    groupName: task.groupName,
    isNew: isNewTask(task, context.userId, context.lastSeenAt),
    // An assignee may always change the status; editing needs the role, known on the group screens.
    canChangeStatus: isAssigned(task, context.userId),
    canEdit: false,
    canDelete: false,
    isMyTurn: isTurnOf(context.userId, task),
  });
}

export interface MyTasksSection {
  bucket: DueBucket;
  title: string;
  rows: TaskRow[];
}

/** The due-date sections; the done tasks only when `includeDone` (« Terminées »). */
export function myTaskSections(context: MyTasksContext, includeDone: boolean): MyTasksSection[] {
  const visible = includeDone ? context.tasks : context.tasks.filter((task) => task.status !== 'done');
  return new DueBucketBoundaries(context.now, context.calendar).sections(visible).map((section) => ({
    bucket: section.bucket,
    title: dueBucketTitle(section.bucket),
    rows: section.tasks.map((task) => myTaskRow(task, context)),
  }));
}

/** Number of « Nouveau » tasks (the tab badge). */
export function newTaskCount(context: Pick<MyTasksContext, 'tasks' | 'userId' | 'lastSeenAt'>): number {
  return context.tasks.filter((task) => isNewTask(task, context.userId, context.lastSeenAt)).length;
}

/** « Ta journée »: what the user did today out of what they planned. */
export interface DaySummary {
  /** My tasks done today, whatever their due date. */
  doneCount: number;
  /** My tasks still to do due today, plus those done today. */
  plannedCount: number;
  overdueCount: number;
  newCount: number;
}

export function daySummary(context: MyTasksContext): DaySummary {
  const bounds = new DueBucketBoundaries(context.now, context.calendar);
  const isToday = (date: Instant | null) => date !== null && date >= bounds.startOfToday && date < bounds.startOfTomorrow;
  const doneToday = context.tasks.filter((task) => task.status === 'done' && isToday(task.completedAt)).length;
  const toDoToday = context.tasks.filter((task) => task.status !== 'done' && isToday(task.dueAt)).length;
  return {
    doneCount: doneToday,
    plannedCount: doneToday + toDoToday,
    overdueCount: context.tasks.filter((task) => isOverdue(task, context.now)).length,
    newCount: newTaskCount(context),
  };
}

/** 0…1, for the ring. */
export function dayFraction(summary: DaySummary): number {
  return summary.plannedCount === 0 ? 0 : summary.doneCount / summary.plannedCount;
}

/** « 2/4 », inside the ring. */
export function dayRingText(summary: DaySummary): string {
  return `${summary.doneCount}/${summary.plannedCount}`;
}

/** « 2 tâches faites sur 4 prévues », « Tout est fait pour aujourd’hui ! », « Rien de prévu aujourd’hui ». */
export function daySubtitle(summary: DaySummary): string {
  if (summary.plannedCount === 0) return 'Rien de prévu aujourd’hui';
  if (summary.doneCount >= summary.plannedCount) return 'Tout est fait pour aujourd’hui\u{a0}!';
  const done = frenchCount(summary.doneCount, 'tâche faite', 'tâches faites');
  return `${done} sur ${summary.plannedCount} ${isSingular(summary.plannedCount) ? 'prévue' : 'prévues'}`;
}

/** « 1 en retard », null when none. */
export function dayOverdueText(summary: DaySummary): string | null {
  return summary.overdueCount === 0 ? null : `${summary.overdueCount} en retard`;
}

/** « 1 nouvelle », « 2 nouvelles », null when none. */
export function dayNewText(summary: DaySummary): string | null {
  return summary.newCount === 0 ? null : frenchCount(summary.newCount, 'nouvelle', 'nouvelles');
}

/** My tasks done today, most recently completed first. */
export function doneTodayRows(context: MyTasksContext): TaskRow[] {
  const bounds = new DueBucketBoundaries(context.now, context.calendar);
  return context.tasks
    .filter(
      (task) =>
        task.status === 'done' &&
        task.completedAt !== null &&
        task.completedAt >= bounds.startOfToday &&
        task.completedAt < bounds.startOfTomorrow,
    )
    .sort((lhs, rhs) => (rhs.completedAt ?? 0) - (lhs.completedAt ?? 0))
    .map((task) => myTaskRow(task, context));
}

/** « 2 tâches terminées aujourd’hui », « 1 tâche terminée aujourd’hui »; null when none. */
export function doneTodayText(count: number): string | null {
  if (count === 0) return null;
  return `${frenchCount(count, 'tâche terminée', 'tâches terminées')} aujourd’hui`;
}

/** « Vendredi 25 septembre », above the title. */
export function todayText(now: Instant, calendar: FrenchCalendar): string {
  return capitalizingFirstLetter(formatDay(now, calendar, false));
}

/** `updated` (a bare task returned by a status change) with the fields only the « Mes tâches » reads fill. */
export function mergeMyTaskFields(updated: TaskItem, current: TaskItem): TaskItem {
  return {
    ...updated,
    myAssignedAt: current.myAssignedAt,
    myAssignedBy: current.myAssignedBy,
    groupName: current.groupName,
    groupColor: current.groupColor,
    groupEmoji: current.groupEmoji,
  };
}
