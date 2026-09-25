import { IANAZone } from 'luxon';

import type { Instant } from './calendar';
import { civilFromDays, daysFromCivil, daysInMonth } from './civilDate';
import type { RecurrenceRule } from './models';

// Due dates of the occurrences of a recurring task (docs/CONTRACTS-V2.md §6), computed exactly like the server's
// `private.next_due_at` (Swift `NextDueCalculator`). Days are local calendar dates of the rule's time zone, and every
// occurrence keeps the local time of day of the due date it comes from. A local time that does not exist or is
// ambiguous (a daylight saving time change) is read like PostgreSQL does: a skipped time takes the offset from before
// the change, a repeated time is the later instant.

/** Most calls of `step` in one computation, the first one included (vector 26). */
export const MAX_STEPS = 10_000;

const SECONDS_PER_DAY = 86_400;

function zoneOf(rule: RecurrenceRule): IANAZone | null {
  const zone = IANAZone.create(rule.timeZoneId);
  return zone.isValid ? zone : null;
}

/** Offset of `zone` at an instant given in seconds since 1970, in seconds. */
function offset(zone: IANAZone, secondsSince1970: number): number {
  return Math.round(zone.offset(secondsSince1970 * 1000) * 60);
}

/** A local date and time of day: `day` since 1970-01-01, `time` in seconds after local midnight. */
interface LocalDateTime {
  day: number;
  time: number;
}

function localDateTime(date: Instant, zone: IANAZone): LocalDateTime {
  const seconds = date / 1000;
  const local = seconds + offset(zone, seconds);
  const day = Math.floor(local / SECONDS_PER_DAY);
  return { day, time: local - day * SECONDS_PER_DAY };
}

/** ISO weekday of a day number: 1 = Monday … 7 = Sunday (1970-01-01 was a Thursday). */
export function isoWeekday(day: number): number {
  return ((((day + 3) % 7) + 7) % 7) + 1;
}

/** The local date that follows `day` in the rule (`private.recurrence_step`). */
export function step(day: number, rule: RecurrenceRule, monthDay: number): number {
  const interval = rule.interval;
  switch (rule.frequency) {
    case 'daily':
      return day + interval;
    case 'weekly': {
      const weekdays = rule.weekdays;
      if (weekdays === null || weekdays.length === 0) return day + 7 * interval;
      const firstWeekday = Math.min(...weekdays);
      const weekday = isoWeekday(day);
      const later = weekdays.filter((candidate) => candidate > weekday);
      if (later.length > 0) return day + (Math.min(...later) - weekday);
      // monday(d) + 7 × interval + (min(W) − 1): a Sunday belongs to the week of the Monday before it.
      return day - (weekday - 1) + 7 * interval + (firstWeekday - 1);
    }
    case 'monthly': {
      const date = civilFromDays(day);
      const months = date.year * 12 + (date.month - 1) + interval;
      const year = months >= 0 ? Math.trunc(months / 12) : Math.trunc((months - 11) / 12);
      const month = months - year * 12 + 1;
      const clamped = Math.min(Math.max(monthDay, 1), daysInMonth(year, month));
      return daysFromCivil(year, month, clamped);
    }
  }
}

/**
 * The instant of the local date `day` at `time` (seconds after local midnight) in `zone`, with PostgreSQL's rules
 * for a DST change (`DetermineTimeZoneOffset`): the candidates are the local time read with the offset of the day
 * before and with the offset of the day after; when exactly one of them reads back as that local time it is the
 * answer, otherwise (a skipped or repeated local time) the later of the two.
 */
export function localInstant(day: number, time: number, zone: IANAZone): Instant {
  const local = day * SECONDS_PER_DAY + time;
  const offsetBefore = offset(zone, local - SECONDS_PER_DAY);
  const offsetAfter = offset(zone, local + SECONDS_PER_DAY);
  const before = local - offsetBefore;
  const after = local - offsetAfter;
  if (offsetBefore === offsetAfter) return before * 1000;
  const beforeHolds = offset(zone, before) === offsetBefore;
  const afterHolds = offset(zone, after) === offsetAfter;
  if (beforeHolds !== afterHolds) return (beforeHolds ? before : after) * 1000;
  return Math.max(before, after) * 1000;
}

/**
 * The due date of the occurrence created when an occurrence due at `dueAt` becomes done at `now`: with `d` and `t` the
 * local date and time of `dueAt`, `c = step(d)`, then `c = step(c)` while `c + t` is not after `now`, at most
 * `MAX_STEPS` steps in all. Missed occurrences are skipped, a slot due exactly at `now` included.
 *
 * Returns null when this device does not know the rule's time zone.
 */
export function nextDueDate(dueAt: Instant, rule: RecurrenceRule, now: Instant): Instant | null {
  const zone = zoneOf(rule);
  if (zone === null) return null;
  const local = localDateTime(dueAt, zone);
  const monthDay = rule.monthDay ?? civilFromDays(local.day).day;
  let day = step(local.day, rule, monthDay);
  let steps = 1;
  let due = localInstant(day, local.time, zone);
  while (due <= now && steps < MAX_STEPS) {
    day = step(day, rule, monthDay);
    steps += 1;
    due = localInstant(day, local.time, zone);
  }
  return due;
}

/**
 * The next `count` due dates of the series, for previews (« Prochaines fois »): first `nextDueDate`, then each
 * following one a single step after the previous (same month day for the whole series, local time of the previous
 * date). Empty when `count` ≤ 0 or the rule's time zone is unknown.
 */
export function upcomingDueDates(dueAt: Instant, rule: RecurrenceRule, now: Instant, count: number): Instant[] {
  if (count <= 0) return [];
  const zone = zoneOf(rule);
  if (zone === null) return [];
  const first = nextDueDate(dueAt, rule, now);
  if (first === null) return [];
  const monthDay = rule.monthDay ?? civilFromDays(localDateTime(dueAt, zone).day).day;
  const dates = [first];
  let previous = first;
  while (dates.length < count) {
    const local = localDateTime(previous, zone);
    previous = localInstant(step(local.day, rule, monthDay), local.time, zone);
    dates.push(previous);
  }
  return dates;
}

/** ISO weekday of `date` in the rule's time zone (UTC when unknown). */
export function localWeekday(date: Instant, rule: RecurrenceRule): number {
  return isoWeekday(localDateTime(date, zoneOf(rule) ?? IANAZone.create('UTC')).day);
}

/** Day of the month of `date` in the rule's time zone (UTC when unknown). */
export function localMonthDay(date: Instant, rule: RecurrenceRule): number {
  return civilFromDays(localDateTime(date, zoneOf(rule) ?? IANAZone.create('UTC')).day).day;
}
