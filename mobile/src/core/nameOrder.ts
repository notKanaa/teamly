import type { GroupSummary, Membership } from './models';
import { compareStrings, foldCaseAndDiacritics } from './unicode';
import { compareUuids } from './uuid';

/**
 * Name order shared by every backend implementation (docs/CONTRACTS.md §4.3): fr_FR, case- and diacritic-insensitive,
 * then exact. `myGroups` and `members` are always returned in this order.
 */
export function nameKey(name: string): string {
  return foldCaseAndDiacritics(name);
}

/** Folded order first, then exact order; null when both names are identical. */
export function namePrecedes(lhs: string, rhs: string): boolean | null {
  const left = nameKey(lhs);
  const right = nameKey(rhs);
  if (left !== right) return compareStrings(left, right) < 0;
  if (lhs !== rhs) return compareStrings(lhs, rhs) < 0;
  return null;
}

/** A comparator from `namePrecedes` (0 for identical names). */
export function compareNames(lhs: string, rhs: string): number {
  const order = namePrecedes(lhs, rhs);
  if (order === null) return 0;
  return order ? -1 : 1;
}

/** `myGroups`: most recently active first, then name, then id. */
export function sortedGroups(groups: readonly GroupSummary[]): GroupSummary[] {
  return [...groups].sort((lhs, rhs) => {
    if (lhs.group.lastActivityAt !== rhs.group.lastActivityAt) {
      return lhs.group.lastActivityAt > rhs.group.lastActivityAt ? -1 : 1;
    }
    const byName = compareNames(lhs.group.name, rhs.group.name);
    if (byName !== 0) return byName;
    return compareUuids(lhs.group.id, rhs.group.id);
  });
}

/** `members`: admins first, then display name, then user id. */
export function sortedMembers(members: readonly Membership[]): Membership[] {
  return [...members].sort((lhs, rhs) => {
    if (lhs.role !== rhs.role) return lhs.role === 'admin' ? -1 : 1;
    const byName = compareNames(lhs.user.displayName, rhs.user.displayName);
    if (byName !== 0) return byName;
    return compareUuids(lhs.user.id, rhs.user.id);
  });
}
