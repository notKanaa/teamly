import { DateTime } from 'luxon';

import { AppError } from './appError';
import type { FrenchCalendar, Instant } from './calendar';
import { relativeDateText } from './frenchDate';
import { capitalizingFirstLetter } from './frenchText';
import { trimmed, validateChecklist, validateChecklistItemTitle, validateDueDate, validateRecurrence, validateRotation, validateTaskDetails, validateTaskTitle } from './inputValidation';
import { Limits } from './limits';
import {
  draftFromTask,
  makeDraft,
  makeRule,
  type Frequency,
  type Membership,
  type RecurrenceRule,
  type TaskDraft,
  type TaskItem,
  type TaskPriority,
} from './models';
import { localWeekday, upcomingDueDates } from './nextDue';
import { MemberDirectory, type PersonBadge } from './presentation';
import { compareNames, sortedMembers } from './nameOrder';
import { ISO_WEEKDAY_NAMES, recurrenceDescription } from './recurrenceText';
import { compareUuids, type Uuid } from './uuid';

// « Nouvelle tâche » / « Modifier la tâche » (Swift `TaskEditorViewModel`), as pure functions over an immutable state.
// v2 (docs/CONTRACTS-V2.md §5, §6): « Répéter », « À tour de rôle » and the initial checklist.

export const TASK_EDITOR_TEXTS = {
  createTitle: 'Nouvelle tâche',
  editTitle: 'Modifier la tâche',
  createButton: 'Créer',
  editButton: 'Enregistrer',
  invalidDueDate: 'Date d’échéance invalide.',
  gone: 'Cette tâche a été supprimée.',
  recurrenceHint: 'Dès que la tâche est faite, la suivante est créée.',
  dueDateRequired: 'Une tâche qui se répète a toujours une échéance.',
  rotationTitle: 'À tour de rôle',
  rotationSubtitle: 'Une personne à la fois, dans cet ordre.',
  rotationStarts: 'Commence',
  rotationTurn: 'C’est son tour',
  rotationMyTurn: 'C’est ton tour',
  checklistTitle: 'Checklist',
  addChecklistItem: 'Ajouter un élément',
  discardTitle: 'Abandonner les modifications\u{a0}?',
  discardMessage: 'Les changements apportés à cette tâche seront perdus.',
  upcomingTitle: 'Prochaines fois',
} as const;

/** Letters of the weekday circles, Monday first. */
export const WEEKDAY_LETTERS = ['L', 'M', 'M', 'J', 'V', 'S', 'D'] as const;

export type RepeatFrequency = 'never' | Frequency;
export const REPEAT_FREQUENCIES: readonly RepeatFrequency[] = ['never', 'daily', 'weekly', 'monthly'];

/** « Jamais », « Jour », « Semaine », « Mois ». */
export function repeatFrequencyLabel(frequency: RepeatFrequency): string {
  switch (frequency) {
    case 'never':
      return 'Jamais';
    case 'daily':
      return 'Jour';
    case 'weekly':
      return 'Semaine';
    case 'monthly':
      return 'Mois';
  }
}

/** « jour(s) », « semaine(s) », « mois », after the interval of the stepper (« Tous les 2 jours »). */
export function intervalUnit(frequency: Frequency, interval: number): string {
  const plural = interval > 1;
  switch (frequency) {
    case 'daily':
      return plural ? 'jours' : 'jour';
    case 'weekly':
      return plural ? 'semaines' : 'semaine';
    case 'monthly':
      return 'mois';
  }
}

export type EditorMode = { kind: 'create'; groupId: Uuid } | { kind: 'edit'; task: TaskItem };

export interface ChecklistDraftItem {
  key: string;
  title: string;
}

export interface TaskEditorState {
  mode: EditorMode;
  /** The draft the editor started from: what is sent for everything not changed here. */
  original: TaskDraft;
  /** Zone of a new rule (the device's). */
  timeZoneId: string;
  title: string;
  details: string;
  priority: TaskPriority;
  hasDueDate: boolean;
  /** The picker's value, used when `hasDueDate`. */
  dueDate: Instant;
  frequency: RepeatFrequency;
  interval: number;
  /** The explicit weekdays of a weekly rule; null = the due date's weekday. */
  weekdays: number[] | null;
  rotationEnabled: boolean;
  /** The rotation sent: the task's own list until the user changes it. */
  rotation: Uuid[];
  assigneeIds: Uuid[];
  checklist: ChecklistDraftItem[];
  nextChecklistKey: number;
}

