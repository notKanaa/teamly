import { AppError, type AppErrorKind } from '../appError';
import { FrenchCalendar, type Instant } from '../calendar';
import { makeTask, type TaskItem, type TaskPriority, type TaskStatus } from '../models';
import type { Uuid } from '../uuid';

/** Fixtures of the Swift `LogicFixtures`. */
export const F = {
  parisCalendar: FrenchCalendar.frenchGregorian('Europe/Paris'),
  me: '00000000-0000-0000-0000-00000000000a',
  other: '00000000-0000-0000-0000-00000000000b',
  groupA: '00000000-0000-0000-0000-0000000000a1',
  groupB: '00000000-0000-0000-0000-0000000000b2',

  /** A date in Europe/Paris. */
  date(year: number, month: number, day: number, hour = 0, minute = 0, second = 0): Instant {
    return F.parisCalendar.date(year, month, day, hour, minute, second);
  },

  /** Deterministic UUID from a small number. */
  uuid(value: number): Uuid {
    const hex = value.toString(16);
    return `10000000-0000-0000-0000-${'0'.repeat(12 - hex.length)}${hex}`;
  },

  task(
    value: number,
    fields: {
      title?: string;
      group?: Uuid;
      status?: TaskStatus;
      priority?: TaskPriority;
      due?: Instant | null;
      createdAt?: Instant;
      completedAt?: Instant | null;
      assignees?: Uuid[];
      groupName?: string | null;
    } = {},
  ): TaskItem {
    const createdAt = fields.createdAt ?? F.date(2026, 1, 1);
    const status = fields.status ?? 'todo';
    return makeTask({
      id: F.uuid(value),
      groupId: fields.group ?? F.groupA,
      title: fields.title ?? `Tâche ${value}`,
      status,
      priority: fields.priority ?? 'medium',
      dueAt: fields.due ?? null,
      createdBy: F.other,
      createdAt,
      updatedAt: createdAt,
      completedAt: status === 'done' ? (fields.completedAt ?? createdAt) : null,
      assigneeIds: fields.assignees ?? [F.me],
      groupName: fields.groupName === undefined ? 'Coloc\u{27} rue des Lilas' : fields.groupName,
    });
  },
};

/** UTC instant of `2026-09-24T18:00:00Z`. */
export function utc(text: string): Instant {
  const value = Date.parse(text);
  if (Number.isNaN(value)) throw new Error(`Invalid instant ${text}`);
  return value;
}

/** `2026-09-24T18:00:00Z`. */
export function utcText(instant: Instant): string {
  return new Date(instant).toISOString().replace('.000Z', 'Z');
}

/** Runs `body` and returns the kind of the `AppError` it throws (fails when it throws nothing or something else). */
export function thrownKind(body: () => unknown): AppErrorKind {
  try {
    body();
  } catch (error) {
    if (AppError.isAppError(error)) return error.kind;
    throw error;
  }
  throw new Error('Expected an AppError to be thrown');
}

/** What breaks the French spacing rules in `text` (Swift `WordingTests.typographyProblems`). */
export function typographyProblems(text: string): string[] {
  const characters = Array.from(text);
  const problems: string[] = [];
  const isNoBreak = (character: string | undefined) => character === '\u{a0}' || character === '\u{202f}';
  characters.forEach((character, index) => {
    const previous = characters[index - 1];
    const next = characters[index + 1];
    if ('?!:;'.includes(character) && previous === ' ') problems.push(`plain space before « ${character} »`);
    if (character === '«' && !isNoBreak(next)) problems.push('no no-break space after «');
    if (character === '»' && !isNoBreak(previous)) problems.push('no no-break space before »');
  });
  return problems;
}
