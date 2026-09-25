import type { TaskItem } from '../models';
import {
  activeCriteriaCount,
  ALL_TASKS_FILTER,
  applyFilter,
  DUE_BUCKETS,
  dueBucket,
  DueBucketBoundaries,
  dueBucketTitle,
  dueSections,
  sortTasks,
  statusFilterLabel,
  TASK_SORTS,
  TASK_STATUS_FILTERS,
  type TaskFilter,
  taskSortLabel,
  tasksAreInIncreasingOrder,
} from '../taskList';
import { isOverdue } from '../models';
import { F } from './support';

const calendar = F.parisCalendar;

describe('TaskFilter', () => {
  const now = F.date(2026, 9, 24, 12, 0);
  const tasks = [
    F.task(1, { status: 'todo', due: F.date(2026, 9, 23), assignees: [F.me] }),
    F.task(2, { status: 'in_progress', due: F.date(2026, 9, 25), assignees: [F.other] }),
    F.task(3, { status: 'done', due: F.date(2026, 9, 20), assignees: [F.me] }),
    F.task(4, { status: 'todo', due: null, assignees: [] }),
    F.task(5, { status: 'in_progress', due: F.date(2026, 9, 24, 11, 59), assignees: [F.me, F.other] }),
  ];
  const ids = (filter: TaskFilter, userId: string | null = F.me) =>
    applyFilter(filter, tasks, userId, now).map((task) => tasks.indexOf(task) + 1);

  it('keeps everything in order by default', () => {
    expect(ids(ALL_TASKS_FILTER)).toEqual([1, 2, 3, 4, 5]);
    expect(activeCriteriaCount(ALL_TASKS_FILTER)).toBe(0);
  });

  it('filters by status', () => {
    expect(ids({ ...ALL_TASKS_FILTER, status: 'todo' })).toEqual([1, 4]);
    expect(ids({ ...ALL_TASKS_FILTER, status: 'inProgress' })).toEqual([2, 5]);
    expect(ids({ ...ALL_TASKS_FILTER, status: 'done' })).toEqual([3]);
    expect(ids({ ...ALL_TASKS_FILTER, status: 'notDone' })).toEqual([1, 2, 4, 5]);
  });

  it('filters the tasks assigned to me and the overdue ones', () => {
    expect(ids({ ...ALL_TASKS_FILTER, onlyAssignedToMe: true })).toEqual([1, 3, 5]);
    expect(ids({ ...ALL_TASKS_FILTER, onlyAssignedToMe: true }, null)).toEqual([]);
    expect(ids({ ...ALL_TASKS_FILTER, onlyOverdue: true })).toEqual([1, 5]);
  });

  it('keeps the overdue boundary strict', () => {
    const dueNow = F.task(9, { due: now });
    expect(isOverdue(dueNow, now)).toBe(false);
    expect(isOverdue(dueNow, now + 1)).toBe(true);
    expect(isOverdue(F.task(10, { due: null }), now)).toBe(false);
    expect(isOverdue(F.task(11, { status: 'done', due: F.date(2020, 1, 1) }), now)).toBe(false);
  });

  it('combines the criteria', () => {
    const filter: TaskFilter = { status: 'inProgress', onlyAssignedToMe: true, onlyOverdue: true };
    expect(ids(filter)).toEqual([5]);
    expect(activeCriteriaCount(filter)).toBe(3);
  });

  it('labels in French', () => {
    expect(TASK_STATUS_FILTERS.map(statusFilterLabel)).toEqual(['Toutes', 'À faire', 'En cours', 'Terminées', 'Non terminées']);
    expect(TASK_SORTS.map(taskSortLabel)).toEqual(['Échéance', 'Priorité', 'Plus récentes']);
  });
});