/** Tomorrow at 18:00 in `calendar`'s time zone. */
export function defaultDueDate(now: Instant, calendar: FrenchCalendar): Instant {
  const { year, month, day } = calendar.components(calendar.addingDays(1, calendar.startOfDay(now)));
  return calendar.date(year, month, day, 18, 0);
}

export function makeEditorState(
  mode: EditorMode,
  now: Instant,
  calendar: FrenchCalendar,
  initialAssignees: readonly Uuid[] = [],
): TaskEditorState {
  const original = mode.kind === 'edit' ? draftFromTask(mode.task) : makeDraft({ assigneeIds: [...initialAssignees] });
  return {
    mode,
    original,
    timeZoneId: calendar.zone,
    title: original.title,
    details: original.details,
    priority: original.priority,
    hasDueDate: original.dueAt !== null,
    dueDate: original.dueAt ?? defaultDueDate(now, calendar),
    frequency: original.recurrence?.frequency ?? 'never',
    interval: original.recurrence?.interval ?? 1,
    weekdays: original.recurrence?.weekdays ? [...original.recurrence.weekdays] : null,
    rotationEnabled: original.rotation.length > 0,
    rotation: [...original.rotation],
    assigneeIds: [...original.assigneeIds],
    checklist: [],
    nextChecklistKey: 1,
  };
}

export function isEditing(state: TaskEditorState): boolean {
  return state.mode.kind === 'edit';
}

export function editorTitle(state: TaskEditorState): string {
  return isEditing(state) ? TASK_EDITOR_TEXTS.editTitle : TASK_EDITOR_TEXTS.createTitle;
}

export function saveButtonTitle(state: TaskEditorState): string {
  return isEditing(state) ? TASK_EDITOR_TEXTS.editButton : TASK_EDITOR_TEXTS.createButton;
}

export function canSave(state: TaskEditorState): boolean {
  return trimmed(state.title) !== '';
}

// MARK: - Due date and repetition

export function isRecurring(state: TaskEditorState): boolean {
  return state.frequency !== 'never';
}

/** Choosing a frequency turns the due date on (a repetition needs one). */
export function setFrequency(state: TaskEditorState, frequency: RepeatFrequency): TaskEditorState {
  return { ...state, frequency, hasDueDate: frequency !== 'never' ? true : state.hasDueDate };
}

export function setInterval(state: TaskEditorState, interval: number): TaskEditorState {
  return { ...state, interval: Math.min(Math.max(Math.round(interval), 1), Limits.repeatIntervalMax) };
}

function ruleZone(state: TaskEditorState): string {
  return state.original.recurrence?.timeZoneId ?? state.timeZoneId;
}

/** The due date's weekday in the rule's time zone, null without due date. */
function implicitWeekday(state: TaskEditorState): number | null {
  if (!state.hasDueDate) return null;
  return localWeekday(state.dueDate, makeRule({ frequency: 'weekly', timeZoneId: ruleZone(state) }));
}

export function selectedWeekdays(state: TaskEditorState): number[] {
  if (state.weekdays !== null) return state.weekdays;
  const implicit = implicitWeekday(state);
  return implicit === null ? [] : [implicit];
}

export interface WeekdayOption {
  /** ISO weekday: 1 = Monday … 7 = Sunday. */
  id: number;
  letter: string;
  /** « Lundi » (accessibility). */
  name: string;
  isSelected: boolean;
}

export function weekdayOptions(state: TaskEditorState): WeekdayOption[] {
  const selected = selectedWeekdays(state);
  return [1, 2, 3, 4, 5, 6, 7].map((day) => ({
    id: day,
    letter: WEEKDAY_LETTERS[day - 1]!,
    name: capitalizingFirstLetter(ISO_WEEKDAY_NAMES[day - 1]!),
    isSelected: selected.includes(day),
  }));
}

/**
 * Adds or removes a day of a weekly rule (one day at least stays). Back to the due date's weekday alone, the rule
 * follows the due date again (unless the task's rule listed its days).
 */
export function toggleWeekday(state: TaskEditorState, weekday: number): TaskEditorState {
  if (weekday < 1 || weekday > 7) return state;
  let days = selectedWeekdays(state);
  if (days.includes(weekday)) {
    if (days.length <= 1) return state;
    days = days.filter((day) => day !== weekday);
  } else {
    days = [...days, weekday].sort((a, b) => a - b);
  }
  const implicit = implicitWeekday(state);
  const followsDueDate = state.original.recurrence?.weekdays == null && implicit !== null && days.length === 1 && days[0] === implicit;
  return { ...state, weekdays: followsDueDate ? null : days };
}

