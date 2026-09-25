import { DateTime, IANAZone } from 'luxon';

/**
 * An instant: milliseconds since 1970-01-01T00:00:00Z. Server timestamps keep their microseconds as the fractional
 * part (see `postgresTimestamp.ts`).
 */
export type Instant = number;

/** Local date and time components of an instant in a calendar's time zone. */
export interface CalendarComponents {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
  /** Gregorian weekday of Foundation: 1 = Sunday, 2 = Monday … 7 = Saturday. */
  weekday: number;
}

/**
 * The Gregorian calendar of the Swift core (`Calendar.frenchGregorian(timeZone:)`): a time zone and the first day of
 * the week (Foundation's `firstWeekday`, 1 = Sunday … 7 = Saturday; 2 = Monday for the French calendar). Every
 * computation is done by Luxon in the zone, so days and weeks are correct across daylight saving time changes.
 */
export class FrenchCalendar {
  readonly zone: string;
  readonly firstWeekday: number;
  private readonly iana: IANAZone;

  constructor(zone: string, firstWeekday = 2) {
    const iana = IANAZone.create(zone);
    if (!iana.isValid) throw new RangeError(`Unknown time zone: ${zone}`);
    this.zone = zone;
    this.iana = iana;
    this.firstWeekday = firstWeekday;
  }

  /** The French calendar (weeks start on Monday) in `zone`. */
  static frenchGregorian(zone: string): FrenchCalendar {
    return new FrenchCalendar(zone, 2);
  }

  /** The French calendar in the device's time zone (UTC when it cannot be read). */
  static device(): FrenchCalendar {
    return FrenchCalendar.frenchGregorian(deviceTimeZone());
  }

  /** The same calendar with another first weekday (tests of `DueBucket`). */
  withFirstWeekday(firstWeekday: number): FrenchCalendar {
    return new FrenchCalendar(this.zone, firstWeekday);
  }

  dateTime(instant: Instant): DateTime {
    return DateTime.fromMillis(instant, { zone: this.iana });
  }

  components(instant: Instant): CalendarComponents {
    const dt = this.dateTime(instant);
    return {
      year: dt.year,
      month: dt.month,
      day: dt.day,
      hour: dt.hour,
      minute: dt.minute,
      second: dt.second,
      weekday: (dt.weekday % 7) + 1,
    };
  }

  /** Gregorian weekday of Foundation: 1 = Sunday … 7 = Saturday. */
  gregorianWeekday(instant: Instant): number {
    return (this.dateTime(instant).weekday % 7) + 1;
  }

  /**
   * `Calendar.date(from:)`: the instant of a local date and time. A local time skipped by a daylight saving change is
   * moved forward by the gap (02:30 on the spring-forward day in Paris is 03:30 CEST).
   */
  date(year: number, month: number, day: number, hour = 0, minute = 0, second = 0): Instant {
    return DateTime.fromObject({ year, month, day, hour, minute, second }, { zone: this.iana }).toMillis();
  }

  /** First instant of the day of `instant` (01:00 on a day whose midnight is skipped). */
  startOfDay(instant: Instant): Instant {
    return this.dateTime(instant).startOf('day').toMillis();
  }

  /** `Calendar.date(byAdding: .day, value:, to:)`: calendar days, keeping the local time of day. */
  addingDays(days: number, instant: Instant): Instant {
    return this.dateTime(instant).plus({ days }).toMillis();
  }

  /** Offset of the zone from UTC at `instant`, in seconds. */
  offsetSeconds(instant: Instant): number {
    return Math.round(this.iana.offset(instant) * 60);
  }
}

/** The IANA name of the device's time zone (`TimeZone.current.identifier`), UTC when it cannot be read. */
export function deviceTimeZone(): string {
  try {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (zone && IANAZone.isValidZone(zone)) return zone;
  } catch {
    // Fall through.
  }
  return 'UTC';
}

/** Offset from UTC, in seconds, of the IANA `zone` at `instant` (Foundation's `secondsFromGMT(for:)`). */
export function zoneOffsetSeconds(zone: IANAZone, instant: Instant): number {
  return Math.round(zone.offset(instant) * 60);
}
