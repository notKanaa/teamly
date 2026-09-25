import { AppError, type AppErrorKind } from './appError';
import type { Instant } from './calendar';
import { type ColorKey, isColorKey } from './colorKey';
import { Limits } from './limits';
import type { RecurrenceRule } from './models';
import { codePointLength, codePoints, utf8Length } from './unicode';
import type { Uuid } from './uuid';

// Input rules of docs/CONTRACTS.md §1 and docs/CONTRACTS-V2.md §1, §3, §5 (Swift `InputValidation`). The data layer
// applies them before calling the server, so the app answers like the server would, in the server's order.

/**
 * Code points trimmed at both ends of every text field (pinned list, the SQL `private.clean_text`): U+0009–U+000D,
 * U+0020, U+0085, U+00A0, U+1680, U+2000–U+200B, U+2028, U+2029, U+202F, U+205F, U+3000.
 */
export function isTrimmedCodePoint(code: number): boolean {
  return (
    (code >= 0x09 && code <= 0x0d) ||
    code === 0x20 ||
    code === 0x85 ||
    code === 0xa0 ||
    code === 0x1680 ||
    (code >= 0x2000 && code <= 0x200b) ||
    code === 0x2028 ||
    code === 0x2029 ||
    code === 0x202f ||
    code === 0x205f ||
    code === 0x3000
  );
}

/** `value` without the trimmed code points at both ends (code point by code point, like the SQL regexp). */
export function trimmed(value: string): string {
  const points = codePoints(value);
  let start = 0;
  while (start < points.length && isTrimmedCodePoint(points[start]!.codePointAt(0)!)) start += 1;
  let end = points.length;
  while (end > start && isTrimmedCodePoint(points[end - 1]!.codePointAt(0)!)) end -= 1;
  return points.slice(start, end).join('');
}

/** Postgres `text` cannot hold U+0000: such input gets the field's own error. */
function text(raw: string, min: number, max: number, error: AppErrorKind): string {
  const value = trimmed(raw);
  const length = codePointLength(value);
  if (length < min || length > max || value.includes('\u0000')) throw new AppError(error);
  return value;
}

/** Trimmed display name (1–50) or `invalidDisplayName`. */
export function validateDisplayName(raw: string): string {
  return text(raw, Limits.displayName.min, Limits.displayName.max, 'invalidDisplayName');
}

/** Trimmed group name (1–60) or `invalidName`. */
export function validateGroupName(raw: string): string {
  return text(raw, Limits.groupName.min, Limits.groupName.max, 'invalidName');
}

/** Trimmed task title (1–200) or `invalidTitle`. */
export function validateTaskTitle(raw: string): string {
  return text(raw, Limits.taskTitle.min, Limits.taskTitle.max, 'invalidTitle');
}

/** Trimmed task details (≤ 5000, null when empty) or `invalidDetails`. */
export function validateTaskDetails(raw: string): string | null {
  const value = text(raw, 0, Limits.taskDetailsMax, 'invalidDetails');
  return value === '' ? null : value;
}

/** Accepted due dates: [1970-01-01, 10000-01-01) UTC (`tasks_due_at_range`). */
export const DUE_DATE_MIN: Instant = 0;
export const DUE_DATE_END: Instant = 253_402_300_800_000;

/** null (no due date) or a date inside the accepted range, else `invalidInput` (SQL `invalid_due_at`). */
export function validateDueDate(date: Instant | null): Instant | null {
  if (date === null) return null;
  if (!(date >= DUE_DATE_MIN && date < DUE_DATE_END)) throw new AppError('invalidInput');
  return date;
}

// MARK: - Auth

/** Trimmed and lowercased e-mail (Supabase Auth stores e-mails lowercased but does not trim them). */
export function normalizedEmail(raw: string): string {
  return trimmed(raw).toLowerCase();
}

const EMAIL_LOCAL_CHARACTERS = new Set(
  Array.from("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-"),
);

function isAsciiAlphanumeric(character: string): boolean {
  return /^[A-Za-z0-9]$/.test(character);
}

