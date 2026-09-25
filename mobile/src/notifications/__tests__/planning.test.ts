import { makeTask, type TaskItem } from '@/core/models';
import { F } from '@/core/__tests__/support';

import {
  DEFAULT_LEAD_TIME,
  EMPTY_ASSIGNMENT_STATE,
  leadTimeLabel,
  notificationRoute,
  planAssignments,
  planReminders,
  reconcileReminders,
  REMINDER_LEAD_TIMES,
  reminderFireDate,
  reminderId,
  rotationTurnBody,
} from '../planning';

const calendar = F.parisCalendar;

function assignedTask(value: number, fields: Partial<TaskItem> & { at: number; by?: string | null }): TaskItem {
  return makeTask({
    id: F.uuid(value),
    groupId: F.groupA,
    title: `Tâche ${value}`,
    createdBy: F.other,
    createdAt: F.date(2026, 1, 1),
    updatedAt: F.date(2026, 1, 1),
    assigneeIds: [F.me],
    groupName: 'Coloc',
    myAssignedAt: fields.at,
    myAssignedBy: fields.by === undefined ? F.other : fields.by,
    ...fields,
  });
}

describe('ReminderLeadTime', () => {
  it('defaults to one hour and has French labels', () => {
    expect(DEFAULT_LEAD_TIME).toBe('oneHour');
    expect(REMINDER_LEAD_TIMES.map(leadTimeLabel)).toEqual([
      'À l’heure de l’échéance',
      '15 minutes avant',
      '1 heure avant',
      '1 jour avant',
      'Aucun rappel',
    ]);
  });

  it('computes fire dates, one calendar day across daylight saving time', () => {
    const due = F.date(2026, 3, 30, 9, 0);
    expect(reminderFireDate('atDueTime', due, calendar)).toBe(due);
    expect(reminderFireDate('fifteenMinutes', due, calendar)).toBe(due - 15 * 60_000);
    expect(reminderFireDate('oneHour', due, calendar)).toBe(due - 3_600_000);
    // 29 March 2026 is the spring-forward day in Paris: 23 hours before, same wall-clock time.
    expect(reminderFireDate('oneDay', due, calendar)).toBe(F.date(2026, 3, 29, 9, 0));
    expect(reminderFireDate('off', due, calendar)).toBeNull();
  });
});

describe('planReminders', () => {
  const now = F.date(2026, 9, 24, 12, 0);

  it('keeps my open tasks with a future fire date, soonest first', () => {
    const tasks = [
      F.task(1, { due: F.date(2026, 9, 25, 18, 0), groupName: 'Coloc' }),
      F.task(2, { due: F.date(2026, 9, 24, 18, 0), groupName: null }),
      F.task(3, { due: F.date(2026, 9, 24, 12, 30) }), // fires at 11:30: past
      F.task(4, { due: F.date(2026, 9, 26, 9, 0), status: 'done' }),
      F.task(5, { due: F.date(2026, 9, 26, 9, 0), assignees: [F.other] }),
      F.task(6, { due: null }),
    ];
    const planned = planReminders({ tasks, userId: F.me, leadTime: 'oneHour', now, calendar });
    expect(planned.map((notification) => notification.id)).toEqual([
      reminderId(F.uuid(2), F.date(2026, 9, 24, 18, 0)),
      reminderId(F.uuid(1), F.date(2026, 9, 25, 18, 0)),
    ]);
    expect(planned[0]).toEqual({
      id: `due-${F.uuid(2)}-${F.date(2026, 9, 24, 18, 0) / 1000}`,
      title: 'Échéance proche',
      body: 'Tâche 2, aujourd’hui à 18:00',
      fireAt: F.date(2026, 9, 24, 17, 0),
      data: { taskId: F.uuid(2), groupId: F.groupA },
    });
    // Worded relative to the moment the reminder fires.
    expect(planned[1]?.body).toBe('Tâche 1 — Coloc, aujourd’hui à 18:00');
  });

  it('plans nothing when off, and at most the cap', () => {
    const tasks = Array.from({ length: 70 }, (_, index) => F.task(index + 1, { due: F.date(2026, 10, 1 + (index % 20), 10, index % 60) }));
    expect(planReminders({ tasks, userId: F.me, leadTime: 'off', now, calendar })).toEqual([]);
    const planned = planReminders({ tasks, userId: F.me, leadTime: 'atDueTime', now, calendar });
    expect(planned).toHaveLength(60);
    const fireDates = planned.map((notification) => notification.fireAt ?? 0);
    expect([...fireDates].sort((a, b) => a - b)).toEqual(fireDates);
  });

  it('reconciles with the pending requests', () => {
    const desired = planReminders({
      tasks: [F.task(1, { due: F.date(2026, 9, 25, 18, 0) }), F.task(2, { due: F.date(2026, 9, 26, 18, 0) })],
      userId: F.me,
      leadTime: 'oneHour',
      now,
      calendar,
    });
    const kept = desired[0]!.id;
    const { cancel, schedule } = reconcileReminders([kept, 'due-old-1', 'recap-weekly', 'assigned-x'], desired);
    expect(cancel).toEqual(['due-old-1']);
    expect(schedule.map((notification) => notification.id)).toEqual([desired[1]!.id]);
  });
});