/**
 * The draft's rule, null for « Jamais ». It starts from the task's rule, whose time zone is kept; a new rule takes the
 * device's zone. The server's month day is kept while the rule stays monthly on the same local due date.
 */
export function draftRule(state: TaskEditorState): RecurrenceRule | null {
  if (state.frequency === 'never') return null;
  const base = state.original.recurrence;
  const zoneId = ruleZone(state);
  const weekdays = state.frequency === 'weekly' ? state.weekdays : null;
  let monthDay = base?.monthDay ?? null;
  const dueAt = state.hasDueDate ? state.dueDate : null;
  const localDate = (date: Instant | null) => (date === null ? null : DateTime.fromMillis(date, { zone: zoneId }).toISODate());
  const sameLocalDate = localDate(dueAt) === localDate(state.original.dueAt);
  if (state.frequency !== 'monthly' || base?.frequency !== 'monthly' || !sameLocalDate) monthDay = null;
  return makeRule({ frequency: state.frequency, interval: state.interval, weekdays, timeZoneId: zoneId, monthDay });
}

/** « Chaque semaine, le samedi »; null for « Jamais ». */
export function editorRecurrenceSummary(state: TaskEditorState): string | null {
  const rule = draftRule(state);
  return rule === null ? null : recurrenceDescription(rule, state.hasDueDate ? state.dueDate : null);
}

/** The first dates of the series: the due date, then the next occurrences (« Prochaines fois »). */
export function editorUpcomingDates(state: TaskEditorState, count = 3): Instant[] {
  const rule = draftRule(state);
  if (rule === null || !state.hasDueDate || count <= 0) return [];
  return [state.dueDate, ...upcomingDueDates(state.dueDate, rule, state.dueDate, count - 1)];
}

export function editorUpcomingTexts(state: TaskEditorState, now: Instant, calendar: FrenchCalendar, count = 3): string[] {
  return editorUpcomingDates(state, count).map((date) => relativeDateText(date, now, calendar));
}

// MARK: - Assignees

/** Adds or removes an assignee; adding beyond 20 is refused with its message. */
export function toggleAssignee(state: TaskEditorState, userId: Uuid): { state: TaskEditorState; error: string | null } {
  if (state.assigneeIds.includes(userId)) {
    return { state: { ...state, assigneeIds: state.assigneeIds.filter((id) => id !== userId) }, error: null };
  }
  if (state.assigneeIds.length >= Limits.maxAssignees) {
    return { state, error: new AppError('tooManyAssignees').messageFR };
  }
  return { state: { ...state, assigneeIds: [...state.assigneeIds, userId] }, error: null };
}

/** Drops the selected people who are no longer members (the server would refuse them). */
export function keepingMembers(state: TaskEditorState, members: readonly Membership[]): TaskEditorState {
  const ids = new Set(members.map((member) => member.user.id));
  const assigneeIds = state.assigneeIds.filter((id) => ids.has(id));
  const originalAssignees = state.original.assigneeIds.filter((id) => ids.has(id));
  if (assigneeIds.length === state.assigneeIds.length && originalAssignees.length === state.original.assigneeIds.length) return state;
  return { ...state, assigneeIds, original: { ...state.original, assigneeIds: originalAssignees } };
}

// MARK: - Rotation

/** The rotation switch is offered while the task repeats. */
export function canUseRotation(state: TaskEditorState): boolean {
  return isRecurring(state);
}

export function showsRotation(state: TaskEditorState): boolean {
  return isRecurring(state) && state.rotationEnabled;
}

function membersByName(members: readonly Membership[]): Membership[] {
  return [...members].sort((lhs, rhs) => compareNames(lhs.user.displayName, rhs.user.displayName) || compareUuids(lhs.user.id, rhs.user.id));
}

/** The current assignees first, then the other members, each by name; at most 20. */
export function defaultRotation(state: TaskEditorState, members: readonly Membership[]): Uuid[] {
  const byName = membersByName(members).map((member) => member.user.id);
  const assigned = byName.filter((id) => state.assigneeIds.includes(id));
  const others = byName.filter((id) => !state.assigneeIds.includes(id));
  return [...assigned, ...others].slice(0, Limits.rotationMax);
}

