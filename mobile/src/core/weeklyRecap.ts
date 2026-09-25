import type { FrenchCalendar, Instant } from './calendar';
import type { Membership, TaskCompletion, UserProfile } from './models';
import { compareNames } from './nameOrder';
import { compareUuids, type Uuid } from './uuid';

/**
 * The weekly recap of a group (docs/CONTRACTS-V2.md §8, Swift `WeeklyRecap`), computed on the device from the group's
 * done tasks and its members. Weeks run from Monday 00:00 to the next Monday 00:00 in the calendar's time zone.
 * - total: every task done in the current week;
 * - podium: the top 3 completers among the current members, most tasks first, ties by name, then id;
 * - streak: the same current member as the sole leader of consecutive weeks, the current one included, when at least
 *   2 weeks (at most the 4 weeks read).
 * Tasks completed by people who are no longer members, or by nobody known, count in the total only.
 */
export interface WeeklyRecapEntry {
  user: UserProfile;
  count: number;
}

export interface WeeklyRecapStreak {
  user: UserProfile;
  weeks: number;
}

export interface WeeklyRecap {
  /** Monday 00:00 of the current week. */
  weekStart: Instant;
  /** The next Monday 00:00 (exclusive end). */
  weekEnd: Instant;
  total: number;
  podium: WeeklyRecapEntry[];
  streak: WeeklyRecapStreak | null;
}

export const RECAP_WEEKS_READ = 4;
export const RECAP_PODIUM_SIZE = 3;
export const RECAP_MINIMUM_STREAK = 2;

/** Monday 00:00 of the week of `date`, in the calendar's time zone (whatever its first weekday). */
export function recapWeekStart(date: Instant, calendar: FrenchCalendar): Instant {
  const startOfDay = calendar.startOfDay(date);
  // Gregorian weekday: 1 = Sunday, 2 = Monday … 7 = Saturday.
  const daysSinceMonday = (calendar.gregorianWeekday(startOfDay) + 5) % 7;
  return calendar.startOfDay(calendar.addingDays(-daysSinceMonday, startOfDay));
}

/** The first instant to read (`completed_at=gte.<…>`): Monday 00:00, 3 weeks before the week of `now`. */
export function recapReadStart(now: Instant, calendar: FrenchCalendar): Instant {
  let start = recapWeekStart(now, calendar);
  for (let week = 1; week < RECAP_WEEKS_READ; week += 1) {
    start = recapWeekStart(calendar.addingDays(-7, start), calendar);
  }
  return start;
}

/** The member with strictly more tasks than every other member, if any. */
function soleLeader(counts: Map<Uuid, number>): Uuid | null {
  let best = -1;
  for (const value of counts.values()) best = Math.max(best, value);
  if (best < 0) return null;
  const leaders = Array.from(counts.entries()).filter(([, value]) => value === best);
  return leaders.length === 1 ? leaders[0]![0] : null;
}

function ranks(lhs: WeeklyRecapEntry, rhs: WeeklyRecapEntry): number {
  if (lhs.count !== rhs.count) return rhs.count - lhs.count;
  const byName = compareNames(lhs.user.displayName, rhs.user.displayName);
  if (byName !== 0) return byName;
  return compareUuids(lhs.user.id, rhs.user.id);
}

/** The recap of the week of `now` from the group's done tasks since `recapReadStart` and its current members. */
export function computeWeeklyRecap(
  completions: readonly TaskCompletion[],
  members: readonly Membership[],
  now: Instant,
  calendar: FrenchCalendar,
): WeeklyRecap {
  const current = recapWeekStart(now, calendar);
  const end = recapWeekStart(calendar.addingDays(7, current), calendar);
  // starts[0] is the current week, starts[k] the week k weeks before it.
  const starts = [current];
  for (let week = 1; week < RECAP_WEEKS_READ; week += 1) {
    starts.push(recapWeekStart(calendar.addingDays(-7, starts[starts.length - 1]!), calendar));
  }

  const profiles = new Map<Uuid, UserProfile>();
  for (const member of members) profiles.set(member.user.id, member.user);

  let total = 0;
  const counts = starts.map(() => new Map<Uuid, number>());
  for (const completion of completions) {
    if (!(completion.completedAt < end)) continue;
    const week = starts.findIndex((start) => completion.completedAt >= start);
    if (week < 0) continue;
    if (week === 0) total += 1;
    const userId = completion.completedBy;
    if (userId !== null && profiles.has(userId)) {
      counts[week]!.set(userId, (counts[week]!.get(userId) ?? 0) + 1);
    }
  }

  const podium = Array.from(counts[0]!.entries())
    .map(([userId, count]) => ({ user: profiles.get(userId)!, count }))
    .sort(ranks)
    .slice(0, RECAP_PODIUM_SIZE);

  let streak: WeeklyRecapStreak | null = null;
  const leader = soleLeader(counts[0]!);
  const leaderProfile = leader === null ? undefined : profiles.get(leader);
  if (leader !== null && leaderProfile !== undefined) {
    let weeks = 1;
    for (const weekCounts of counts.slice(1)) {
      if (soleLeader(weekCounts) !== leader) break;
      weeks += 1;
    }
    if (weeks >= RECAP_MINIMUM_STREAK) streak = { user: leaderProfile, weeks };
  }

  return { weekStart: current, weekEnd: end, total, podium, streak };
}
