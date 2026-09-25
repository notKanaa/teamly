import type { Instant } from '@/core/calendar';
import { civilFromDays, daysFromCivil, daysInMonth } from '@/core/civilDate';

// `timestamptz` values as PostgREST exchanges them (docs/CONTRACTS.md §4.3), without `Date` parsing:
// - parsing accepts ISO-8601 with an offset (`Z`, `±HH`, `±HHMM`, `±HH:MM`, optional seconds) and 0 to 6 fractional
//   digits (more are rounded to the microsecond), with a `T` or a space between the date and the time;
// - formatting writes UTC with exactly 6 fractional digits (`2026-09-24T08:00:00.123456Z`), so that a timestamp read
//   from the server and sent back as a filter value designates the same instant.
// An `Instant` keeps the microseconds as the fractional part of its milliseconds.

/** Whole microseconds since 1970 of an instant (rounded to the nearest microsecond). */
export function epochMicroseconds(instant: Instant): number {
  return Math.round(instant * 1000);
}

/** The instant of a number of microseconds since 1970. */
export function instantFromMicroseconds(micros: number): Instant {
  return micros / 1000;
}

function pad(value: number, width: number): string {
  const digits = String(value);
  return digits.length >= width ? digits : '0'.repeat(width - digits.length) + digits;
}

/** UTC, 6 fractional digits, `Z` suffix. */
export function formatTimestamp(instant: Instant): string {
  const micros = epochMicroseconds(instant);
  const seconds = Math.floor(micros / 1_000_000);
  const fraction = micros - seconds * 1_000_000;
  const days = Math.floor(seconds / 86_400);
  const secondOfDay = seconds - days * 86_400;
  const { year, month, day } = civilFromDays(days);
  const hour = Math.floor(secondOfDay / 3600);
  const minute = Math.floor((secondOfDay % 3600) / 60);
  const second = secondOfDay % 60;
  return `${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}T${pad(hour, 2)}:${pad(minute, 2)}:${pad(second, 2)}.${pad(fraction, 6)}Z`;
}

const PATTERN =
  /^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:([Zz])|([+-])(\d{2})(?::?(\d{2})(?::?(\d{2}))?)?)$/;

/** The instant of a PostgREST timestamp, null when it is malformed. */
export function parseTimestamp(text: string): Instant | null {
  const match = PATTERN.exec(text);
  if (!match) return null;
  const [, y, mo, d, h, mi, s, fractionText, zulu, sign, offsetHours, offsetMinutes, offsetSeconds] = match;
  const year = Number(y);
  const month = Number(mo);
  const day = Number(d);
  const hour = Number(h);
  const minute = Number(mi);
  const second = Number(s);
  if (month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month)) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;

  let micros = 0;
  if (fractionText !== undefined) {
    const digits = fractionText.slice(0, 6).padEnd(6, '0');
    micros = Number(digits);
    // Rounded half up beyond 6 digits.
    if (fractionText.length > 6 && Number(fractionText[6]) >= 5) micros += 1;
  }

  let offset = 0;
  if (zulu === undefined) {
    if (sign === undefined || offsetHours === undefined) return null;
    const hours = Number(offsetHours);
    const minutes = offsetMinutes === undefined ? 0 : Number(offsetMinutes);
    const seconds = offsetSeconds === undefined ? 0 : Number(offsetSeconds);
    if (hours > 23 || minutes > 59 || seconds > 59) return null;
    offset = (sign === '-' ? -1 : 1) * (hours * 3600 + minutes * 60 + seconds);
  }

  const days = daysFromCivil(year, month, day);
  const totalSeconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset;
  return instantFromMicroseconds(totalSeconds * 1_000_000 + micros);
}
