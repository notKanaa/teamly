import { makeProfile, makeRule, makeTask, type Membership, type MemberRole } from '../models';
import {
  addChecklistItem,
  defaultDueDate,
  draftRule,
  editorDraft,
  editorRecurrenceSummary,
  editorTitle,
  editorUpcomingDates,
  hasChanges,
  makeEditorState,
  moveRotationMember,
  REPEAT_FREQUENCIES,
  repeatFrequencyLabel,
  rotationEditorEntries,
  saveButtonTitle,
  selectedWeekdays,
  setFrequency,
  setInterval,
  setRotationEnabled,
  toggleAssignee,
  toggleRotationMember,
  toggleWeekday,
  validateEditor,
  weekdayOptions,
  type TaskEditorState,
} from '../taskEditor';

import { F, typographyProblems } from './support';

const camille = makeProfile({ id: F.me, displayName: 'Camille Martin' });
const lucas = makeProfile({ id: F.uuid(0xc2), displayName: 'Lucas Bernard' });
const ines = makeProfile({ id: F.uuid(0xc3), displayName: 'Inès Dubois' });
const member = (user = camille, role: MemberRole = 'member'): Membership => ({
  groupId: F.groupA,
  user,
  role,
  joinedAt: F.date(2026, 9, 1),
});
const members = [member(camille, 'admin'), member(lucas), member(ines)];

/** Friday 25 September 2026, 10:00 in Paris. */
const now = F.date(2026, 9, 25, 10);

function createState(): TaskEditorState {
  return makeEditorState({ kind: 'create', groupId: F.groupA }, now, F.parisCalendar);
}

