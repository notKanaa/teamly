import {
  displayNameMessage,
  emailMessage,
  groupNameMessage,
  groupPreview,
  isInviteCodeComplete,
  joinResultMessage,
  passwordMessage,
  PASSWORD_TOO_LONG_MESSAGE,
  resetCodeSentMessage,
  sanitizedResetCode,
} from '../forms';
import {
  type GroupContext,
  groupFilterChips,
  groupsHeaderText,
  groupTaskRows,
  makeGroupOverview,
  membersSummary,
  turnCards,
  turnCardsSubtitle,
} from '../groups';
import { makeProfile, makeRule, type Membership, type TaskItem } from '../models';
import {
  daySubtitle,
  daySummary,
  dayNewText,
  dayOverdueText,
  dayRingText,
  doneTodayRows,
  doneTodayText,
  isNewTask,
  lastSeenKey,
  type MyTasksContext,
  myTaskSections,
  newTaskCount,
  todayText,
} from '../myTasks';
import {
  type GroupOverview,
  overviewMemberAvatars,
  overviewMoreMembersText,
  overviewSummaryText,
  overviewWeekProgress,
  overviewWeekProgressText,
} from '../presentation';
import { ALL_TASKS_FILTER } from '../taskList';
import { createdText, completedText, rotationEntries, rotationText, taskRecurrenceText, taskUpcomingDueTexts } from '../taskDetail';
import { F } from './support';

const calendar = F.parisCalendar;
const lucas = F.uuid(0xc2);
const ines = F.uuid(0xc3);
const member = (id: string, name: string, role: 'admin' | 'member' = 'member'): Membership => ({
  groupId: F.groupA,
  user: makeProfile({ id, displayName: name }),
  role,
  joinedAt: F.date(2026, 1, 1),
});
const members = [member(F.me, 'Camille Martin', 'admin'), member(lucas, 'Lucas Bernard'), member(ines, 'Inès Dubois')];

describe('Groups list', () => {
  const overview = (open: number, done: number, count = 3): GroupOverview => ({
    groupId: F.groupA,
    members: members.concat(
      Array.from({ length: Math.max(0, count - 3) }, (_, index) => member(F.uuid(0x100 + index), `Membre ${index}`)),
    ).slice(0, count),
    openTaskCount: open,
    doneTaskCount: done,
  });

  it('words the cards', () => {
    expect(overviewSummaryText(overview(4, 9))).toBe('3 membres · 4 à faire');
    expect(overviewSummaryText(overview(0, 0, 1))).toBe('1 membre · rien à faire');
    expect(overviewWeekProgressText(overview(4, 9))).toBe('9 faites sur 13');
    expect(overviewWeekProgressText(overview(5, 1))).toBe('1 faite sur 6');
    expect(overviewWeekProgressText(overview(0, 0))).toBe('Rien de prévu');
    expect(overviewWeekProgress(overview(3, 1))).toBe(0.25);
    expect(overviewWeekProgress(overview(0, 0))).toBe(0);
  });

  it('shows at most three avatar circles', () => {
    expect(overviewMemberAvatars(overview(0, 0, 3))).toHaveLength(3);
    expect(overviewMoreMembersText(overview(0, 0, 3))).toBeNull();
    expect(overviewMemberAvatars(overview(0, 0, 5))).toHaveLength(2);
    expect(overviewMoreMembersText(overview(0, 0, 5))).toBe('+3');
  });

  it('counts open and recently done tasks, and sorts the members', () => {
    const since = F.date(2026, 9, 21);
    const result = makeGroupOverview(
      F.groupA,
      [member(lucas, 'Lucas Bernard'), member(F.me, 'Camille Martin', 'admin'), member(ines, 'Inès Dubois')],
      [
        { status: 'todo', completedAt: null },
        { status: 'in_progress', completedAt: null },
        { status: 'done', completedAt: since },
        { status: 'done', completedAt: since - 1 },
      ],
      since,
    );
    expect(result.openTaskCount).toBe(2);
    expect(result.doneTaskCount).toBe(1);
    expect(result.members.map((entry) => entry.user.displayName)).toEqual(['Camille Martin', 'Inès Dubois', 'Lucas Bernard']);
  });

  it('summarizes the header', () => {
    const group = (id: string) => ({
      group: { id, name: id, createdBy: null, createdAt: 0, lastActivityAt: 0, color: null, emoji: null },
      myRole: 'member' as const,
    });
    const groups = [group(F.groupA), group(F.groupB)];
    expect(groupsHeaderText([], null)).toBeNull();
    expect(groupsHeaderText(groups, null)).toBe('2 groupes');
    const overviews = new Map([
      [F.groupA, { ...overview(4, 1), groupId: F.groupA }],
      [F.groupB, { ...overview(7, 0), groupId: F.groupB }],
    ]);
    expect(groupsHeaderText(groups, overviews)).toBe('2 groupes · 11 tâches à faire');
    expect(groupsHeaderText([group(F.groupA)], new Map([[F.groupA, { ...overview(1, 0), groupId: F.groupA }]]))).toBe('1 groupe · 1 tâche à faire');
    expect(groupsHeaderText([group(F.groupA)], new Map([[F.groupA, { ...overview(0, 0), groupId: F.groupA }]]))).toBe('1 groupe · aucune tâche à faire');
  });
});

