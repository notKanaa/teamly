/**
 * 8-character group invite codes over an unambiguous alphabet (no 0/O/1/I), in sync with
 * `private.generate_invite_code()` and the `group_invites.code` check constraint.
 */
export const INVITE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export const INVITE_CODE_LENGTH = 8;

/**
 * Uppercases (full case mapping: `ß` → `SS`), then keeps only the code points A–Z and 0–9, like the SQL
 * `join_group_by_code`: « L\u{301}YLAS234 » → « LYLAS234 ».
 */
export function normalizeInviteCode(input: string): string {
  let out = '';
  for (const character of input.toUpperCase()) {
    if (/^[A-Z0-9]$/.test(character)) out += character;
  }
  return out;
}

/** The normalized code (`ABCDEFGH`), or null when the input cannot be a valid code. */
export function parseInviteCode(input: string): string | null {
  const value = normalizeInviteCode(input);
  if (value.length !== INVITE_CODE_LENGTH) return null;
  for (const character of value) {
    if (!INVITE_ALPHABET.includes(character)) return null;
  }
  return value;
}

/** Display form: `ABCD-EFGH`. */
export function formatInviteCode(value: string): string {
  const half = INVITE_CODE_LENGTH / 2;
  return `${value.slice(0, half)}-${value.slice(half)}`;
}

/**
 * Live formatting of the code field (`JoinGroupViewModel.format`): `abcd efgh` → `ABCD-EFGH`, `abcde` → `ABCD-E`;
 * at most 8 letters or digits.
 */
export function formatInviteCodeInput(input: string): string {
  const characters = normalizeInviteCode(input).slice(0, INVITE_CODE_LENGTH);
  const half = INVITE_CODE_LENGTH / 2;
  if (characters.length <= half) return characters;
  return `${characters.slice(0, half)}-${characters.slice(half)}`;
}