export function setRotationEnabled(state: TaskEditorState, enabled: boolean, members: readonly Membership[]): TaskEditorState {
  const rotation = enabled && state.rotation.length === 0 ? defaultRotation(state, members) : state.rotation;
  return { ...state, rotationEnabled: enabled, rotation };
}

function includedRotation(state: TaskEditorState, members: readonly Membership[]): Uuid[] {
  const ids = new Set(members.map((member) => member.user.id));
  return state.rotation.filter((id) => ids.has(id));
}

export interface RotationEditorEntry {
  person: PersonBadge;
  isIncluded: boolean;
  /** 1-based place, null when not included. */
  position: number | null;
  /** « Commence », « C’est son tour », « C’est ton tour »; null for the others. */
  badge: string | null;
}

/** The members in the rotation, in turn order, then the others (to add). */
export function rotationEditorEntries(state: TaskEditorState, members: readonly Membership[], userId: Uuid): RotationEditorEntry[] {
  const directory = new MemberDirectory(members, userId);
  const included = includedRotation(state, members);
  const turn = state.mode.kind === 'edit' ? state.mode.task.turnUserId : null;
  const holder = turn !== null && included.includes(turn) ? { id: turn, current: true } : included[0] ? { id: included[0], current: false } : null;
  const badgeOf = (id: Uuid): string | null => {
    if (holder === null || holder.id !== id) return null;
    if (!holder.current) return TASK_EDITOR_TEXTS.rotationStarts;
    return id === userId ? TASK_EDITOR_TEXTS.rotationMyTurn : TASK_EDITOR_TEXTS.rotationTurn;
  };
  const entries: RotationEditorEntry[] = included.map((id, index) => ({
    person: directory.badge(id),
    isIncluded: true,
    position: index + 1,
    badge: badgeOf(id),
  }));
  const includedIds = new Set(included);
  for (const member of membersByName(members)) {
    if (includedIds.has(member.user.id)) continue;
    entries.push({ person: directory.badge(member.user.id), isIncluded: false, position: null, badge: null });
  }
  return entries;
}

/** Moves someone one place earlier (−1) or later (+1). */
export function moveRotationMember(state: TaskEditorState, userId: Uuid, offset: number, members: readonly Membership[]): TaskEditorState {
  const included = includedRotation(state, members);
  const index = included.indexOf(userId);
  const target = index + offset;
  if (index < 0 || target < 0 || target >= included.length) return state;
  const next = [...included];
  [next[index], next[target]] = [next[target]!, next[index]!];
  return { ...state, rotation: next };
}

/** Adds a member at the end of the rotation, or takes them out (20 people at most). */
export function toggleRotationMember(
  state: TaskEditorState,
  userId: Uuid,
  members: readonly Membership[],
): { state: TaskEditorState; error: string | null } {
  const included = includedRotation(state, members);
  if (included.includes(userId)) return { state: { ...state, rotation: included.filter((id) => id !== userId) }, error: null };
  if (!members.some((member) => member.user.id === userId)) return { state, error: null };
  if (included.length >= Limits.rotationMax) return { state, error: new AppError('invalidRotation').messageFR };
  return { state: { ...state, rotation: [...included, userId] }, error: null };
}

// MARK: - Checklist (creation only)

export function showsChecklist(state: TaskEditorState): boolean {
  return !isEditing(state);
}

/** Adds a trimmed item at the end; a refused title or a full list gives its message. */
export function addChecklistItem(state: TaskEditorState, raw: string): { state: TaskEditorState; error: string | null } {
  let title: string;
  try {
    title = validateChecklistItemTitle(raw);
  } catch {
    return { state, error: new AppError('invalidChecklistItem').messageFR };
  }
  if (state.checklist.length >= Limits.checklistItemsMax) return { state, error: new AppError('tooManyChecklistItems').messageFR };
  return {
    state: {
      ...state,
      checklist: [...state.checklist, { key: `item-${state.nextChecklistKey}`, title }],
      nextChecklistKey: state.nextChecklistKey + 1,
    },
    error: null,
  };
}

export function removeChecklistItem(state: TaskEditorState, key: string): TaskEditorState {
  return { ...state, checklist: state.checklist.filter((item) => item.key !== key) };
}

// MARK: - Draft and validation