describe('Group screen', () => {
  const now = F.date(2026, 9, 24, 10);
  const rule = makeRule({ frequency: 'weekly', timeZoneId: 'Europe/Paris' });
  const rotating = (value: number, turn: string, rotation: string[]): TaskItem => ({
    ...F.task(value, { title: 'Sortir les poubelles', due: F.date(2026, 9, 24, 20), assignees: [turn], groupName: null }),
    recurrence: rule,
    rotation,
    turnUserId: turn,
  });
  const context = (tasks: TaskItem[], role: 'admin' | 'member' | null = 'admin'): GroupContext => ({
    tasks,
    members,
    myRole: role,
    userId: F.me,
    now,
    calendar,
  });

  it('summarizes the members', () => {
    expect(membersSummary(3, 'admin')).toBe('3 membres · Tu es admin');
    expect(membersSummary(2, 'member')).toBe('2 membres · Tu es membre');
    expect(membersSummary(1, null)).toBe('1 membre');
  });

  it('builds the turn cards', () => {
    const cards = turnCards(context([rotating(1, F.me, [F.me, lucas]), rotating(2, lucas, [lucas, F.me, ines])]));
    expect(cards).toHaveLength(2);
    const mine = cards.find((card) => card.id === F.uuid(1))!;
    expect(mine.isMyTurn).toBe(true);
    expect(mine.nextText).toBe('puis Lucas');
    expect(mine.dueText).toBe('Aujourd’hui à 20:00');
    const theirs = cards.find((card) => card.id === F.uuid(2))!;
    expect(theirs.current?.shortName).toBe('Lucas');
    expect(theirs.nextText).toBe('puis toi');
    expect(turnCardsSubtitle(cards)).toBe('2 tâches tournantes');
    expect(turnCardsSubtitle([])).toBeNull();
    // A done occurrence has no card.
    expect(turnCards(context([{ ...rotating(3, F.me, [F.me, lucas]), status: 'done', completedAt: now }]))).toEqual([]);
  });

  it('builds the rows with the assignees and « Ton tour »', () => {
    const tasks = [rotating(1, F.me, [F.me, lucas]), F.task(2, { title: 'Payer le loyer', due: F.date(2026, 9, 23, 18), assignees: [ines], groupName: null })];
    const rows = groupTaskRows(context(tasks), ALL_TASKS_FILTER);
    expect(rows.map((row) => row.title)).toEqual(['Payer le loyer', 'Sortir les poubelles']);
    expect(rows[0]!.isOverdue).toBe(true);
    expect(rows[0]!.dueText).toBe('Hier à 18:00');
    expect(rows[0]!.assignees.map((badge) => badge.shortName)).toEqual(['Inès']);
    expect(rows[1]!.isMyTurn).toBe(true);
    expect(rows[1]!.recurrenceText).toBe('Chaque semaine');
    expect(rows[1]!.canEdit).toBe(true);
    const memberRows = groupTaskRows(context(tasks, 'member'), ALL_TASKS_FILTER);
    expect(memberRows[0]!.canChangeStatus).toBe(false);
    expect(memberRows[1]!.canChangeStatus).toBe(true);
  });

  it('counts the filter chips', () => {
    const tasks = [
      F.task(1, { status: 'todo', assignees: [F.me] }),
      F.task(2, { status: 'todo', assignees: [lucas] }),
      F.task(3, { status: 'in_progress', assignees: [F.me] }),
      F.task(4, { status: 'done', assignees: [F.me] }),
    ];
    expect(groupFilterChips(context(tasks), ALL_TASKS_FILTER).map((chip) => chip.countedLabel)).toEqual([
      'Toutes · 4',
      'À faire · 2',
      'En cours · 1',
      'Terminées · 1',
      'Assignées à moi',
      'En retard',
    ]);
    expect(groupFilterChips(context(tasks), { ...ALL_TASKS_FILTER, onlyAssignedToMe: true }).map((chip) => chip.countedLabel)).toEqual([
      'Toutes · 3',
      'À faire · 1',
      'En cours · 1',
      'Terminées · 1',
      'Assignées à moi',
      'En retard',
    ]);
  });
});

