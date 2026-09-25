/**
 * Ids are UUID strings as Postgres prints them: lowercase and canonical. The Swift core compares and hashes the
 * uppercase form (`UUID.uuidString`): `uuidString` gives it, and `compareUuids` orders ids like Swift (and like
 * Postgres' byte order on `uuid` values).
 */
export type Uuid = string;

const UUID_PATTERN = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

/** True for a canonical UUID string, in any case. */
export function isUuid(text: string): boolean {
  return UUID_PATTERN.test(text);
}

/** The lowercase form used everywhere in the app (reads, filters, RPC parameters). */
export function normalizeUuid(id: string): Uuid {
  return id.toLowerCase();
}

/** `UUID.uuidString` of the Swift core: the uppercase form. */
export function uuidString(id: Uuid): string {
  return id.toUpperCase();
}

/** Ascending order of `uuidString` (digits before letters in both cases, so it is also the lowercase order). */
export function compareUuids(lhs: Uuid, rhs: Uuid): number {
  const left = uuidString(lhs);
  const right = uuidString(rhs);
  if (left === right) return 0;
  return left < right ? -1 : 1;
}

/** Distinct ids, sorted with `compareUuids` (assignees, rotations sent as sets). */
export function sortedUniqueUuids(ids: readonly Uuid[]): Uuid[] {
  return Array.from(new Set(ids.map(normalizeUuid))).sort(compareUuids);
}

/** A random v4 UUID. Not cryptographic: channel names and a random palette color only. */
export function randomUuid(): Uuid {
  const hex = '0123456789abcdef';
  let out = '';
  for (let index = 0; index < 36; index += 1) {
    if (index === 8 || index === 13 || index === 18 || index === 23) {
      out += '-';
    } else if (index === 14) {
      out += '4';
    } else if (index === 19) {
      out += hex[8 + Math.floor(Math.random() * 4)];
    } else {
      out += hex[Math.floor(Math.random() * 16)];
    }
  }
  return out;
}