describe('planAssignments', () => {
  const t0 = F.date(2026, 9, 24, 10, 0);

  it('records the history on the first check', () => {
    const result = planAssignments({ tasks: [assignedTask(1, { at: t0 })], userId: F.me, state: EMPTY_ASSIGNMENT_STATE, now: t0 + 60_000 });
    expect(result.notifications).toEqual([]);
    expect(result.state.cursor).toBe(t0);
    expect(result.state.handled).toEqual([`${F.uuid(1)}@${t0}`]);
  });

  it('notifies new assignments by someone else once, with the rotation wording', () => {
    const state = { cursor: t0, handled: [`${F.uuid(1)}@${t0}`] };
    const tasks = [
      assignedTask(1, { at: t0 }),
      assignedTask(2, { at: t0 + 10_000 }),
      assignedTask(3, { at: t0 + 20_000, by: null, rotation: [F.me, F.other] }),
      assignedTask(4, { at: t0 + 30_000, by: F.me }),
      assignedTask(5, { at: t0 + 40_000, status: 'done' }),
    ];
    const first = planAssignments({ tasks, userId: F.me, state, now: t0 + 60_000 });
    expect(first.notifications).toEqual([
      { id: `assigned-${F.uuid(2)}`, title: 'Nouvelle tâche', body: 'Tâche 2 — Coloc', fireAt: null, data: { taskId: F.uuid(2), groupId: F.groupA } },
      {
        id: `assigned-${F.uuid(3)}`,
        title: 'C’est ton tour',
        body: '«\u{a0}Tâche 3\u{a0}» dans «\u{a0}Coloc\u{a0}»',
        fireAt: null,
        data: { taskId: F.uuid(3), groupId: F.groupA },
      },
    ]);
    expect(first.state.cursor).toBe(t0 + 20_000);
    const again = planAssignments({ tasks, userId: F.me, state: first.state, now: t0 + 120_000 });
    expect(again.notifications).toEqual([]);
  });

  it('summarizes more than five', () => {
    const tasks = Array.from({ length: 6 }, (_, index) => assignedTask(index + 1, { at: t0 + (index + 1) * 1000 }));
    const now = t0 + 60_000;
    const result = planAssignments({ tasks, userId: F.me, state: { cursor: t0, handled: [] }, now });
    expect(result.notifications).toEqual([
      { id: `summary-${now / 1000}`, title: 'Nouvelles tâches', body: '6 nouvelles tâches assignées', fireAt: null, data: { groupId: F.groupA } },
    ]);
  });

  it('words a rotation turn without a group', () => {
    expect(rotationTurnBody('Lessive', null)).toBe('«\u{a0}Lessive\u{a0}»');
  });
});

describe('notificationRoute', () => {
  it('opens the task, « Mes tâches » or « Groupes »', () => {
    expect(notificationRoute('due-x-1', { taskId: 'ABC', groupId: 'g' })).toBe('/task/abc');
    expect(notificationRoute('summary-12', {})).toBe('/my-tasks');
    expect(notificationRoute('recap-weekly', {})).toBe('/');
    expect(notificationRoute('recap-weekly', null)).toBe('/');
  });
});