describe('Mes tâches', () => {
  const now = F.date(2026, 9, 24, 10);
  const mine = (value: number, fields: Parameters<typeof F.task>[1] = {}, assigned: { at?: number; by?: string | null } = {}): TaskItem => ({
    ...F.task(value, fields),
    myAssignedAt: assigned.at ?? F.date(2026, 9, 23),
    myAssignedBy: assigned.by === undefined ? F.other : assigned.by,
  });
  const context = (tasks: TaskItem[], lastSeenAt: number | null = null): MyTasksContext => ({ tasks, userId: F.me, lastSeenAt, now, calendar });

  it('marks as new the tasks assigned by someone else since the last look', () => {
    expect(isNewTask(mine(1), F.me, null)).toBe(true);
    expect(isNewTask(mine(1), F.me, F.date(2026, 9, 22))).toBe(true);
    expect(isNewTask(mine(1), F.me, F.date(2026, 9, 23))).toBe(false);
    expect(isNewTask(mine(1, {}, { by: F.me }), F.me, null)).toBe(false);
    expect(isNewTask({ ...mine(1), createdBy: F.me }, F.me, null)).toBe(false);
    expect(isNewTask(mine(1, { status: 'done' }), F.me, null)).toBe(false);
    expect(isNewTask(mine(1, {}, { by: null }), F.me, null)).toBe(true);
    expect(lastSeenKey(F.me)).toBe('myTasks.lastSeen.00000000-0000-0000-0000-00000000000A');
  });

  it('summarizes the day', () => {
    const tasks = [
      mine(1, { due: F.date(2026, 9, 24, 20) }),
      mine(2, { due: F.date(2026, 9, 23, 18) }),
      mine(3, { status: 'done', completedAt: F.date(2026, 9, 24, 9) }),
      mine(4, { due: F.date(2026, 9, 25, 18) }, { by: F.me }),
    ];
    const summary = daySummary(context(tasks));
    expect(summary).toEqual({ doneCount: 1, plannedCount: 2, overdueCount: 1, newCount: 2 });
    expect(dayRingText(summary)).toBe('1/2');
    expect(daySubtitle(summary)).toBe('1 tâche faite sur 2 prévues');
    expect(dayOverdueText(summary)).toBe('1 en retard');
    expect(dayNewText(summary)).toBe('2 nouvelles');
    expect(daySubtitle({ doneCount: 2, plannedCount: 2, overdueCount: 0, newCount: 0 })).toBe('Tout est fait pour aujourd’hui\u{a0}!');
    expect(daySubtitle({ doneCount: 0, plannedCount: 0, overdueCount: 0, newCount: 0 })).toBe('Rien de prévu aujourd’hui');
    expect(daySubtitle({ doneCount: 0, plannedCount: 1, overdueCount: 0, newCount: 0 })).toBe('0 tâche faite sur 1 prévue');
    expect(dayNewText({ doneCount: 0, plannedCount: 0, overdueCount: 0, newCount: 1 })).toBe('1 nouvelle');
    expect(dayOverdueText({ doneCount: 0, plannedCount: 0, overdueCount: 0, newCount: 0 })).toBeNull();
  });

  it('builds the sections and today’s done tasks', () => {
    const tasks = [
      mine(1, { title: 'Sortir les poubelles', due: F.date(2026, 9, 24, 20) }),
      mine(2, { title: 'Payer le loyer', due: F.date(2026, 9, 23, 18) }),
      mine(3, { title: 'Nettoyer la cuisine', status: 'done', completedAt: F.date(2026, 9, 24, 9) }),
      mine(4, { title: 'Réserver le gymnase', due: F.date(2026, 9, 27, 18) }),
    ];
    const sections = myTaskSections(context(tasks), false);
    expect(sections.map((section) => section.title)).toEqual(['En retard', 'Aujourd’hui', 'Cette semaine']);
    expect(sections[1]!.rows[0]!.groupShortName).toBe('Coloc\u{27}');
    expect(sections[1]!.rows[0]!.canChangeStatus).toBe(true);
    expect(sections[2]!.rows[0]!.dueText).toBe('Dimanche à 18:00');
    expect(myTaskSections(context(tasks), true).map((section) => section.title)).toContain('Terminées');
    expect(doneTodayRows(context(tasks)).map((row) => row.title)).toEqual(['Nettoyer la cuisine']);
    expect(doneTodayText(1)).toBe('1 tâche terminée aujourd’hui');
    expect(doneTodayText(2)).toBe('2 tâches terminées aujourd’hui');
    expect(doneTodayText(0)).toBeNull();
    expect(newTaskCount(context(tasks))).toBe(3);
    expect(todayText(now, calendar)).toBe('Jeudi 24 septembre');
  });
});

