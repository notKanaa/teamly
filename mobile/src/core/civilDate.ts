/**
 * Dates of the proleptic Gregorian calendar as day numbers (days since 1970-01-01), with Howard Hinnant's
 * `days_from_civil` / `civil_from_days` algorithms (Swift `CivilDate`).
 */
export interface CivilDate {
  year: number;
  month: number;
  day: number;
}

/** Swift's integer division: truncation toward zero. */
function div(value: number, divisor: number): number {
  return Math.trunc(value / divisor);
}

export function civilFromDays(dayNumber: number): CivilDate {
  const z = dayNumber + 719_468;
  const era = div(z >= 0 ? z : z - 146_096, 146_097);
  const dayOfEra = z - era * 146_097;
  const yearOfEra = div(dayOfEra - div(dayOfEra, 1460) + div(dayOfEra, 36_524) - div(dayOfEra, 146_096), 365);
  const dayOfYear = dayOfEra - (365 * yearOfEra + div(yearOfEra, 4) - div(yearOfEra, 100));
  const shiftedMonth = div(5 * dayOfYear + 2, 153); // March = 0
  const day = dayOfYear - div(153 * shiftedMonth + 2, 5) + 1;
  const month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9;
  const year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0);
  return { year, month, day };
}

export function daysFromCivil(year: number, month: number, day: number): number {
  const y = month <= 2 ? year - 1 : year;
  const era = div(y >= 0 ? y : y - 399, 400);
  const yearOfEra = y - era * 400;
  const dayOfYear = div(153 * ((month + 9) % 12) + 2, 5) + day - 1;
  const dayOfEra = yearOfEra * 365 + div(yearOfEra, 4) - div(yearOfEra, 100) + dayOfYear;
  return era * 146_097 + dayOfEra - 719_468;
}

export function isLeapYear(year: number): boolean {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

export function daysInMonth(year: number, month: number): number {
  switch (month) {
    case 2:
      return isLeapYear(year) ? 29 : 28;
    case 4:
    case 6:
    case 9:
    case 11:
      return 30;
    default:
      return 31;
  }
}
