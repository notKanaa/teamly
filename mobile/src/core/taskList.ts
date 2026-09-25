import type { FrenchCalendar, Instant } from './calendar';
import { isAssigned, isOverdue, priorityRank, type TaskItem, type TaskStatus } from './models';
import { compareStrings, foldForTitleSort } from './unicode';
import { compareUuids, type Uuid } from './uuid';

// Filters, sorts and due-date sections of the task lists (Swift `TaskFilter`, `TaskSort`, `DueBucket`).

// MARK: - Filter

/** Status criterion of a task list. */
export type TaskStatusFilter = 'all' | 'todo' | 'inProgress' | 'done' | 'notDone';

export const TASK_STATUS_FILTERS: readonly TaskStatusFilter[] = ['all', 'todo', 'inProgress', 'done', 'notDone'];

export function statusFilterLabel(filter: TaskStatusFilter): string {
  switch (filter) {
    case 'all':
      return 'Toutes';
    case 'todo':
      return 'À faire';
    case 'inProgress':
      return 'En cours';
    case 'done':
      return 'Terminées';
    case 'notDone':
      return 'Non terminées';
  }
}

export function statusFilterMatches(filter: TaskStatusFilter, status: TaskStatus): boolean {
  switch (filter) {
    case 'all':
      return true;
    case 'todo':
      return status === 'todo';
    case 'inProgress':
      return status === 'in_progress';
    case 'done':
      return status === 'done';
    case 'notDone':
      return status !== 'done';
  }
}

/** Filter of a task list; all criteria are combined with AND. */
export interface TaskFilter {
  status: TaskStatusFilter;
  /** Only tasks assigned to the current user. */
  onlyAssignedToMe: boolean;
  /** Only overdue tasks. */
  onlyOverdue: boolean;
}

export const ALL_TASKS_FILTER: TaskFilter = { status: 'all', onlyAssignedToMe: false, onlyOverdue: false };

/** Number of criteria that differ from `ALL_TASKS_FILTER`. */
export function activeCriteriaCount(filter: TaskFilter): number {
  return (filter.status === 'all' ? 0 : 1) + (filter.onlyAssignedToMe ? 1 : 0) + (filter.onlyOverdue ? 1 : 0);
}

/** `userId` null: « assigned to me » matches nothing. */
export function filterMatches(filter: TaskFilter, task: TaskItem, userId: Uuid | null, now: Instant): boolean {
  if (!statusFilterMatches(filter.status, task.status)) return false;
  if (filter.onlyAssignedToMe && (userId === null || !isAssigned(task, userId))) return false;
  if (filter.onlyOverdue && !isOverdue(task, now)) return false;
  return true;
}

/** Tasks matching the filter, in their original order. */
export function applyFilter(filter: TaskFilter, tasks: readonly TaskItem[], userId: Uuid | null, now: Instant): TaskItem[] {
  return tasks.filter((task) => filterMatches(filter, task, userId, now));
}

// MARK: - Sort

/** Sort orders of a task list: total over distinct tasks and independent of the input order. */
export type TaskSort = 'dueDate' | 'priority' | 'recentlyCreated';

export const TASK_SORTS: readonly TaskSort[] = ['dueDate', 'priority', 'recentlyCreated'];

export function taskSortLabel(sort: TaskSort): string {
  switch (sort) {
    case 'dueDate':
      return 'Échéance';
    case 'priority':
      return 'Priorité';
    case 'recentlyCreated':
      return 'Plus récentes';
  }
}

/** Case-, accent- and width-insensitive key, ligatures spelled out: « éclairage » sorts between « eau » and « fenêtre ». */
export function titleKey(title: string): string {
  return foldForTitleSort(title);
}

function ascending<T extends number | string>(lhs: T, rhs: T): number {
  if (typeof lhs === 'string' && typeof rhs === 'string') return compareStrings(lhs, rhs);
  return lhs < rhs ? -1 : rhs < lhs ? 1 : 0;
}

/** Ascending due date, none last. */
function compareDue(lhs: Instant | null, rhs: Instant | null): number {
  if (lhs === null && rhs === null) return 0;
  if (lhs === null) return 1;
  if (rhs === null) return -1;
  return ascending(lhs, rhs);
}

function compareTasks(sort: TaskSort, lhs: TaskItem, lhsTitle: string, rhs: TaskItem, rhsTitle: string): number {
  const criteria: Array<() => number> =
    sort === 'dueDate'
      ? [
          () => compareDue(lhs.dueAt, rhs.dueAt),
          () => ascending(priorityRank(rhs.priority), priorityRank(lhs.priority)),
          () => ascending(lhsTitle, rhsTitle),
          () => ascending(lhs.title, rhs.title),
          () => ascending(lhs.createdAt, rhs.createdAt),
          () => compareUuids(lhs.id, rhs.id),
        ]
      : sort === 'priority'
        ? [
            () => ascending(priorityRank(rhs.priority), priorityRank(lhs.priority)),
            () => compareDue(lhs.dueAt, rhs.dueAt),
            () => ascending(lhsTitle, rhsTitle),
            () => ascending(lhs.title, rhs.title),
            () => ascending(lhs.createdAt, rhs.createdAt),
            () => compareUuids(lhs.id, rhs.id),
          ]
        : [
            () => ascending(rhs.createdAt, lhs.createdAt),
            () => ascending(lhsTitle, rhsTitle),
            () => ascending(lhs.title, rhs.title),
            () => compareUuids(lhs.id, rhs.id),
          ];
  for (const criterion of criteria) {
    const result = criterion();
    if (result !== 0) return result;
  }
  return 0;
}