describe('Task screen', () => {
  const now = F.date(2026, 9, 24, 10);
  const rule = makeRule({ frequency: 'weekly', weekdays: [1, 3, 5], timeZoneId: 'Europe/Paris' });

  it('words the rotation from the current turn', () => {
    const task: TaskItem = { ...F.task(1, { due: F.date(2026, 9, 25, 18) }), recurrence: rule, rotation: [ines, F.me, lucas], turnUserId: lucas };
    const entries = rotationEntries(task, members, F.me);
    expect(entries.map((entry) => entry.person.shortName)).toEqual(['Lucas', 'Inès', 'Camille']);
    expect(entries[0]!.isCurrentTurn).toBe(true);
    expect(rotationText(entries)).toBe('C’est au tour de Lucas, puis Inès, puis toi.');
    const mineNow = rotationEntries({ ...task, turnUserId: F.me }, members, F.me);
    expect(rotationText(mineNow)).toBe('C’est ton tour, puis Lucas, puis Inès.');
    const inesTurn = rotationEntries({ ...task, turnUserId: ines }, members, F.me);
    expect(rotationText(inesTurn)).toBe('C’est au tour d’Inès, puis toi, puis Lucas.');
    const noTurn = rotationEntries({ ...task, turnUserId: null }, members, F.me);
    expect(rotationText(noTurn)).toBe('Tour de rôle\u{a0}: Inès, puis toi, puis Lucas.');
    expect(rotationText([])).toBeNull();
  });

  it('words the repetition and the next dates', () => {
    const task: TaskItem = { ...F.task(1, { due: F.date(2026, 9, 25, 18) }), recurrence: rule };
    expect(taskRecurrenceText(task)).toBe('Chaque semaine, le lundi, le mercredi et le vendredi');
    // Thursday 24: Monday and Wednesday are 2 to 6 days ahead (the weekday alone), Friday 2 is 8 days ahead.
    expect(taskUpcomingDueTexts(task, now, calendar)).toEqual(['Lundi à 18:00', 'Mercredi à 18:00', 'Vendredi 2 octobre à 18:00']);
    expect(taskUpcomingDueTexts({ ...task, status: 'done' }, now, calendar)).toEqual([]);
    expect(taskRecurrenceText(F.task(2))).toBeNull();
  });

  it('words the creation and the completion', () => {
    const task = { ...F.task(1, { createdAt: F.date(2026, 9, 23, 14, 31) }), createdBy: lucas };
    expect(createdText(task, members, F.me, now, calendar)).toBe('Créée par Lucas Bernard hier à 14:31');
    expect(createdText({ ...task, createdBy: F.me }, members, F.me, now, calendar)).toBe('Créée par toi hier à 14:31');
    expect(createdText({ ...task, createdBy: null }, members, F.me, now, calendar)).toBe('Créée par Ancien membre hier à 14:31');
    expect(completedText({ ...task, status: 'done', completedAt: F.date(2026, 9, 24, 9) }, now, calendar)).toBe('Terminée aujourd’hui à 09:00');
    expect(completedText(task, now, calendar)).toBeNull();
  });
});

describe('Forms', () => {
  it('words the sign-up fields', () => {
    expect(emailMessage('x')).toBe('Adresse e-mail invalide.');
    expect(emailMessage('a@b.fr')).toBeNull();
    expect(passwordMessage('court')).toBe('Mot de passe trop faible (8 caractères minimum).');
    expect(passwordMessage('a'.repeat(73))).toBe(PASSWORD_TOO_LONG_MESSAGE);
    expect(passwordMessage('motdepasse')).toBeNull();
    expect(displayNameMessage(' ')).toBe('Le nom doit contenir entre 1 et 50 caractères.');
    expect(displayNameMessage('Zoé')).toBeNull();
    expect(groupNameMessage('x'.repeat(61))).toBe('Le nom du groupe doit contenir entre 1 et 60 caractères.');
    expect(groupNameMessage('Coloc')).toBeNull();
  });

  it('keeps six digits of the reset code', () => {
    expect(sanitizedResetCode(' 12a3-45 678 ')).toBe('123456');
    expect(sanitizedResetCode('１２３')).toBe('');
    expect(resetCodeSentMessage('camille@example.com')).toBe('Si un compte existe pour camille@example.com, un code à 6 chiffres vient d’y être envoyé.');
  });

  it('checks the invite code and words the result', () => {
    expect(isInviteCodeComplete('abcd-efg')).toBe(false);
    expect(isInviteCodeComplete('abcd-efgh')).toBe(true);
    expect(joinResultMessage({ groupId: F.groupA, groupName: 'Coloc', alreadyMember: false })).toBe('Tu as rejoint «\u{a0}Coloc\u{a0}».');
    expect(joinResultMessage({ groupId: F.groupA, groupName: 'Coloc', alreadyMember: true })).toBe('Tu fais déjà partie de «\u{a0}Coloc\u{a0}».');
    expect(groupPreview('Club de lecture', 'violet', null)).toEqual({ color: 'violet', emoji: null, initials: 'CD' });
  });
});
