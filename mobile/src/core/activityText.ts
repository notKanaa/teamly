import type { FrenchCalendar, Instant } from './calendar';
import { dayOffset, formatDay } from './frenchDate';
import { capitalizingFirstLetter, dePrefix, ordinal, isSingular, quoted } from './frenchText';
import type { ActivityEvent } from './models';
import type { Uuid } from './uuid';

/** A short French text whose people are emphasized: the view draws the emphasized runs in bold. */
export interface TextRun {
  text: string;
  isEmphasized: boolean;
}

export type EmphasizedText = TextRun[];

function run(text: string, isEmphasized = false): TextRun {
  return { text, isEmphasized };
}

/** The whole text, without emphasis (accessibility). */
export function plainText(text: EmphasizedText): string {
  return text.map((part) => part.text).join('');
}

/** The emphasized parts, in order. */
export function emphasizedParts(text: EmphasizedText): string[] {
  return text.filter((part) => part.isEmphasized).map((part) => part.text);
}

// MARK: - Activity feed (docs/CONTRACTS-V2.md §7, Swift `ActivityText`)

/** Someone the app does not know (any more), at the start of a sentence. */
export const FORMER_MEMBER = 'Un ancien membre';
/** The author of an account deletion. */
export const DELETED_ACCOUNT_MEMBER = 'Un membre';

type Person = { kind: 'me' } | { kind: 'member'; name: string } | { kind: 'former' };

function person(id: Uuid | null, me: Uuid, names: ReadonlyMap<Uuid, string>): Person {
  if (id === null) return { kind: 'former' };
  if (id === me) return { kind: 'me' };
  const name = names.get(id);
  return name ? { kind: 'member', name } : { kind: 'former' };
}

/** At the start of a sentence: « Tu », « Lucas », « Un ancien membre ». */
function subjectForm(who: Person): string {
  switch (who.kind) {
    case 'me':
      return 'Tu';
    case 'member':
      return who.name;
    case 'former':
      return FORMER_MEMBER;
  }
}

/** Inside a sentence: « toi », « Lucas », « un ancien membre ». */
function objectForm(who: Person): string {
  switch (who.kind) {
    case 'me':
      return 'toi';
    case 'member':
      return who.name;
    case 'former':
      return 'un ancien membre';
  }
}

/** « Tu as créé … », « Lucas a créé … »: the subject emphasized, then the verb in the passé composé. */
function sentence(subject: Person, participle: string, rest: string): EmphasizedText {
  return [run(subjectForm(subject), true), run(` ${subject.kind === 'me' ? 'as' : 'a'} ${participle}${rest}`)];
}

function memberLeft(event: ActivityEvent, me: Uuid, names: ReadonlyMap<Uuid, string>): EmphasizedText {
  const { actorId, subjectId } = event;
  if (actorId === null && subjectId === null) {
    return [run(DELETED_ACCOUNT_MEMBER, true), run(' a supprimé son compte')];
  }
  if (actorId !== null && subjectId !== null && actorId === subjectId) {
    return sentence(person(subjectId, me, names), 'quitté', ' le groupe');
  }
  if (actorId === null) {
    // Removed by someone whose account was deleted since (or by a trusted context).
    return sentence(person(subjectId, me, names), 'été retiré', ' du groupe');
  }
  const actor = person(actorId, me, names);
  const subject = person(subjectId, me, names);
  if (subject.kind === 'me') {
    return [run(subjectForm(actor), true), run(' t’a retiré du groupe')];
  }
  return [
    run(subjectForm(actor), true),
    run(` ${actor.kind === 'me' ? 'as' : 'a'} retiré `),
    run(objectForm(subject), true),
    run(' du groupe'),
  ];
}

/**
 * The sentence of one event, its people emphasized. People are « Tu » for the current user, their short name (from
 * `names`) for a current member, and « Un ancien membre » for anyone else.
 */
