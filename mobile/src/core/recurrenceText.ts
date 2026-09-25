import type { Instant } from './calendar';
import type { Frequency, RecurrenceRule } from './models';
import { localMonthDay, localWeekday } from './nextDue';

// French wording of a repetition rule (Swift `RecurrenceText`): « Chaque semaine, le samedi », « Toutes les 2 semaines,
// le mardi et le vendredi », « Chaque mois, le 31 ou le dernier jour du mois ».

/** Weekday names indexed by ISO weekday − 1 (1 = Monday … 7 = Sunday). */
export const ISO_WEEKDAY_NAMES = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'] as const;

/** « Chaque jour », « Tous les 2 jours », « Chaque semaine », « Toutes les 2 semaines », « Chaque mois », « Tous les 3 mois ». */
export function recurrenceSummaryOf(frequency: Frequency, interval: number): string {
  const count = Math.max(1, interval);
  switch (frequency) {
    case 'daily':
      return count === 1 ? 'Chaque jour' : `Tous les ${count} jours`;
    case 'weekly':
      return count === 1 ? 'Chaque semaine' : `Toutes les ${count} semaines`;
    case 'monthly':
      return count === 1 ? 'Chaque mois' : `Tous les ${count} mois`;
  }
}

export function recurrenceSummary(rule: RecurrenceRule): string {
  return recurrenceSummaryOf(rule.frequency, rule.interval);
}

/** « le samedi », « le mardi et le vendredi », « du lundi au vendredi », « tous les jours »; null without any day. */
export function weekdaysText(weekdays: Iterable<number>): string | null {
  const days = Array.from(new Set(weekdays))
    .filter((day) => day >= 1 && day <= 7)
    .sort((a, b) => a - b);
  const last = days[days.length - 1];
  if (last === undefined) return null;
  if (days.length === 7) return 'tous les jours';
  if (days.join(',') === '1,2,3,4,5') return 'du lundi au vendredi';
  if (days.length === 1) return `le ${ISO_WEEKDAY_NAMES[last - 1]}`;
  const first = days
    .slice(0, -1)
    .map((day) => `le ${ISO_WEEKDAY_NAMES[day - 1]}`)
    .join(', ');
  return `${first} et le ${ISO_WEEKDAY_NAMES[last - 1]}`;
}

/** « le 25 », « le 1er », and for a day some months lack, « le 31 ou le dernier jour du mois ». */
export function monthDayText(day: number): string {
  const clamped = Math.min(Math.max(day, 1), 31);
  const value = clamped === 1 ? '1er' : `${clamped}`;
  return clamped > 28 ? `le ${value} ou le dernier jour du mois` : `le ${value}`;
}

/**
 * The summary, then the days of a weekly or monthly rule; the days that follow the due date are read in the rule's
 * time zone. Without a due date (and without explicit days), only the summary.
 */
export function recurrenceDescription(rule: RecurrenceRule, dueAt: Instant | null): string {
  const summary = recurrenceSummary(rule);
  switch (rule.frequency) {
    case 'daily':
      return summary;
    case 'weekly': {
      const weekdays = rule.weekdays ?? (dueAt === null ? [] : [localWeekday(dueAt, rule)]);
      const days = weekdaysText(weekdays);
      return days === null ? summary : `${summary}, ${days}`;
    }
    case 'monthly': {
      const day = rule.monthDay ?? (dueAt === null ? null : localMonthDay(dueAt, rule));
      return day === null ? summary : `${summary}, ${monthDayText(day)}`;
    }
  }
}