/** The tasks sorted in `sort` order (stable: only two copies of the same task keep their input order). */
export function sortTasks(sort: TaskSort, tasks: readonly TaskItem[]): TaskItem[] {
  const keyed = tasks.map((task, offset) => ({ task, offset, title: titleKey(task.title) }));
  keyed.sort((lhs, rhs) => compareTasks(sort, lhs.task, lhs.title, rhs.task, rhs.title) || lhs.offset - rhs.offset);
  return keyed.map((entry) => entry.task);
}

/** Strict ordering predicate (false for tasks that compare equal). */
export function tasksAreInIncreasingOrder(sort: TaskSort, lhs: TaskItem, rhs: TaskItem): boolean {
  return compareTasks(sort, lhs, titleKey(lhs.title), rhs, titleKey(rhs.title)) < 0;
}

// MARK: - Due-date sections

/** Due-date section of a task list (« Mes tâches »), in display order. */
export type DueBucket = 'overdue' | 'today' | 'thisWeek' | 'later' | 'noDueDate' | 'done';

export const DUE_BUCKETS: readonly DueBucket[] = ['overdue', 'today', 'thisWeek', 'later', 'noDueDate', 'done'];

export function dueBucketTitle(bucket: DueBucket): string {
  switch (bucket) {
    case 'overdue':
      return 'En retard';
    case 'today':
      return 'Aujourd’hui';
    case 'thisWeek':
      return 'Cette semaine';
    case 'later':
      return 'Plus tard';
    case 'noDueDate':
      return 'Sans échéance';
    case 'done':
      return 'Terminées';
  }
}

/** A non-empty section of tasks sharing a bucket. */
export interface DueSection {
  bucket: DueBucket;
  title: string;
  tasks: TaskItem[];
}

/**
 * Day boundaries of the buckets, computed from `now` and the calendar (time zone and first weekday): calendar
 * midnights, not multiples of 24 hours.
 */
export class DueBucketBoundaries {
  readonly now: Instant;
  readonly startOfToday: Instant;
  readonly startOfTomorrow: Instant;
  /** Equals `startOfTomorrow` on the last day of the week, making « Cette semaine » empty. */
  readonly startOfNextWeek: Instant;

  constructor(now: Instant, calendar: FrenchCalendar) {
    this.now = now;
    const startOfToday = calendar.startOfDay(now);
    this.startOfToday = startOfToday;
    const weekday = calendar.gregorianWeekday(startOfToday);
    const daysSinceWeekStart = (((weekday - calendar.firstWeekday) % 7) + 7) % 7;
    this.startOfTomorrow = calendar.startOfDay(calendar.addingDays(1, startOfToday));
    this.startOfNextWeek = calendar.startOfDay(calendar.addingDays(7 - daysSinceWeekStart, startOfToday));
  }

  bucket(task: TaskItem): DueBucket {
    if (task.status === 'done') return 'done';
    if (task.dueAt === null) return 'noDueDate';
    if (task.dueAt < this.now) return 'overdue';
    if (task.dueAt < this.startOfTomorrow) return 'today';
    if (task.dueAt < this.startOfNextWeek) return 'thisWeek';
    return 'later';
  }

  /** Ordered non-empty sections; « Terminées » lists the most recently completed first. */
  sections(tasks: readonly TaskItem[], sort: TaskSort = 'dueDate'): DueSection[] {
    const grouped = new Map<DueBucket, TaskItem[]>();
    for (const task of tasks) {
      const bucket = this.bucket(task);
      grouped.set(bucket, [...(grouped.get(bucket) ?? []), task]);
    }
    const sections: DueSection[] = [];
    for (const bucket of DUE_BUCKETS) {
      const bucketTasks = grouped.get(bucket);
      if (!bucketTasks || bucketTasks.length === 0) continue;
      const ordered = bucket === 'done' ? sortDone(bucketTasks, sort) : sortTasks(sort, bucketTasks);
      sections.push({ bucket, title: dueBucketTitle(bucket), tasks: ordered });
    }
    return sections;
  }
}

/** Most recently completed first (unknown completion date last), ties broken by `sort`. */
function sortDone(tasks: readonly TaskItem[], sort: TaskSort): TaskItem[] {
  const keyed = sortTasks(sort, tasks).map((task, offset) => ({ task, offset }));
  keyed.sort((lhs, rhs) => {
    const left = lhs.task.completedAt;
    const right = rhs.task.completedAt;
    if (left !== null && right !== null && left !== right) return right - left;
    if (left !== null && right === null) return -1;
    if (left === null && right !== null) return 1;
    return lhs.offset - rhs.offset;
  });
  return keyed.map((entry) => entry.task);
}

export function dueBucket(task: TaskItem, now: Instant, calendar: FrenchCalendar): DueBucket {
  return new DueBucketBoundaries(now, calendar).bucket(task);
}

export function dueSections(
  tasks: readonly TaskItem[],
  now: Instant,
  calendar: FrenchCalendar,
  sort: TaskSort = 'dueDate',
): DueSection[] {
  return new DueBucketBoundaries(now, calendar).sections(tasks, sort);
}