function hasEmailSyntax(value: string): boolean {
  const points = codePoints(value);
  const at = points.indexOf('@');
  if (at <= 0) return false;
  if (!points.slice(0, at).every((character) => EMAIL_LOCAL_CHARACTERS.has(character))) return false;
  const labels = points.slice(at + 1).join('').split('.');
  return labels.every((label) => {
    const characters = codePoints(label);
    if (characters.length < 1 || characters.length > 63) return false;
    if (!isAsciiAlphanumeric(characters[0]!) || !isAsciiAlphanumeric(characters[characters.length - 1]!)) return false;
    return characters.every((character) => isAsciiAlphanumeric(character) || character === '-');
  });
}

/**
 * The normalized e-mail, or `invalidEmail` unless it has the HTML5 syntax Supabase Auth checks (at most 255 bytes):
 * before the `@`, ASCII letters, digits or .!#$%&'*+/=?^_`{|}~-; after it, dot-separated labels of 1–63 ASCII letters,
 * digits or hyphens, starting and ending with a letter or a digit.
 */
export function validateEmail(raw: string): string {
  const value = trimmed(raw);
  if (utf8Length(value) > Limits.emailMaxBytes || !hasEmailSyntax(value)) throw new AppError('invalidEmail');
  return value.toLowerCase();
}

/** Password length in UTF-8 bytes, like Supabase Auth: ≥ 8 (`weakPassword`), ≤ 72 (`invalidInput`). */
export function validatePassword(value: string): void {
  const bytes = utf8Length(value);
  if (bytes < Limits.passwordMinLength) throw new AppError('weakPassword');
  if (bytes > Limits.passwordMaxBytes) throw new AppError('invalidInput');
}

/** Sign-up input, checked in this order: e-mail, password, display name. */
export function validateSignUp(email: string, password: string, displayName: string): { email: string; displayName: string } {
  const checkedEmail = validateEmail(email);
  validatePassword(password);
  const name = validateDisplayName(displayName);
  return { email: checkedEmail, displayName: name };
}

// MARK: - v2: appearance

/** A color from its stored text, exact case; null = automatic. Anything else is `invalidAppearance`. */
export function validateColorKey(raw: string | null): ColorKey | null {
  if (raw === null) return null;
  if (!isColorKey(raw)) throw new AppError('invalidAppearance');
  return raw;
}

/**
 * Code points refused inside an emoji: U+0000–U+0020, U+007F–U+00A0, U+1680, U+2000–U+200B, U+2028, U+2029, U+202F,
 * U+205F, U+3000 (U+200D, the ZWJ, is allowed).
 */
export function isForbiddenInEmoji(code: number): boolean {
  return code <= 0x20 || (code >= 0x7f && code <= 0xa0) || isTrimmedCodePoint(code);
}

/**
 * The normalized emoji of a group or an avatar: null stays null; otherwise trimmed, and blank is null. What remains
 * must have 1–16 code points, none of them forbidden, else `invalidAppearance`.
 */
export function validateEmoji(raw: string | null): string | null {
  if (raw === null) return null;
  const value = trimmed(raw);
  if (value === '') return null;
  const points = codePoints(value);
  if (points.length > Limits.emojiCodePointsMax || points.some((point) => isForbiddenInEmoji(point.codePointAt(0)!))) {
    throw new AppError('invalidAppearance');
  }
  return value;
}

// MARK: - v2: recurrence

/** Zone names the server accepts that a device may list or name differently. */
const FIXED_TIME_ZONE_IDS = new Set(['UTC', 'GMT', 'Etc/UTC', 'Etc/GMT']);
const TIME_ZONE_SHAPE = /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+)+$/;

let knownTimeZoneIds: Set<string> | null | undefined;

/** The IANA names this device lists (`Intl.supportedValuesOf`), null when the engine cannot list them. */
function listedTimeZoneIds(): Set<string> | null {
  if (knownTimeZoneIds === undefined) {
    const intl = Intl as unknown as { supportedValuesOf?: (key: string) => string[] };
    try {
      knownTimeZoneIds = typeof intl.supportedValuesOf === 'function' ? new Set(intl.supportedValuesOf('timeZone')) : null;
    } catch {
      knownTimeZoneIds = null;
    }
  }
  return knownTimeZoneIds;
}

