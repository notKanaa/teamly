import { makeProfile, type Membership, type TaskCompletion, type UserProfile } from '../models';
import { computeWeeklyRecap, RECAP_WEEKS_READ, recapReadStart, recapWeekStart } from '../weeklyRecap';
import { F } from './support';

const calendar = F.parisCalendar;
const camille = makeProfile({ id: F.uuid(0xc1), displayName: 'Camille Martin' });
const lucas = makeProfile({ id: F.uuid(0xc2), displayName: 'Lucas Bernard' });
const ines = makeProfile({ id: F.uuid(0xc3), displayName: 'Inès Dubois' });
const zoe = makeProfile({ id: F.uuid(0xc4), displayName: 'zoé' });
/** Someone who left the group. */
const departed = F.uuid(0xde);
const membersOf = (users: UserProfile[]): Membership[] =>
  users.map((user) => ({ groupId: F.groupA, user, role: 'member', joinedAt: F.date(2026, 1, 1) }));
const members = membersOf([camille, lucas, ines, zoe]);
/** Thursday 24 September 2026, 10:00 in Paris: the week runs from Monday 21 to Monday 28. */
const now = F.date(2026, 9, 24, 10);

let counter = 0;
function done(user: string | null, date: number, times = 1): TaskCompletion[] {
  return Array.from({ length: times }, () => {
    counter += 1;
    return { taskId: F.uuid(counter), completedBy: user, completedAt: date };
  });
}
const recap = (completions: TaskCompletion[], group: Membership[] = members) => computeWeeklyRecap(completions, group, now, calendar);

describe('WeeklyRecap (docs/CONTRACTS-V2.md §8)', () => {
  it('runs weeks from Monday midnight in the calendar’s time zone', () => {
    expect(recapWeekStart(now, calendar)).toBe(F.date(2026, 9, 21));
    expect(recapWeekStart(F.date(2026, 9, 21), calendar)).toBe(F.date(2026, 9, 21));
    expect(recapWeekStart(F.date(2026, 9, 27, 23, 59, 59), calendar)).toBe(F.date(2026, 9, 21));
    expect(recapWeekStart(F.date(2026, 9, 28), calendar)).toBe(F.date(2026, 9, 28));
    expect(recapReadStart(now, calendar)).toBe(F.date(2026, 8, 31));
    const empty = recap([]);
    expect(empty.weekStart).toBe(F.date(2026, 9, 21));
    expect(empty.weekEnd).toBe(F.date(2026, 9, 28));
  });

  it('starts weeks on Monday whatever the first weekday, across DST', () => {
    expect(recapWeekStart(F.date(2026, 9, 27, 12), calendar.withFirstWeekday(1))).toBe(F.date(2026, 9, 21));
    expect(recapWeekStart(F.date(2026, 10, 25, 12), calendar)).toBe(F.date(2026, 10, 19));
    expect(recapReadStart(F.date(2026, 10, 27, 9), calendar)).toBe(F.date(2026, 10, 5));
    const week = computeWeeklyRecap([], [], F.date(2026, 10, 20, 9), calendar);
    expect(week.weekEnd).toBe(F.date(2026, 10, 26));
    expect(week.weekEnd - week.weekStart).toBe((7 * 86_400 + 3600) * 1000);
  });

  it('counts every task done this week in the total', () => {
    const completions = [
      ...done(camille.id, F.date(2026, 9, 21), 2),
      ...done(departed, F.date(2026, 9, 22, 8)),
      ...done(null, F.date(2026, 9, 23, 8)),
      ...done(lucas.id, F.date(2026, 9, 20, 23, 59, 59)),
      ...done(lucas.id, F.date(2026, 9, 28)),
      ...done(lucas.id, F.date(2026, 8, 30, 12)),
    ];
    const result = recap(completions);
    expect(result.total).toBe(4);
    expect(result.podium).toEqual([{ user: camille, count: 2 }]);
  });

  it('ranks the current members, ties by name', () => {
    const day = F.date(2026, 9, 23, 18);
    const completions = [
      ...done(departed, day, 5),
      ...done(null, day, 4),
      ...done(zoe.id, day, 3),
      ...done(lucas.id, day, 3),
      ...done(camille.id, day, 3),
      ...done(ines.id, day, 1),
    ];
    const result = recap(completions);
    expect(result.total).toBe(19);
    expect(result.podium.map((entry) => entry.user)).toEqual([camille, lucas, zoe]);
    expect(result.podium.map((entry) => entry.count)).toEqual([3, 3, 3]);
    expect(result.streak).toBeNull();
  });

  it('orders identical names by user id', () => {
    const twinA = makeProfile({ id: F.uuid(0xa), displayName: 'Alex' });
    const twinB = makeProfile({ id: F.uuid(0xb), displayName: 'Alex' });
    const completions = [...done(twinB.id, F.date(2026, 9, 22)), ...done(twinA.id, F.date(2026, 9, 22))];
    expect(recap(completions, membersOf([twinB, twinA])).podium.map((entry) => entry.user.id)).toEqual([twinA.id, twinB.id]);
  });

  it('is empty without completions', () => {
    const result = recap([]);
    expect(result.total).toBe(0);
    expect(result.podium).toEqual([]);
    expect(result.streak).toBeNull();
  });

  it('counts consecutive sole leaderships', () => {
    const completions = [
      ...done(lucas.id, F.date(2026, 9, 24, 8), 2),
      ...done(camille.id, F.date(2026, 9, 22, 8)),
      ...done(lucas.id, F.date(2026, 9, 15, 8)),
      ...done(lucas.id, F.date(2026, 9, 7)),
      ...done(departed, F.date(2026, 9, 8), 4),
      ...done(camille.id, F.date(2026, 9, 1), 2),
      ...done(lucas.id, F.date(2026, 9, 2)),
    ];
    expect(recap(completions).streak).toEqual({ user: lucas, weeks: 3 });
  });

  it('caps a streak at the weeks read', () => {
    const completions = [F.date(2026, 9, 24), F.date(2026, 9, 14), F.date(2026, 9, 7), F.date(2026, 8, 31), F.date(2026, 8, 24)].flatMap((date) =>
      done(ines.id, date),
    );
    expect(recap(completions).streak).toEqual({ user: ines, weeks: RECAP_WEEKS_READ });
  });

  it('needs two weeks and sole leaders', () => {
    expect(recap(done(lucas.id, F.date(2026, 9, 24))).streak).toBeNull();
    const tie = [...done(lucas.id, F.date(2026, 9, 24)), ...done(lucas.id, F.date(2026, 9, 15)), ...done(ines.id, F.date(2026, 9, 16))];
    expect(recap(tie).streak).toBeNull();
    const tieNow = [...done(lucas.id, F.date(2026, 9, 24)), ...done(ines.id, F.date(2026, 9, 24)), ...done(lucas.id, F.date(2026, 9, 15))];
    expect(recap(tieNow).streak).toBeNull();
    const gap = [...done(lucas.id, F.date(2026, 9, 24)), ...done(lucas.id, F.date(2026, 9, 8))];
    expect(recap(gap).streak).toBeNull();
  });

  it('gives no streak to a departed leader', () => {
    const completions = [...done(departed, F.date(2026, 9, 24), 3), ...done(departed, F.date(2026, 9, 15), 3), ...done(camille.id, F.date(2026, 9, 24))];
    const result = recap(completions);
    expect(result.podium).toEqual([{ user: camille, count: 1 }]);
    expect(result.streak).toBeNull();
  });
});
