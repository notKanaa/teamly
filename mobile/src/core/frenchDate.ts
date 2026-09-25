import { daysFromCivil } from './civilDate';
import type { FrenchCalendar, Instant } from './calendar';
import { capitalizingFirstLetter } from './frenchText';

// French wording of dates and times (Swift `FrenchDateFormatter` and `DateText`): « aujourd’hui à 20:00 »,
// « mardi 1er septembre 2027 ». Written by hand (no locale data), in the injected calendar's time zone.

/** Weekday names indexed by the Gregorian weekday − 1 (1 = Sunday). */
export const WEEKDAY_NAMES = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'] as const;
/** Month names indexed by month − 1. */
export const MONTH_NAMES = [
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
] as const;

function twoDigits(value: number): string {
  return value >= 0 && value < 10 ? `0${value}` : `${value}`;
}

/** 24-hour wall-clock time: `08:05`, `20:00`. */
export function formatTime(date: Instant, calendar: FrenchCalendar): string {
  const { hour, minute } = calendar.components(date);
  return `${twoDigits(hour)}:${twoDigits(minute)}`;
}

/** Full day: `jeudi 24 septembre`, `mardi 1er septembre`, with the year when `includeYear`. */
export function formatDay(date: Instant, calendar: FrenchCalendar, includeYear: boolean): string {
  const { weekday, day, month, year } = calendar.components(date);
  const dayText = day === 1 ? '1er' : `${day}`;
  let text = `${WEEKDAY_NAMES[weekday - 1]} ${dayText} ${MONTH_NAMES[month - 1]}`;
  if (includeYear) text += ` ${year}`;
  return text;
}

/**
 * Number of calendar days from `reference`'s day to `date`'s day (0 = same day, 1 = tomorrow, -1 = yesterday),
 * comparing the local calendar dates, never instants (correct on days whose midnight is skipped).
 */
export function dayOffset(date: Instant, reference: Instant, calendar: FrenchCalendar): number {
  const a = calendar.components(reference);
  const b = calendar.components(date);
  return daysFromCivil(b.year, b.month, b.day) - daysFromCivil(a.year, a.month, a.day);
}

function fullDay(date: Instant, reference: Instant, calendar: FrenchCalendar): string {
  const sameYear = calendar.components(date).year === calendar.components(reference).year;
  return formatDay(date, calendar, !sameYear);
}

/**
 * Day relative to `reference`: `aujourd’hui`, `demain`, `hier`, the weekday alone 2 to 6 days ahead, otherwise the
 * full day (with the year when it differs). Lowercase.
 */
export function relativeDay(date: Instant, reference: Instant, calendar: FrenchCalendar): string {
  const offset = dayOffset(date, reference, calendar);
  if (offset === 0) return 'aujourd’hui';
  if (offset === 1) return 'demain';
  if (offset === -1) return 'hier';
  if (offset >= 2 && offset <= 6) return WEEKDAY_NAMES[calendar.components(date).weekday - 1]!;
  return fullDay(date, reference, calendar);
}

/** `aujourd’hui à 20:00`, `lundi à 09:00`, `jeudi 1er octobre à 09:00`. Lowercase. */
export function relativeDateTime(date: Instant, reference: Instant, calendar: FrenchCalendar): string {
  return `${relativeDay(date, reference, calendar)} à ${formatTime(date, calendar)}`;
}

/** For the middle of a sentence: `hier à 09:30`, otherwise `le lundi 14 septembre à 10:00`. Lowercase. */
export function relativeDateTimeInSentence(date: Instant, reference: Instant, calendar: FrenchCalendar): string {
  const offset = dayOffset(date, reference, calendar);
  if (offset >= -1 && offset <= 1) return relativeDateTime(date, reference, calendar);
  return `le ${fullDay(date, reference, calendar)} à ${formatTime(date, calendar)}`;
}

/** « Aujourd’hui à 20:00 », « Demain à 18:00 », « Lundi à 18:00 », « Jeudi 1er octobre à 18:00 » (`DateText.relative`). */
export function relativeDateText(date: Instant, now: Instant, calendar: FrenchCalendar): string {
  return capitalizingFirstLetter(relativeDateTime(date, now, calendar));
}