export function editorDraft(state: TaskEditorState): TaskDraft {
  return {
    ...state.original,
    title: state.title,
    details: state.details,
    priority: state.priority,
    dueAt: state.hasDueDate ? state.dueDate : null,
    assigneeIds: [...state.assigneeIds],
    recurrence: draftRule(state),
    rotation: showsRotation(state) ? [...state.rotation] : [],
    checklist: isEditing(state) ? [] : state.checklist.map((item) => item.title),
  };
}

function sameDraft(lhs: TaskDraft, rhs: TaskDraft): boolean {
  const sorted = (ids: readonly Uuid[]) => [...ids].sort().join(',');
  return (
    lhs.title === rhs.title &&
    lhs.details === rhs.details &&
    lhs.priority === rhs.priority &&
    lhs.dueAt === rhs.dueAt &&
    sorted(lhs.assigneeIds) === sorted(rhs.assigneeIds) &&
    JSON.stringify(lhs.recurrence) === JSON.stringify(rhs.recurrence) &&
    lhs.rotation.join(',') === rhs.rotation.join(',') &&
    lhs.checklist.join('\n') === rhs.checklist.join('\n')
  );
}

/** Something differs from the initial values (ask before discarding). */
export function hasChanges(state: TaskEditorState): boolean {
  return !sameDraft(editorDraft(state), state.original);
}

export interface EditorErrors {
  title: string | null;
  details: string | null;
  dueDate: string | null;
  recurrence: string | null;
  rotation: string | null;
  assignees: string | null;
  checklist: string | null;
}

export const NO_EDITOR_ERRORS: EditorErrors = {
  title: null,
  details: null,
  dueDate: null,
  recurrence: null,
  rotation: null,
  assignees: null,
  checklist: null,
};

function message(check: () => unknown): string | null {
  try {
    check();
    return null;
  } catch (error) {
    return AppError.wrap(error).messageFR;
  }
}

/** Checks every field (same order as the server) and gives their messages. */
export function validateEditor(state: TaskEditorState): EditorErrors {
  const rule = draftRule(state);
  const dueAt = state.hasDueDate ? state.dueDate : null;
  const draft = editorDraft(state);
  let rotation: string | null;
  if (showsRotation(state) && draft.rotation.length < Limits.rotationMin) rotation = new AppError('invalidRotation').messageFR;
  else if (isEditing(state) && draft.rotation.join(',') === state.original.rotation.join(',')) rotation = null;
  else rotation = message(() => validateRotation(draft.rotation, rule));
  return {
    title: message(() => validateTaskTitle(state.title)),
    details: message(() => validateTaskDetails(state.details)),
    dueDate: state.hasDueDate && message(() => validateDueDate(state.dueDate)) !== null ? TASK_EDITOR_TEXTS.invalidDueDate : null,
    recurrence: message(() => validateRecurrence(rule, dueAt)),
    rotation,
    assignees:
      draft.rotation.length === 0 && state.assigneeIds.length > Limits.maxAssignees ? new AppError('tooManyAssignees').messageFR : null,
    checklist: isEditing(state) ? null : message(() => validateChecklist(draft.checklist)),
  };
}

export function hasEditorErrors(errors: EditorErrors): boolean {
  return Object.values(errors).some((value) => value !== null);
}

/** The field of a server error (the others go to the general error). */
export function editorErrorField(error: unknown): keyof EditorErrors | null {
  if (!AppError.isAppError(error)) return null;
  switch (error.kind) {
    case 'invalidTitle':
      return 'title';
    case 'invalidDetails':
      return 'details';
    case 'tooManyAssignees':
    case 'assigneeNotMember':
      return 'assignees';
    case 'invalidRecurrence':
    case 'recurrenceNeedsDueDate':
      return 'recurrence';
    case 'invalidRotation':
      return 'rotation';
    case 'invalidChecklistItem':
    case 'tooManyChecklistItems':
      return 'checklist';
    default:
      return null;
  }
}

/** Assignee choices: the group's members (admins first, then by name), « Camille Martin (toi) » for the user. */
export interface AssigneeOption {
  id: Uuid;
  name: string;
  isMe: boolean;
  isSelected: boolean;
  isAdmin: boolean;
}

export function assigneeOptions(state: TaskEditorState, members: readonly Membership[], userId: Uuid): AssigneeOption[] {
  return sortedMembers(members).map((member) => {
    const isMe = member.user.id === userId;
    return {
      id: member.user.id,
      name: isMe ? `${member.user.displayName} (toi)` : member.user.displayName,
      isMe,
      isSelected: state.assigneeIds.includes(member.user.id),
      isAdmin: member.role === 'admin',
    };
  });
}