/**
 * True for a time zone name accepted in a recurrence rule: an IANA name that this device knows, exact case
 * (`Europe/Paris`, `UTC`, `America/Argentina/Buenos_Aires`), except the `posix/…` and `right/…` copies and `Factory`.
 * POSIX offsets (`UTC+3`), abbreviations (`CEST`) and other cases (`europe/paris`) are refused. Like the Swift client,
 * some aliases the server accepts may be refused here; the app only sends the device's own zone.
 */
export function isValidTimeZoneId(id: string): boolean {
  if (id.startsWith('posix/') || id.startsWith('right/') || id === 'Factory') return false;
  if (FIXED_TIME_ZONE_IDS.has(id)) return true;
  if (!TIME_ZONE_SHAPE.test(id)) return false;
  if (listedTimeZoneIds()?.has(id)) return true;
  let resolved: string;
  try {
    resolved = new Intl.DateTimeFormat('en-US', { timeZone: id }).resolvedOptions().timeZone;
  } catch {
    return false;
  }
  if (resolved === id) return true;
  // The same name in another case (`europe/paris`): refused.
  if (resolved.toLowerCase() === id.toLowerCase()) return false;
  // An alias the engine canonicalized (`America/Argentina/Buenos_Aires` → `America/Buenos_Aires` in ICU): the engine
  // cannot tell its exact case, so the IANA casing is checked instead.
  return hasIanaCasing(id);
}

/** Every segment starts with an uppercase letter and is not a shouted word (`PARIS`). */
function hasIanaCasing(id: string): boolean {
  return id.split('/').every((segment) => {
    if (!/^[A-Z]/.test(segment)) return false;
    const letters = segment.replace(/[^A-Za-z]/g, '');
    return letters.length <= 3 || letters !== letters.toUpperCase();
  });
}

/**
 * The shape of a rule, else `invalidRecurrence`: interval in 1…52; weekdays only on a weekly rule, not empty, values in
 * 1…7; a valid time zone. `monthDay` is not checked: the server sets it.
 */
export function validateRecurrenceShape(rule: RecurrenceRule): RecurrenceRule {
  if (!Number.isInteger(rule.interval) || rule.interval < 1 || rule.interval > Limits.repeatIntervalMax) {
    throw new AppError('invalidRecurrence');
  }
  if (rule.weekdays !== null) {
    if (
      rule.frequency !== 'weekly' ||
      rule.weekdays.length === 0 ||
      !rule.weekdays.every((day) => Number.isInteger(day) && day >= 1 && day <= 7)
    ) {
      throw new AppError('invalidRecurrence');
    }
  }
  if (!isValidTimeZoneId(rule.timeZoneId)) throw new AppError('invalidRecurrence');
  return rule;
}

/** The recurrence of a draft: null, or its shape then a due date (`recurrenceNeedsDueDate`). */
export function validateRecurrence(rule: RecurrenceRule | null, dueAt: Instant | null): RecurrenceRule | null {
  if (rule === null) return null;
  const checked = validateRecurrenceShape(rule);
  if (dueAt === null) throw new AppError('recurrenceNeedsDueDate');
  return checked;
}

/**
 * A new rotation, except the membership of its users (checked by the server): empty is no rotation; otherwise it needs
 * a recurrence and 2–20 distinct ids, else `invalidRotation`.
 */
export function validateRotation(ids: readonly Uuid[], recurrence: RecurrenceRule | null): Uuid[] {
  if (ids.length === 0) return [];
  if (
    recurrence === null ||
    ids.length < Limits.rotationMin ||
    ids.length > Limits.rotationMax ||
    new Set(ids).size !== ids.length
  ) {
    throw new AppError('invalidRotation');
  }
  return [...ids];
}

// MARK: - v2: checklist

/** Trimmed checklist item title (1–200), else `invalidChecklistItem`. */
export function validateChecklistItemTitle(raw: string): string {
  return text(raw, 1, Limits.checklistItemTitleMax, 'invalidChecklistItem');
}

/** The initial checklist of a new task: every title in order, then at most 30 items (`tooManyChecklistItems`). */
export function validateChecklist(titles: readonly string[]): string[] {
  const checked = titles.map(validateChecklistItemTitle);
  if (checked.length > Limits.checklistItemsMax) throw new AppError('tooManyChecklistItems');
  return checked;
}