describe('TaskSort', () => {
  const titles = (tasks: TaskItem[]) => tasks.map((task) => task.title);

  it('sorts by due date, then priority, then title, none last', () => {
    const day = F.date(2026, 9, 25, 10, 0);
    const tasks = [
      F.task(1, { title: 'Sans date', priority: 'high', due: null }),
      F.task(2, { title: 'Zèbre', priority: 'low', due: day }),
      F.task(3, { title: 'banane', priority: 'high', due: day }),
      F.task(4, { title: 'Abricot', priority: 'high', due: day }),
      F.task(5, { title: 'Tôt', priority: 'low', due: day - 60_000 }),
      F.task(6, { title: 'Autre sans date', priority: 'low', due: null }),
    ];
    expect(titles(sortTasks('dueDate', tasks))).toEqual(['Tôt', 'Abricot', 'banane', 'Zèbre', 'Sans date', 'Autre sans date']);
  });

  it('sorts by priority, then due date', () => {
    const tasks = [
      F.task(1, { title: 'Moyenne', priority: 'medium', due: F.date(2026, 9, 25) }),
      F.task(2, { title: 'Haute sans date', priority: 'high', due: null }),
      F.task(3, { title: 'Haute tôt', priority: 'high', due: F.date(2026, 9, 24) }),
      F.task(4, { title: 'Basse', priority: 'low', due: F.date(2026, 9, 1) }),
    ];
    expect(titles(sortTasks('priority', tasks))).toEqual(['Haute tôt', 'Haute sans date', 'Moyenne', 'Basse']);
  });

  it('sorts the most recently created first', () => {
    const tasks = [
      F.task(1, { title: 'Ancienne', createdAt: F.date(2026, 1, 1) }),
      F.task(2, { title: 'Récente', createdAt: F.date(2026, 9, 1) }),
      F.task(3, { title: 'Moyenne', createdAt: F.date(2026, 5, 1) }),
    ];
    expect(titles(sortTasks('recentlyCreated', tasks))).toEqual(['Récente', 'Moyenne', 'Ancienne']);
  });

  it('compares titles ignoring case and accents', () => {
    const tasks = ['fenêtre', 'Éclairage', 'eau', 'Zinc', 'arrosage'].map((title, index) => F.task(index + 1, { title }));
    expect(titles(sortTasks('dueDate', tasks))).toEqual(['arrosage', 'eau', 'Éclairage', 'fenêtre', 'Zinc']);
  });

  it('sorts distinct tasks independently of the input order', () => {
    const due = F.date(2026, 9, 25, 20, 0);
    const older = F.task(2, { title: 'Sortir les poubelles', due, createdAt: F.date(2026, 9, 1) });
    const newer = F.task(1, { title: 'Sortir les poubelles', due, createdAt: F.date(2026, 9, 2) });
    const twin = F.task(3, { title: 'Sortir les poubelles', due, createdAt: F.date(2026, 9, 2) });
    for (const sort of ['dueDate', 'priority'] as const) {
      expect(sortTasks(sort, [older, newer, twin]).map((task) => task.id)).toEqual([older.id, newer.id, twin.id]);
      expect(sortTasks(sort, [twin, newer, older]).map((task) => task.id)).toEqual([older.id, newer.id, twin.id]);
    }
    expect(sortTasks('recentlyCreated', [older, twin, newer]).map((task) => task.id)).toEqual([newer.id, twin.id, older.id]);
    expect(sortTasks('recentlyCreated', [twin, older, newer]).map((task) => task.id)).toEqual([newer.id, twin.id, older.id]);
    expect(tasksAreInIncreasingOrder('dueDate', newer, twin)).toBe(true);
  });

  it('keeps the input order of two copies of the same task', () => {
    const task = F.task(1, { title: 'Même tâche', due: F.date(2026, 9, 25) });
    const copy = { ...task, status: 'in_progress' as const };
    for (const sort of TASK_SORTS) {
      expect(sortTasks(sort, [task, copy]).map((item) => item.status)).toEqual(['todo', 'in_progress']);
      expect(sortTasks(sort, [copy, task]).map((item) => item.status)).toEqual(['in_progress', 'todo']);
    }
  });

  it('reads ligatures as two letters', () => {
    const tasks = ['Payer le loyer', 'Œufs pour la fête', 'Nettoyer la cuisine', 'Zinc', 'Ænéide', 'Adresse', 'Afficher'].map(
      (title, index) => F.task(index + 1, { title }),
    );
    expect(titles(sortTasks('dueDate', tasks))).toEqual([
      'Adresse',
      'Ænéide',
      'Afficher',
      'Nettoyer la cuisine',
      'Œufs pour la fête',
      'Payer le loyer',
      'Zinc',
    ]);
  });

  it('is deterministic whatever the input order', () => {
    const tasks = [
      F.task(1, { title: 'b', priority: 'low', due: F.date(2026, 9, 25) }),
      F.task(2, { title: 'a', priority: 'low', due: F.date(2026, 9, 25) }),
      F.task(3, { title: 'c', priority: 'high', due: null }),
      F.task(4, { title: 'd', priority: 'medium', due: F.date(2026, 9, 26) }),
    ];
    for (const sort of TASK_SORTS) {
      const expected = sortTasks(sort, tasks).map((task) => task.id);
      expect(sortTasks(sort, [...tasks].reverse()).map((task) => task.id)).toEqual(expected);
      expect(sortTasks(sort, [tasks[2]!, tasks[0]!, tasks[3]!, tasks[1]!]).map((task) => task.id)).toEqual(expected);
    }
  });
});

