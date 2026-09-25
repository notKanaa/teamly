import type { FrenchCalendar, Instant } from './calendar';
import { relativeDateText, relativeDateTimeInSentence } from './frenchDate';
import { de } from './frenchText';
import type { Membership, TaskItem } from './models';
import { upcomingDueDates } from './nextDue';
import { MemberDirectory, ME_NAME, type PersonBadge } from './presentation';
import { recurrenceDescription } from './recurrenceText';
import type { Uuid } from './uuid';

// The task screen (Swift `TaskDetailViewModel`), as pure functions over the loaded task and members.

export const TASK_GONE_MESSAGE = 'Cette tâche n’existe plus.';
export const UPCOMING_TITLE = 'Prochaines fois';
export const UPCOMING_COUNT = 3;
export const CHECKLIST_TITLE = 'Checklist';
export const ADD_CHECKLIST_ITEM_TITLE = 'Ajouter un élément';

/** « Chaque semaine, le samedi », « Chaque mois, le 25 »; null for a plain task. */
export function taskRecurrenceText(task: TaskItem): string | null {
  return task.recurrence === null ? null : recurrenceDescription(task.recurrence, task.dueAt);
}

/** The due dates of the next occurrences, as the server would create them; empty for a plain or done task. */
export function taskUpcomingDueDates(task: TaskItem, now: Instant): Instant[] {
  if (task.status === 'done' || task.recurrence === null || task.dueAt === null) return [];
  return upcomingDueDates(task.dueAt, task.recurrence, now, UPCOMING_COUNT);
}

/** « Samedi 3 octobre à 11:00 », for « Prochaines fois ». */
export function taskUpcomingDueTexts(task: TaskItem, now: Instant, calendar: FrenchCalendar): string[] {
  return taskUpcomingDueDates(task, now).map((date) => relativeDateText(date, now, calendar));
}

/** A person of a task's rotation, in turn order. */
export interface RotationEntry {
  person: PersonBadge;
  isCurrentTurn: boolean;
}

/** The rotation's current members in turn order, starting with the current turn holder; empty without rotation. */
export function rotationEntries(task: TaskItem, members: readonly Membership[], userId: Uuid): RotationEntry[] {
  if (task.rotation.length === 0) return [];
  const directory = new MemberDirectory(members, userId);
  const memberIds = new Set(members.map((member) => member.user.id));
  let order = [...task.rotation];
  const index = task.turnUserId === null ? -1 : order.indexOf(task.turnUserId);
  if (index >= 0) order = [...order.slice(index), ...order.slice(0, index)];
  return order
    .filter((id) => memberIds.has(id))
    .map((id) => ({ person: directory.badge(id), isCurrentTurn: id === task.turnUserId }));
}

function turnName(person: PersonBadge): string {
  return person.isMe ? 'toi' : person.shortName;
}

/** « C’est au tour de Lucas, puis Camille, puis Inès. », « C’est ton tour, puis Lucas. »; null without rotation. */
export function rotationText(entries: readonly RotationEntry[]): string | null {
  const first = entries[0];
  if (first === undefined) return null;
  let head: string;
  if (!first.isCurrentTurn) head = `Tour de rôle\u{a0}: ${turnName(first.person)}`;
  else if (first.person.isMe) head = 'C’est ton tour';
  else head = `C’est au tour ${de(first.person.shortName)}`;
  const rest = entries
    .slice(1)
    .map((entry) => `, puis ${turnName(entry.person)}`)
    .join('');
  return `${head}${rest}.`;
}

/** « Créée par Lucas Bernard hier à 10:00 » / « Créée par toi le lundi 14 septembre à 09:00 ». */
export function createdText(task: TaskItem, members: readonly Membership[], userId: Uuid, now: Instant, calendar: FrenchCalendar): string {
  const directory = new MemberDirectory(members, userId);
  const who = task.createdBy === userId ? 'toi' : directory.name(task.createdBy);
  return `Créée par ${who} ${relativeDateTimeInSentence(task.createdAt, now, calendar)}`;
}

/** « Terminée aujourd’hui à 09:00 », null unless done. */
export function completedText(task: TaskItem, now: Instant, calendar: FrenchCalendar): string | null {
  if (task.status !== 'done' || task.completedAt === null) return null;
  return `Terminée ${relativeDateTimeInSentence(task.completedAt, now, calendar)}`;
}

/** « Toi », the creator's name, or « Ancien membre ». */
export function creatorName(task: TaskItem, members: readonly Membership[], userId: Uuid): string {
  if (task.createdBy === userId) return ME_NAME;
  return new MemberDirectory(members, userId).name(task.createdBy);
}

/** Confirmation text of « Supprimer la tâche ». */
export function deleteTaskConfirmationMessage(title: string): string {
  return `La tâche «\u{a0}${title}\u{a0}» sera supprimée pour tous les membres du groupe.`;
}
