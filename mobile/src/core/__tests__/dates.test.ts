import { FrenchCalendar } from '../calendar';
import { dayOffset, formatDay, formatTime, relativeDateText, relativeDateTime, relativeDateTimeInSentence, relativeDay } from '../frenchDate';
import { F } from './support';

const calendar = F.parisCalendar;

describe('FrenchDateFormatter', () => {
  it('writes 24-hour times with two digits', () => {
    expect(formatTime(F.date(2026, 9, 24, 8, 5), calendar)).toBe('08:05');
    expect(formatTime(F.date(2026, 9, 24, 20, 0), calendar)).toBe('20:00');
    expect(formatTime(F.date(2026, 9, 24, 0, 0), calendar)).toBe('00:00');
    expect(formatTime(F.date(2026, 9, 24, 23, 59), calendar)).toBe('23:59');
  });

  it('uses the calendar’s time zone', () => {
    const date = F.date(2026, 7, 1, 20, 0); // 18:00 UTC (CEST = UTC+2)
    expect(formatTime(date, FrenchCalendar.frenchGregorian('UTC'))).toBe('18:00');
    expect(formatTime(date, calendar)).toBe('20:00');
  });

  it('names full days', () => {
    expect(formatDay(F.date(2026, 9, 24), calendar, false)).toBe('jeudi 24 septembre');
    expect(formatDay(F.date(2026, 9, 1), calendar, false)).toBe('mardi 1er septembre');
    expect(formatDay(F.date(2027, 1, 1), calendar, true)).toBe('vendredi 1er janvier 2027');
    expect(formatDay(F.date(2026, 8, 16), calendar, false)).toBe('dimanche 16 août');
    expect(formatDay(F.date(2026, 2, 2), calendar, false)).toBe('lundi 2 février');
    expect(formatDay(F.date(2026, 12, 12), calendar, false)).toBe('samedi 12 décembre');
  });

  it('words dates relative to a reference', () => {
    const reference = F.date(2026, 9, 24, 10, 0);
    expect(relativeDateTime(F.date(2026, 9, 24, 20, 0), reference, calendar)).toBe('aujourd’hui à 20:00');
    expect(relativeDateTime(F.date(2026, 9, 25, 8, 30), reference, calendar)).toBe('demain à 08:30');
    expect(relativeDateTime(F.date(2026, 9, 23, 23, 59), reference, calendar)).toBe('hier à 23:59');
    expect(relativeDateTime(F.date(2026, 9, 28, 9, 0), reference, calendar)).toBe('lundi à 09:00');
    expect(relativeDateTime(F.date(2027, 1, 1, 10, 0), reference, calendar)).toBe('vendredi 1er janvier 2027 à 10:00');
    expect(relativeDateTime(F.date(2026, 9, 20, 10, 0), reference, calendar)).toBe('dimanche 20 septembre à 10:00');
    expect(relativeDateText(F.date(2026, 9, 24, 20, 0), reference, calendar)).toBe('Aujourd’hui à 20:00');
  });

  it('shows the weekday alone 2 to 6 days ahead', () => {
    const reference = F.date(2026, 9, 24, 10, 0); // Thursday
    expect(relativeDay(F.date(2026, 9, 26, 9, 0), reference, calendar)).toBe('samedi');
    expect(relativeDay(F.date(2026, 9, 27, 9, 0), reference, calendar)).toBe('dimanche');
    expect(relativeDay(F.date(2026, 9, 30, 23, 59), reference, calendar)).toBe('mercredi');
    expect(relativeDay(F.date(2026, 10, 1, 0, 0), reference, calendar)).toBe('jeudi 1er octobre');
    expect(relativeDay(F.date(2026, 9, 22, 9, 0), reference, calendar)).toBe('mardi 22 septembre');
    const newYearsEve = F.date(2026, 12, 30, 10, 0);
    expect(relativeDateTime(F.date(2027, 1, 2, 18, 0), newYearsEve, calendar)).toBe('samedi à 18:00');
    expect(relativeDateTime(F.date(2027, 1, 6, 18, 0), newYearsEve, calendar)).toBe('mercredi 6 janvier 2027 à 18:00');
  });

  it('words dates in the middle of a sentence', () => {
    const reference = F.date(2026, 9, 24, 10, 0);
    expect(relativeDateTimeInSentence(F.date(2026, 9, 24, 9, 0), reference, calendar)).toBe('aujourd’hui à 09:00');
    expect(relativeDateTimeInSentence(F.date(2026, 9, 23, 23, 59), reference, calendar)).toBe('hier à 23:59');
    expect(relativeDateTimeInSentence(F.date(2026, 9, 25, 8, 30), reference, calendar)).toBe('demain à 08:30');
    expect(relativeDateTimeInSentence(F.date(2026, 9, 22, 10, 0), reference, calendar)).toBe('le mardi 22 septembre à 10:00');
    expect(relativeDateTimeInSentence(F.date(2026, 9, 14, 10, 0), reference, calendar)).toBe('le lundi 14 septembre à 10:00');
    expect(relativeDateTimeInSentence(F.date(2026, 9, 28, 9, 0), reference, calendar)).toBe('le lundi 28 septembre à 09:00');
    expect(relativeDateTimeInSentence(F.date(2025, 12, 31, 10, 0), reference, calendar)).toBe('le mercredi 31 décembre 2025 à 10:00');
  });

  it('handles midnight boundaries', () => {
    const reference = F.date(2026, 9, 24, 23, 59, 59);
    expect(relativeDay(F.date(2026, 9, 25, 0, 0), reference, calendar)).toBe('demain');
    expect(relativeDay(F.date(2026, 9, 24, 0, 0), reference, calendar)).toBe('aujourd’hui');
  });

  it('counts days across daylight saving time changes', () => {
    const saturdayNight = F.date(2026, 3, 28, 23, 30);
    expect(dayOffset(F.date(2026, 3, 29, 23, 30), saturdayNight, calendar)).toBe(1);
    expect(dayOffset(F.date(2026, 3, 30, 0, 30), saturdayNight, calendar)).toBe(2);
    const sundayEarly = F.date(2026, 10, 25, 0, 30);
    const sundayLate = sundayEarly + 24 * 3600 * 1000; // 23:30 the same day
    expect(formatTime(sundayLate, calendar)).toBe('23:30');
    expect(relativeDay(sundayLate, sundayEarly, calendar)).toBe('aujourd’hui');
    expect(relativeDateTime(F.date(2026, 10, 26, 9, 0), sundayEarly, calendar)).toBe('demain à 09:00');
  });

  it.each(['Atlantic/Azores', 'America/Santiago'])('counts days on the days whose midnight is skipped (%s)', (zone) => {
    const local = FrenchCalendar.frenchGregorian(zone);
    let day = local.date(2026, 1, 1, 12);
    let transition: number | null = null;
    for (let index = 0; index < 366; index += 1) {
      if (local.components(local.startOfDay(day)).hour !== 0) {
        transition = day;
        break;
      }
      day = local.addingDays(1, day);
    }
    expect(transition).not.toBeNull();
    const parts = local.components(transition!);
    const noon = local.date(parts.year, parts.month, parts.day, 12);
    const ten = local.date(parts.year, parts.month, parts.day, 10);
    const tomorrow = local.addingDays(1, ten);
    expect(dayOffset(tomorrow, noon, local)).toBe(1);
    expect(dayOffset(local.addingDays(2, ten), noon, local)).toBe(2);
    expect(dayOffset(local.addingDays(-1, ten), noon, local)).toBe(-1);
    expect(dayOffset(noon, tomorrow, local)).toBe(-1);
    expect(relativeDateTime(tomorrow, noon, local)).toBe('demain à 10:00');
    expect(relativeDateTime(ten, noon, local)).toBe('aujourd’hui à 10:00');
  });
});