describe('DueBucket', () => {
  const bucket = (due: number | null, now: number, status: TaskItem['status'] = 'todo') =>
    dueBucket(F.task(1, { status, due }), now, calendar);

  it('titles the sections in display order', () => {
    expect(DUE_BUCKETS.map(dueBucketTitle)).toEqual(['En retard', 'Aujourd’hui', 'Cette semaine', 'Plus tard', 'Sans échéance', 'Terminées']);
  });

  it('draws the midweek boundaries', () => {
    const now = F.date(2026, 9, 24, 12, 0);
    expect(bucket(F.date(2026, 9, 24, 11, 59), now)).toBe('overdue');
    expect(bucket(F.date(2026, 9, 20), now)).toBe('overdue');
    expect(bucket(now, now)).toBe('today');
    expect(bucket(F.date(2026, 9, 24, 23, 59, 59), now)).toBe('today');
    expect(bucket(F.date(2026, 9, 25, 0, 0), now)).toBe('thisWeek');
    expect(bucket(F.date(2026, 9, 27, 23, 59, 59), now)).toBe('thisWeek');
    expect(bucket(F.date(2026, 9, 28, 0, 0), now)).toBe('later');
    expect(bucket(F.date(2027, 1, 1), now)).toBe('later');
    expect(bucket(null, now)).toBe('noDueDate');
    expect(bucket(F.date(2026, 9, 20), now, 'done')).toBe('done');
    expect(bucket(null, now, 'done')).toBe('done');
    expect(bucket(F.date(2026, 9, 25), now, 'in_progress')).toBe('thisWeek');
  });

  it('handles now exactly at midnight', () => {
    const now = F.date(2026, 9, 28, 0, 0); // Monday 00:00
    expect(bucket(F.date(2026, 9, 27, 23, 59), now)).toBe('overdue');
    expect(bucket(now, now)).toBe('today');
    expect(bucket(F.date(2026, 9, 28, 23, 59), now)).toBe('today');
    expect(bucket(F.date(2026, 10, 4, 23, 59), now)).toBe('thisWeek');
    expect(bucket(F.date(2026, 10, 5, 0, 0), now)).toBe('later');
  });

  it('gives Sunday no « Cette semaine » section', () => {
    const now = F.date(2026, 9, 27, 10, 0);
    const bounds = new DueBucketBoundaries(now, calendar);
    expect(bounds.startOfTomorrow).toBe(F.date(2026, 9, 28));
    expect(bounds.startOfNextWeek).toBe(bounds.startOfTomorrow);
    expect(bucket(F.date(2026, 9, 27, 22, 0), now)).toBe('today');
    expect(bucket(F.date(2026, 9, 28, 8, 0), now)).toBe('later');
  });

  it('follows the calendar’s first weekday', () => {
    const sundayFirst = calendar.withFirstWeekday(1);
    const saturday = F.date(2026, 9, 26, 10, 0);
    const sunday = F.date(2026, 9, 27, 10, 0);
    expect(dueBucket(F.task(1, { due: sunday }), saturday, sundayFirst)).toBe('later');
    expect(dueBucket(F.task(1, { due: F.date(2026, 9, 28, 9, 0) }), sunday, sundayFirst)).toBe('thisWeek');
    expect(dueBucket(F.task(1, { due: sunday }), saturday, calendar)).toBe('thisWeek');
  });

  it('handles the spring-forward Sunday', () => {
    const now = F.date(2026, 3, 29, 1, 30);
    const bounds = new DueBucketBoundaries(now, calendar);
    expect(bounds.startOfToday).toBe(F.date(2026, 3, 29));
    expect(bounds.startOfTomorrow).toBe(F.date(2026, 3, 30));
    expect(bounds.startOfTomorrow - bounds.startOfToday).toBe(23 * 3600 * 1000);
    expect(bucket(F.date(2026, 3, 29, 23, 30), now)).toBe('today');
    expect(bucket(F.date(2026, 3, 30, 0, 30), now)).toBe('later');
  });

  it('handles the fall-back Sunday', () => {
    const now = F.date(2026, 10, 25, 0, 30);
    const bounds = new DueBucketBoundaries(now, calendar);
    expect(bounds.startOfTomorrow - bounds.startOfToday).toBe(25 * 3600 * 1000);
    expect(bucket(bounds.startOfToday + 24.5 * 3600 * 1000, now)).toBe('today');
    expect(bucket(F.date(2026, 10, 26, 0, 0), now)).toBe('later');
  });

  it('builds ordered, non-empty, sorted sections', () => {
    const now = F.date(2026, 9, 24, 12, 0);
    const tasks = [
      F.task(1, { title: 'Plus tard', due: F.date(2026, 10, 5) }),
      F.task(2, { title: 'Sans date B', priority: 'low', due: null }),
      F.task(3, { title: 'Retard', due: F.date(2026, 9, 23) }),
      F.task(4, { title: 'Fini ancien', status: 'done', due: F.date(2026, 9, 1), completedAt: F.date(2026, 9, 2) }),
      F.task(5, { title: 'Aujourd’hui 20h', due: F.date(2026, 9, 24, 20, 0) }),
      F.task(6, { title: 'Sans date A', priority: 'high', due: null }),
      F.task(7, { title: 'Aujourd’hui 14h', due: F.date(2026, 9, 24, 14, 0) }),
      F.task(8, { title: 'Fini récent', status: 'done', due: null, completedAt: F.date(2026, 9, 23) }),
    ];
    const sections = dueSections(tasks, now, calendar);
    expect(sections.map((section) => section.bucket)).toEqual(['overdue', 'today', 'later', 'noDueDate', 'done']);
    expect(sections.map((section) => section.tasks.map((task) => task.title))).toEqual([
      ['Retard'],
      ['Aujourd’hui 14h', 'Aujourd’hui 20h'],
      ['Plus tard'],
      ['Sans date A', 'Sans date B'],
      ['Fini récent', 'Fini ancien'],
    ]);
    expect(dueSections([], now, calendar)).toEqual([]);
  });

  it('sorts the sections as asked', () => {
    const now = F.date(2026, 9, 24, 12, 0);
    const tasks = [
      F.task(1, { title: 'Basse tôt', priority: 'low', due: F.date(2026, 9, 24, 13, 0) }),
      F.task(2, { title: 'Haute tard', priority: 'high', due: F.date(2026, 9, 24, 22, 0) }),
    ];
    expect(dueSections(tasks, now, calendar, 'priority')[0]!.tasks.map((task) => task.title)).toEqual(['Haute tard', 'Basse tôt']);
    expect(dueSections(tasks, now, calendar)[0]!.tasks.map((task) => task.title)).toEqual(['Basse tôt', 'Haute tard']);
  });
});
