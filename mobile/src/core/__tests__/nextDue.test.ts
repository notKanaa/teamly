import { IANAZone } from 'luxon';

import { civilFromDays, daysFromCivil, daysInMonth } from '../civilDate';
import { type Frequency, makeRule, type RecurrenceRule } from '../models';
import { isoWeekday, localInstant, nextDueDate, upcomingDueDates } from '../nextDue';
import { rotationHandover } from '../rotation';
import { utc, utcText } from './support';

function rule(
  frequency: Frequency,
  options: { interval?: number; weekdays?: number[]; tz?: string; monthDay?: number } = {},
): RecurrenceRule {
  return makeRule({
    frequency,
    interval: options.interval ?? 1,
    weekdays: options.weekdays ?? null,
    timeZoneId: options.tz ?? 'Europe/Paris',
    monthDay: options.monthDay ?? null,
  });
}

interface Vector {
  name: string;
  rule: RecurrenceRule;
  dueAt: string;
  now: string;
  expected: string;
}

/** Every row of the test-vector table of docs/CONTRACTS-V2.md §6, in order (computed with `private.next_due_at`). */
const VECTORS: Vector[] = [
  { name: '1 daily, 20:00 CEST', rule: rule('daily'), dueAt: '2026-09-24T18:00:00Z', now: '2026-09-24T19:00:00Z', expected: '2026-09-25T18:00:00Z' },
  { name: '2 completed early', rule: rule('daily'), dueAt: '2026-09-26T18:00:00Z', now: '2026-09-24T10:00:00Z', expected: '2026-09-27T18:00:00Z' },
  { name: '3 every 3 days', rule: rule('daily', { interval: 3 }), dueAt: '2026-09-24T06:00:00Z', now: '2026-09-24T07:00:00Z', expected: '2026-09-27T06:00:00Z' },
  { name: '4 missed occurrences skipped', rule: rule('daily'), dueAt: '2026-09-20T06:00:00Z', now: '2026-09-24T12:00:00Z', expected: '2026-09-25T06:00:00Z' },
  { name: '5 a slot due exactly now is skipped', rule: rule('daily'), dueAt: '2026-09-22T06:00:00Z', now: '2026-09-24T06:00:00Z', expected: '2026-09-25T06:00:00Z' },
  { name: '6 weekly, the due date’s weekday', rule: rule('weekly'), dueAt: '2026-09-21T07:00:00Z', now: '2026-09-21T08:00:00Z', expected: '2026-09-28T07:00:00Z' },
  { name: '7 every 2 weeks', rule: rule('weekly', { interval: 2 }), dueAt: '2026-09-21T07:00:00Z', now: '2026-09-21T08:00:00Z', expected: '2026-10-05T07:00:00Z' },
  { name: '8 Mon/Wed/Fri from a Wednesday', rule: rule('weekly', { weekdays: [1, 3, 5] }), dueAt: '2026-09-23T16:00:00Z', now: '2026-09-23T17:00:00Z', expected: '2026-09-25T16:00:00Z' },
  { name: '9 Mon/Wed/Fri from a Friday', rule: rule('weekly', { weekdays: [1, 3, 5] }), dueAt: '2026-09-25T16:00:00Z', now: '2026-09-25T17:00:00Z', expected: '2026-09-28T16:00:00Z' },
  { name: '10 Tue/Thu every 2 weeks from a Tuesday', rule: rule('weekly', { interval: 2, weekdays: [2, 4] }), dueAt: '2026-09-22T16:00:00Z', now: '2026-09-22T17:00:00Z', expected: '2026-09-24T16:00:00Z' },
  { name: '11 Tue/Thu every 2 weeks from a Thursday', rule: rule('weekly', { interval: 2, weekdays: [2, 4] }), dueAt: '2026-09-24T16:00:00Z', now: '2026-09-24T17:00:00Z', expected: '2026-10-06T16:00:00Z' },
  { name: '12 due on a Sunday, outside the weekdays', rule: rule('weekly', { interval: 2, weekdays: [1, 3] }), dueAt: '2026-09-27T08:00:00Z', now: '2026-09-27T09:00:00Z', expected: '2026-10-05T08:00:00Z' },
  { name: '13 weekdays, missed occurrences skipped', rule: rule('weekly', { weekdays: [1, 3, 5] }), dueAt: '2026-09-14T16:00:00Z', now: '2026-09-24T12:00:00Z', expected: '2026-09-25T16:00:00Z' },
  { name: '14 the 31st → February 28', rule: rule('monthly'), dueAt: '2026-01-31T17:00:00Z', now: '2026-01-31T18:00:00Z', expected: '2026-02-28T17:00:00Z' },
  { name: '15 → back to March 31 (after the DST change)', rule: rule('monthly', { monthDay: 31 }), dueAt: '2026-02-28T17:00:00Z', now: '2026-02-28T18:00:00Z', expected: '2026-03-31T16:00:00Z' },
  { name: '16 → April 30', rule: rule('monthly', { monthDay: 31 }), dueAt: '2026-03-31T16:00:00Z', now: '2026-03-31T17:00:00Z', expected: '2026-04-30T16:00:00Z' },
  { name: '17 → May 31, no drift', rule: rule('monthly', { monthDay: 31 }), dueAt: '2026-04-30T16:00:00Z', now: '2026-04-30T17:00:00Z', expected: '2026-05-31T16:00:00Z' },
  { name: '18 leap year', rule: rule('monthly', { monthDay: 31 }), dueAt: '2028-01-31T17:00:00Z', now: '2028-01-31T18:00:00Z', expected: '2028-02-29T17:00:00Z' },
  { name: '19 every 3 months', rule: rule('monthly', { interval: 3 }), dueAt: '2026-01-15T08:00:00Z', now: '2026-01-15T09:00:00Z', expected: '2026-04-15T07:00:00Z' },
  { name: '20 monthly, missed occurrences skipped', rule: rule('monthly'), dueAt: '2026-05-15T07:00:00Z', now: '2026-09-24T12:00:00Z', expected: '2026-10-15T07:00:00Z' },
  { name: '21 spring DST change: 08:00 CET → 08:00 CEST', rule: rule('daily'), dueAt: '2026-03-28T07:00:00Z', now: '2026-03-28T08:00:00Z', expected: '2026-03-29T06:00:00Z' },
  { name: '22 autumn DST change: 18:30 CEST → 18:30 CET', rule: rule('weekly'), dueAt: '2026-10-19T16:30:00Z', now: '2026-10-19T17:00:00Z', expected: '2026-10-26T17:30:00Z' },
  { name: '23 another zone: 09:00 EST → 09:00 EDT', rule: rule('daily', { tz: 'America/New_York' }), dueAt: '2026-03-07T14:00:00Z', now: '2026-03-07T15:00:00Z', expected: '2026-03-08T13:00:00Z' },
  { name: '24 the local date counts (Tokyo)', rule: rule('monthly', { tz: 'Asia/Tokyo' }), dueAt: '2026-01-30T15:30:00Z', now: '2026-01-30T16:00:00Z', expected: '2026-02-27T15:30:00Z' },
  { name: '25 Sunday only', rule: rule('weekly', { weekdays: [7], tz: 'UTC' }), dueAt: '2026-09-27T20:00:00Z', now: '2026-09-27T21:00:00Z', expected: '2026-10-04T20:00:00Z' },
  { name: '26 10 000 steps at most', rule: rule('daily'), dueAt: '1990-01-01T08:00:00Z', now: '2026-09-24T12:00:00Z', expected: '2017-05-19T07:00:00Z' },
  { name: '27 yearly on February 29', rule: rule('monthly', { interval: 12, monthDay: 29 }), dueAt: '2027-02-28T09:00:00Z', now: '2027-02-28T10:00:00Z', expected: '2028-02-29T09:00:00Z' },
];