describe('TaskEditor', () => {
  it('starts a new task tomorrow at 18:00 without due date', () => {
    const state = createState();
    expect(defaultDueDate(now, F.parisCalendar)).toBe(F.date(2026, 9, 26, 18));
    expect(state.dueDate).toBe(F.date(2026, 9, 26, 18));
    expect(state.hasDueDate).toBe(false);
    expect(editorTitle(state)).toBe('Nouvelle tâche');
    expect(saveButtonTitle(state)).toBe('Créer');
    expect(hasChanges(state)).toBe(false);
    expect(REPEAT_FREQUENCIES.map(repeatFrequencyLabel)).toEqual(['Jamais', 'Jour', 'Semaine', 'Mois']);
  });

  it('turns the due date on with a repetition and clamps the interval', () => {
    let state = setFrequency(createState(), 'weekly');
    expect(state.hasDueDate).toBe(true);
    expect(setInterval(state, 0).interval).toBe(1);
    expect(setInterval(state, 99).interval).toBe(52);
    state = setInterval(state, 2);
    expect(draftRule(state)).toEqual(makeRule({ frequency: 'weekly', interval: 2, timeZoneId: 'Europe/Paris' }));
    expect(editorRecurrenceSummary(state)).toBe('Toutes les 2 semaines, le samedi');
  });

  it('picks weekdays, back to the due date’s weekday', () => {
    let state = setFrequency(createState(), 'weekly');
    expect(selectedWeekdays(state)).toEqual([6]);
    expect(weekdayOptions(state).map((option) => option.letter).join('')).toBe('LMMJVSD');
    expect(toggleWeekday(state, 6)).toBe(state); // the last day stays
    state = toggleWeekday(state, 1);
    expect(state.weekdays).toEqual([1, 6]);
    expect(draftRule(state)?.weekdays).toEqual([1, 6]);
    state = toggleWeekday(state, 1);
    expect(state.weekdays).toBeNull();
    // A daily rule sends no weekdays.
    expect(draftRule(setFrequency(toggleWeekday(state, 3), 'daily'))?.weekdays).toBeNull();
  });

  it('previews the next dates from the due date', () => {
    const state = setFrequency(createState(), 'daily');
    expect(editorUpcomingDates(state)).toEqual([F.date(2026, 9, 26, 18), F.date(2026, 9, 27, 18), F.date(2026, 9, 28, 18)]);
    expect(editorUpcomingDates(createState())).toEqual([]);
  });

  it('keeps the task’s zone and month day while the local due date stays', () => {
    const task = makeTask({
      id: F.uuid(1),
      groupId: F.groupA,
      title: 'Loyer',
      createdBy: F.me,
      createdAt: now,
      updatedAt: now,
      dueAt: F.date(2026, 10, 31, 9),
      recurrence: makeRule({ frequency: 'monthly', timeZoneId: 'America/New_York', monthDay: 31 }),
    });
    const state = makeEditorState({ kind: 'edit', task }, now, F.parisCalendar);
    expect(editorTitle(state)).toBe('Modifier la tâche');
    expect(saveButtonTitle(state)).toBe('Enregistrer');
    expect(hasChanges(state)).toBe(false);
    expect(draftRule(state)).toEqual(task.recurrence);
    const moved = { ...state, dueDate: F.date(2026, 10, 30, 9) };
    expect(draftRule(moved)?.monthDay).toBeNull();
    expect(draftRule(moved)?.timeZoneId).toBe('America/New_York');
    expect(hasChanges(moved)).toBe(true);
  });

  it('proposes a rotation, the assignees first, and orders it', () => {
    let state = setFrequency(createState(), 'weekly');
    state = toggleAssignee(state, lucas.id).state;
    state = setRotationEnabled(state, true, members);
    expect(state.rotation).toEqual([lucas.id, camille.id, ines.id]);
    let entries = rotationEditorEntries(state, members, F.me);
    expect(entries.map((entry) => [entry.position, entry.badge])).toEqual([
      [1, 'Commence'],
      [2, null],
      [3, null],
    ]);
    state = moveRotationMember(state, camille.id, -1, members);
    expect(state.rotation).toEqual([camille.id, lucas.id, ines.id]);
    expect(moveRotationMember(state, camille.id, -1, members)).toBe(state);
    state = toggleRotationMember(state, ines.id, members).state;
    entries = rotationEditorEntries(state, members, F.me);
    expect(entries.map((entry) => entry.isIncluded)).toEqual([true, true, false]);
    expect(editorDraft(state).rotation).toEqual([camille.id, lucas.id]);
    // No repetition, no rotation.
    expect(editorDraft(setFrequency(state, 'never')).rotation).toEqual([]);
  });

  it('shows whose turn it is when editing', () => {
    const task = makeTask({
      id: F.uuid(2),
      groupId: F.groupA,
      title: 'Poubelles',
      createdBy: F.me,
      createdAt: now,
      updatedAt: now,
      dueAt: F.date(2026, 9, 26, 20),
      recurrence: makeRule({ frequency: 'weekly', timeZoneId: 'Europe/Paris' }),
      rotation: [lucas.id, camille.id],
      turnUserId: camille.id,
    });
    const state = makeEditorState({ kind: 'edit', task }, now, F.parisCalendar);
    expect(rotationEditorEntries(state, members, F.me).map((entry) => entry.badge)).toEqual([null, 'C’est ton tour', null]);
    expect(rotationEditorEntries(state, members, lucas.id).map((entry) => entry.badge)).toEqual([null, 'C’est son tour', null]);
    expect(validateEditor(state).rotation).toBeNull();
  });

  it('validates in the server’s order, with French messages', () => {
    let state = setFrequency(createState(), 'daily');
    state = { ...state, hasDueDate: false, title: '  ' };
    state = setRotationEnabled(state, true, [member(camille)]);
    const errors = validateEditor(state);
    expect(errors.title).toBe('Le titre doit contenir entre 1 et 200 caractères.');
    expect(errors.recurrence).toBe('Choisis une échéance pour répéter la tâche.');
    expect(errors.rotation).toBe('Le tour de rôle demande de 2 à 20 membres du groupe.');
    for (const message of Object.values(errors)) if (message) expect(typographyProblems(message)).toEqual([]);
  });

  it('builds the initial checklist', () => {
    let state = createState();
    expect(addChecklistItem(state, '   ').error).toBe('Un élément doit contenir entre 1 et 200 caractères.');
    for (let index = 0; index < 30; index += 1) state = addChecklistItem(state, ` Élément ${index} `).state;
    expect(state.checklist[0]?.title).toBe('Élément 0');
    expect(addChecklistItem(state, 'Un de trop').error).toBe('30 éléments au maximum.');
    expect(editorDraft(state).checklist).toHaveLength(30);
  });

  it('refuses a 21st assignee', () => {
    let state = createState();
    for (let index = 0; index < 20; index += 1) state = toggleAssignee(state, F.uuid(index + 1)).state;
    const refused = toggleAssignee(state, F.uuid(99));
    expect(refused.state).toBe(state);
    expect(refused.error).not.toBeNull();
    expect(toggleAssignee(state, F.uuid(1)).state.assigneeIds).toHaveLength(19);
  });
});