export function activityText(event: ActivityEvent, currentUserId: Uuid, names: ReadonlyMap<Uuid, string>): EmphasizedText {
  const actor = person(event.actorId, currentUserId, names);
  const task = event.taskTitle === null ? null : quoted(event.taskTitle);
  switch (event.kind) {
    case 'task_created':
      return sentence(actor, 'créé', ` ${task ?? 'une tâche'}`);
    case 'task_completed':
      return sentence(actor, 'terminé', ` ${task ?? 'une tâche'}`);
    case 'checklist_item_done': {
      const item = event.itemTitle === null ? null : quoted(event.itemTitle);
      if (item !== null && task !== null) return sentence(actor, 'coché', ` ${item} dans ${task}`);
      if (item !== null) return sentence(actor, 'coché', ` ${item}`);
      if (task !== null) return sentence(actor, 'coché un élément de', ` ${task}`);
      return sentence(actor, 'coché', ' un élément');
    }
    case 'turn_started': {
      const holder = person(event.subjectId, currentUserId, names);
      const rest = task === null ? '' : ` pour ${task}`;
      if (holder.kind === 'me') return [run('C’est '), run('ton tour', true), run(rest)];
      const name = objectForm(holder);
      return [run(`C’est au tour ${dePrefix(name)}`), run(name, true), run(rest)];
    }
    case 'member_joined':
      return sentence(person(event.subjectId ?? event.actorId, currentUserId, names), 'rejoint', ' le groupe');
    case 'member_left':
      return memberLeft(event, currentUserId, names);
  }
}

/**
 * Title of a day of the feed: « Aujourd’hui », « Hier », then « Lundi 21 septembre » (with the year when it is not the
 * year of `now`). A later day (a device clock behind the server) reads « Aujourd’hui ».
 */
export function activityDayTitle(date: Instant, now: Instant, calendar: FrenchCalendar): string {
  const offset = dayOffset(date, now, calendar);
  if (offset >= 0) return 'Aujourd’hui';
  if (offset === -1) return 'Hier';
  const sameYear = calendar.components(date).year === calendar.components(now).year;
  return capitalizingFirstLetter(formatDay(date, calendar, !sameYear));
}

// MARK: - Weekly recap card (docs/CONTRACTS-V2.md §8, Swift `RecapText`)

export const RECAP_TITLE = 'Cette semaine';
export const RECAP_EMPTY_MESSAGE = 'Aucune tâche terminée cette semaine pour l’instant.';

const MONTHS = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre',
];
const WEEKDAYS = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'];

/**
 * The week of the recap: « Du lundi 21 au dimanche 27 septembre », « Du lundi 28 septembre au dimanche 4 octobre »,
 * « Du lundi 29 décembre 2025 au dimanche 4 janvier 2026 ».
 * `weekEnd` is the exclusive end of the week (the next Monday 00:00).
 */
export function recapRange(weekStart: Instant, weekEnd: Instant, calendar: FrenchCalendar): string {
  const sunday = calendar.addingDays(-1, weekEnd);
  const start = calendar.components(weekStart);
  const end = calendar.components(sunday);
  const dayNumber = (day: number) => (day === 1 ? '1er' : `${day}`);
  const from = `${WEEKDAYS[start.weekday - 1]} ${dayNumber(start.day)}`;
  const to = `${WEEKDAYS[end.weekday - 1]} ${dayNumber(end.day)} ${MONTHS[end.month - 1]}`;
  if (start.year !== end.year) return `Du ${from} ${MONTHS[start.month - 1]} ${start.year} au ${to} ${end.year}`;
  if (start.month !== end.month) return `Du ${from} ${MONTHS[start.month - 1]} au ${to}`;
  return `Du ${from} au ${to}`;
}

/** The label under the total: « tâches faites », « tâche faite » (0 and 1). */
export function recapTotalLabel(total: number): string {
  return isSingular(total) ? 'tâche faite' : 'tâches faites';
}

/** A place of the podium: « 1re », « 2e », « 3e ». */
export function recapPlace(place: number): string {
  return ordinal(place);
}

/** « Inès mène pour la 3e semaine d’affilée. » / « Tu mènes pour la 3e semaine d’affilée. », the leader emphasized. */
export function recapStreak(name: string, isMe: boolean, weeks: number): EmphasizedText {
  const week = `pour la ${ordinal(weeks)} semaine d’affilée.`;
  return [run(isMe ? 'Tu' : name, true), run(isMe ? ` mènes ${week}` : ` mène ${week}`)];
}