/** PostgreSQL's reading of local times that do not exist or are ambiguous (pgTAP `13_v2_recurrence`). */
const DST_VECTORS: Vector[] = [
  { name: '02:30 on the spring-forward day does not exist: 03:30 CEST', rule: rule('daily'), dueAt: '2026-03-28T01:30:00Z', now: '2026-03-28T02:00:00Z', expected: '2026-03-29T01:30:00Z' },
  { name: '02:30 on the fall-back day is ambiguous: the later instant, 02:30 CET', rule: rule('daily'), dueAt: '2026-10-24T00:30:00Z', now: '2026-10-24T01:00:00Z', expected: '2026-10-25T01:30:00Z' },
];

describe('NextDueCalculator (docs/CONTRACTS-V2.md §6)', () => {
  it('has every row of the table', () => {
    expect(VECTORS).toHaveLength(27);
  });

  it.each(VECTORS.map((vector) => [vector.name, vector] as const))('matches the server vector %s', (_name, vector) => {
    const next = nextDueDate(utc(vector.dueAt), vector.rule, utc(vector.now));
    expect(next).not.toBeNull();
    expect(utcText(next!)).toBe(vector.expected);
  });

  it.each(DST_VECTORS.map((vector) => [vector.name, vector] as const))('reads DST local times like PostgreSQL: %s', (_name, vector) => {
    const next = nextDueDate(utc(vector.dueAt), vector.rule, utc(vector.now));
    expect(utcText(next!)).toBe(vector.expected);
  });

  it('reads the local times around the DST changes of Paris', () => {
    const paris = IANAZone.create('Europe/Paris');
    const at = (year: number, month: number, day: number, hour: number, minute: number) =>
      utcText(localInstant(daysFromCivil(year, month, day), hour * 3600 + minute * 60, paris));
    // Spring forward, 2026-03-29 at 01:00Z (02:00 CET → 03:00 CEST).
    expect(at(2026, 3, 29, 1, 59)).toBe('2026-03-29T00:59:00Z');
    expect(at(2026, 3, 29, 2, 0)).toBe('2026-03-29T01:00:00Z');
    expect(at(2026, 3, 29, 3, 0)).toBe('2026-03-29T01:00:00Z');
    expect(at(2026, 3, 29, 3, 30)).toBe('2026-03-29T01:30:00Z');
    // Fall back, 2026-10-25 at 01:00Z (03:00 CEST → 02:00 CET): 02:00–02:59 happen twice.
    expect(at(2026, 10, 25, 1, 59)).toBe('2026-10-24T23:59:00Z');
    expect(at(2026, 10, 25, 2, 0)).toBe('2026-10-25T01:00:00Z');
    expect(at(2026, 10, 25, 2, 59)).toBe('2026-10-25T01:59:00Z');
    expect(at(2026, 10, 25, 3, 0)).toBe('2026-10-25T02:00:00Z');
    // An ordinary day.
    expect(at(2026, 9, 24, 20, 0)).toBe('2026-09-24T18:00:00Z');
  });

  it('gives no date for an unknown time zone', () => {
    const unknown = rule('daily', { tz: 'Mars/Olympus_Mons' });
    const date = utc('2026-09-24T18:00:00Z');
    expect(nextDueDate(date, unknown, date)).toBeNull();
    expect(upcomingDueDates(date, unknown, date, 3)).toEqual([]);
  });

  it('uses the local day for a new monthly rule (vector 24)', () => {
    const dueAt = utc('2026-01-30T15:30:00Z'); // January 31, 00:30 in Tokyo
    const dates = upcomingDueDates(dueAt, rule('monthly', { tz: 'Asia/Tokyo' }), dueAt, 3);
    expect(dates.map(utcText)).toEqual(['2026-02-27T15:30:00Z', '2026-03-30T15:30:00Z', '2026-04-29T15:30:00Z']);
  });

  it('converts civil dates both ways', () => {
    expect(daysFromCivil(1970, 1, 1)).toBe(0);
    expect(civilFromDays(0)).toEqual({ year: 1970, month: 1, day: 1 });
    expect(daysFromCivil(2000, 3, 1)).toBe(11_017);
    expect(civilFromDays(-1)).toEqual({ year: 1969, month: 12, day: 31 });
    for (let day = -800_000; day <= 3_000_000; day += 997) {
      const civil = civilFromDays(day);
      expect(daysFromCivil(civil.year, civil.month, civil.day)).toBe(day);
    }
    expect(daysInMonth(2028, 2)).toBe(29);
    expect(daysInMonth(2100, 2)).toBe(28);
    expect(daysInMonth(2000, 2)).toBe(29);
  });

  it('computes ISO weekdays', () => {
    expect(isoWeekday(0)).toBe(4); // 1970-01-01, a Thursday
    expect(isoWeekday(daysFromCivil(2026, 9, 21))).toBe(1);
    expect(isoWeekday(daysFromCivil(2026, 9, 27))).toBe(7);
    expect(isoWeekday(-1)).toBe(3);
  });

  it('previews the next dates of a weekday rule', () => {
    const dueAt = utc('2026-09-23T16:00:00Z'); // Wednesday 18:00 CEST
    const dates = upcomingDueDates(dueAt, rule('weekly', { weekdays: [1, 3, 5] }), dueAt, 4);
    expect(dates.map(utcText)).toEqual([
      '2026-09-25T16:00:00Z',
      '2026-09-28T16:00:00Z',
      '2026-09-30T16:00:00Z',
      '2026-10-02T16:00:00Z',
    ]);
  });

  it('previews monthly dates without drift', () => {
    const dueAt = utc('2026-01-31T17:00:00Z');
    const dates = upcomingDueDates(dueAt, rule('monthly'), dueAt, 4);
    expect(dates.map(utcText)).toEqual([
      '2026-02-28T17:00:00Z',
      '2026-03-31T16:00:00Z',
      '2026-04-30T16:00:00Z',
      '2026-05-31T16:00:00Z',
    ]);
  });

  it('starts the preview after now', () => {
    const dueAt = utc('2026-09-20T06:00:00Z');
    const now = utc('2026-09-24T12:00:00Z');
    expect(upcomingDueDates(dueAt, rule('daily'), now, 2).map(utcText)).toEqual(['2026-09-25T06:00:00Z', '2026-09-26T06:00:00Z']);
    expect(upcomingDueDates(dueAt, rule('daily'), now, 0)).toEqual([]);
    expect(upcomingDueDates(dueAt, rule('daily'), now, -1)).toEqual([]);
  });

  it('chains the preview like successive occurrences', () => {
    const dueAt = utc('2026-03-28T01:30:00Z'); // 02:30 CET
    expect(upcomingDueDates(dueAt, rule('daily'), dueAt, 2).map(utcText)).toEqual(['2026-03-29T01:30:00Z', '2026-03-30T01:30:00Z']);
  });

  it('stops an invalid rule after the step budget', () => {
    const dueAt = utc('2026-09-24T18:00:00Z');
    expect(nextDueDate(dueAt, rule('daily', { interval: 0 }), dueAt)).toBe(dueAt);
  });
});

describe('RotationHandover', () => {
  const m1 = '00000000-0000-0000-0000-0000000000d1';
  const m2 = '00000000-0000-0000-0000-0000000000d2';
  const m3 = '00000000-0000-0000-0000-0000000000d3';
  const m4 = '00000000-0000-0000-0000-0000000000d4';
  const m5 = '00000000-0000-0000-0000-0000000000d5';
  const handover = (rotation: string[], turn: string | null, members: string[]) =>
    rotationHandover(rotation, turn, (id) => members.includes(id));

  it('gives the turn to the next one and wraps around', () => {
    const all = [m1, m2, m3];
    expect(handover(all, m1, all)).toEqual({ rotation: all, turnUserId: m2, assigneeId: m2 });
    expect(handover(all, m2, all).turnUserId).toBe(m3);
    expect(handover(all, m3, all).turnUserId).toBe(m1);
  });

  it('skips and drops departed members', () => {
    expect(handover([m1, m4, m2, m3], m1, [m1, m2, m3])).toEqual({ rotation: [m1, m2, m3], turnUserId: m2, assigneeId: m2 });
  });

  it('keeps the position of a departed turn holder', () => {
    expect(handover([m3, m5, m1], m5, [m1, m3])).toEqual({ rotation: [m3, m1], turnUserId: m1, assigneeId: m1 });
  });

  it('starts with the first member without a listed turn holder', () => {
    const gone = '00000000-0000-0000-0000-0000000000ff';
    expect(handover([gone, m2, m3], null, [m2, m3])).toEqual({ rotation: [m2, m3], turnUserId: m2, assigneeId: m2 });
    expect(handover([m1, m2], m5, [m1, m2]).turnUserId).toBe(m1);
  });

  it('hands the turn over when the turn holder leaves', () => {
    const left = handover([m1, m2, m3], m2, [m1, m3]);
    expect(left.turnUserId).toBe(m3);
    expect(left.assigneeId).toBe(m3);
    expect(left.rotation).not.toHaveLength(0);
    expect(handover([m1, m2, m3, m4], m4, [m2, m3]).turnUserId).toBe(m2);
    expect(handover([m1, m2], m1, [m2])).toEqual({ rotation: [], turnUserId: null, assigneeId: m2 });
    expect(handover([m1, m2], m1, [])).toEqual({ rotation: [], turnUserId: null, assigneeId: null });
    expect(handover([m1, m2, m3], m2, [m1, m3]).turnUserId).toBe(m3);
  });

  it('drops a rotation of fewer than two members', () => {
    expect(handover([m1, m4], m1, [m1])).toEqual({ rotation: [], turnUserId: null, assigneeId: m1 });
    expect(handover([m2, m3], m2, [])).toEqual({ rotation: [], turnUserId: null, assigneeId: null });
    expect(handover([], null, [m1])).toEqual({ rotation: [], turnUserId: null, assigneeId: null });
  });
});
