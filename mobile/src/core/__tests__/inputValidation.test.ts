import { COLOR_KEYS } from '../colorKey';
import {
  isForbiddenInEmoji,
  isValidTimeZoneId,
  normalizedEmail,
  trimmed,
  validateChecklist,
  validateChecklistItemTitle,
  validateColorKey,
  validateDisplayName,
  validateDueDate,
  validateEmail,
  validateEmoji,
  validateGroupName,
  validatePassword,
  validateRecurrence,
  validateRecurrenceShape,
  validateRotation,
  validateSignUp,
  validateTaskDetails,
  validateTaskTitle,
} from '../inputValidation';
import { formatInviteCode, formatInviteCodeInput, normalizeInviteCode, parseInviteCode } from '../inviteCode';
import { type Frequency, makeRule } from '../models';
import { codePointLength } from '../unicode';
import { randomUuid } from '../uuid';
import { thrownKind } from './support';

describe('InputValidation v1 (docs/CONTRACTS.md §1)', () => {
  /** The pinned trim list, the same on every platform. */
  const TRIMMED = [0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x85, 0xa0, 0x1680];
  for (let value = 0x2000; value <= 0x200b; value += 1) TRIMMED.push(value);
  TRIMMED.push(0x2028, 0x2029, 0x202f, 0x205f, 0x3000);

  it('trims exactly the pinned code points', () => {
    const found: number[] = [];
    for (let value = 1; value <= 0x3000; value += 1) {
      if (value >= 0xd800 && value <= 0xdfff) continue;
      const character = String.fromCodePoint(value);
      if (trimmed(`${character}x${character}`) === 'x') found.push(value);
    }
    expect(found).toEqual(TRIMMED);
    for (const value of [0x1c, 0x1d, 0x1e, 0x1f, 0x180e, 0xfeff]) {
      const text = `${String.fromCodePoint(value)}x`;
      expect(trimmed(text)).toBe(text);
    }
  });

  it('trims code points, not graphemes', () => {
    expect(trimmed(' \u{301}x ')).toBe('\u{301}x');
    expect(trimmed('\u{3000}\u{200b} Titre \n\t')).toBe('Titre');
    expect(trimmed(' \n ')).toBe('');
    expect(trimmed('')).toBe('');
  });

  it('counts the text limits in Unicode scalars', () => {
    expect(validateDisplayName('  Zoé  ')).toBe('Zoé');
    expect(codePointLength(validateDisplayName('é'.repeat(50)))).toBe(50);
    expect(thrownKind(() => validateDisplayName('é'.repeat(51)))).toBe('invalidDisplayName');
    expect(thrownKind(() => validateDisplayName(' \u{200b} '))).toBe('invalidDisplayName');
    expect(thrownKind(() => validateGroupName('x'.repeat(61)))).toBe('invalidName');
    expect(validateGroupName('x'.repeat(60))).toHaveLength(60);
    expect(thrownKind(() => validateTaskTitle(''))).toBe('invalidTitle');
    expect(thrownKind(() => validateTaskTitle('x'.repeat(201)))).toBe('invalidTitle');
    expect(validateTaskDetails('   ')).toBeNull();
    expect(validateTaskDetails(' d ')).toBe('d');
    expect(thrownKind(() => validateTaskDetails('x'.repeat(5001)))).toBe('invalidDetails');
    // An emoji outside the BMP counts once (not as two UTF-16 units).
    expect(validateDisplayName('😀'.repeat(50))).toBe('😀'.repeat(50));
  });

  it('refuses U+0000 with the field’s error', () => {
    expect(thrownKind(() => validateDisplayName('a\u{0}'))).toBe('invalidDisplayName');
    expect(thrownKind(() => validateGroupName('a\u{0}'))).toBe('invalidName');
    expect(thrownKind(() => validateTaskTitle('a\u{0}b'))).toBe('invalidTitle');
    expect(thrownKind(() => validateTaskDetails('\u{0}'))).toBe('invalidDetails');
  });

  it('measures passwords in UTF-8 bytes', () => {
    expect(() => validatePassword('éééé')).not.toThrow(); // 8 bytes
    expect(() => validatePassword('😀😀')).not.toThrow(); // 8 bytes
    expect(() => validatePassword('a'.repeat(72))).not.toThrow();
    expect(thrownKind(() => validatePassword('abc1234'))).toBe('weakPassword');
    expect(thrownKind(() => validatePassword('ééé1'))).toBe('weakPassword');
    expect(thrownKind(() => validatePassword('a'.repeat(73)))).toBe('invalidInput');
  });

  it('normalizes and checks e-mails like Supabase Auth', () => {
    expect(validateEmail('  Zoe.Leroy@Example.COM ')).toBe('zoe.leroy@example.com');
    expect(normalizedEmail(' A@B.fr\n')).toBe('a@b.fr');
    for (const valid of ['user@localhost', '.x@example.com', 'a..b@example.com', "o'neil+tag@sub-domain.example.fr", '1@2.3']) {
      expect(validateEmail(valid)).toBe(valid.toLowerCase());
    }
    const label63 = 'a'.repeat(63);
    expect(validateEmail(`x@${label63}.fr`)).toBe(`x@${label63}.fr`);
    for (const invalid of [
      '',
      'x',
      'x@',
      '@x.fr',
      'x@@x.fr',
      'x@y@z.fr',
      'x y@z.fr',
      'ü@x.fr',
      'x@exämple.fr',
      'x@-x.fr',
      'x@x-.fr',
      'x@x..fr',
      'x@.x.fr',
      'x@x.fr.',
      `x@${label63}a.fr`,
      'x@x_y.fr',
      `${'a'.repeat(251)}@x.fr`,
    ]) {
      expect([invalid, thrownKind(() => validateEmail(invalid))]).toEqual([invalid, 'invalidEmail']);
    }
  });

  it('checks the sign-up e-mail, then the password, then the name', () => {
    expect(thrownKind(() => validateSignUp('x', 'court', ''))).toBe('invalidEmail');
    expect(thrownKind(() => validateSignUp('a@b.fr', 'court', ''))).toBe('weakPassword');
    expect(thrownKind(() => validateSignUp('a@b.fr', 'motdepasse', ' '))).toBe('invalidDisplayName');
    expect(validateSignUp(' A@B.fr ', 'motdepasse', ' Zoé ')).toEqual({ email: 'a@b.fr', displayName: 'Zoé' });
  });

  it('accepts due dates in [1970, 10000)', () => {
    expect(validateDueDate(null)).toBeNull();
    expect(validateDueDate(0)).toBe(0);
    expect(validateDueDate(253_402_300_799_999)).toBe(253_402_300_799_999);
    expect(thrownKind(() => validateDueDate(-1))).toBe('invalidInput');
    expect(thrownKind(() => validateDueDate(253_402_300_800_000))).toBe('invalidInput');
  });
});

describe('InviteCode', () => {
  it('normalizes per code point, like the SQL', () => {
    expect(normalizeInviteCode('abcd-efgh')).toBe('ABCDEFGH');
    expect(normalizeInviteCode(' L\u{301}YLAS234 ')).toBe('LYLAS234');
    expect(normalizeInviteCode('straße')).toBe('STRASSE');
    expect(parseInviteCode('lylas-234')).toBe('LYLAS234');
    expect(parseInviteCode('ABCD-EFG')).toBeNull();
    expect(parseInviteCode('ABCD-EFG0')).toBeNull(); // 0 is not in the alphabet
    expect(parseInviteCode('ABCD-EFGI')).toBeNull(); // nor I
    expect(formatInviteCode('LYLAS234')).toBe('LYLA-S234');
  });

  it('formats the code field live', () => {
    expect(formatInviteCodeInput('abcd efgh')).toBe('ABCD-EFGH');
    expect(formatInviteCodeInput('abcde')).toBe('ABCD-E');
    expect(formatInviteCodeInput('abcd')).toBe('ABCD');
    expect(formatInviteCodeInput('abcdefghijk')).toBe('ABCD-EFGH');
    expect(formatInviteCodeInput('')).toBe('');
  });
});

describe('InputValidation v2 (docs/CONTRACTS-V2.md §1, §3, §5)', () => {
  it('trims emojis and reads blank as none', () => {
    expect(validateEmoji(null)).toBeNull();
    expect(validateEmoji(' \t🏠 ')).toBe('🏠');
    expect(validateEmoji(' \u{200b}\u{3000} ')).toBeNull();
    expect(validateEmoji('')).toBeNull();
  });

  it('accepts emoji sequences', () => {
    const family = '👨\u{200d}👩\u{200d}👧\u{200d}👦';
    expect(codePointLength(family)).toBe(7);
    expect(validateEmoji(family)).toBe(family);
    expect(validateEmoji('🇫🇷')).toBe('🇫🇷');
    expect(validateEmoji('1\u{fe0f}\u{20e3}')).toBe('1\u{fe0f}\u{20e3}');
    expect(validateEmoji('⚽')).toBe('⚽');
    expect(validateEmoji('x')).toBe('x');
  });

  it('accepts at most sixteen code points', () => {
    expect(validateEmoji('😀'.repeat(16))).toBe('😀'.repeat(16));
    expect(thrownKind(() => validateEmoji('😀'.repeat(17)))).toBe('invalidAppearance');
  });

  it.each(['😀 😀', '😀\u{a0}😀', '😀\u{200b}😀', '😀\u{7}', '😀\u{85}😀', '😀\u{9f}', '😀\u{1f}', '\u{0}', '😀\u{0}', 'x y'])(
    'refuses spaces and controls in %j',
    (value) => {
      expect(thrownKind(() => validateEmoji(value))).toBe('invalidAppearance');
    },
  );

  it('pins the forbidden emoji code points', () => {
    const expected: number[] = [];
    for (let value = 0; value <= 0x20; value += 1) expected.push(value);
    for (let value = 0x7f; value <= 0xa0; value += 1) expected.push(value);
    expected.push(0x1680);
    for (let value = 0x2000; value <= 0x200b; value += 1) expected.push(value);
    expected.push(0x2028, 0x2029, 0x202f, 0x205f, 0x3000);
    const found: number[] = [];
    for (let value = 0; value <= 0x3100; value += 1) if (isForbiddenInEmoji(value)) found.push(value);
    expect(found).toEqual(expected);
    expect(isForbiddenInEmoji(0x200d)).toBe(false);
    expect(isForbiddenInEmoji(0xfe0f)).toBe(false);
  });

  it('keeps color keys exact', () => {
    expect(validateColorKey(null)).toBeNull();
    for (const key of COLOR_KEYS) expect(validateColorKey(key)).toBe(key);
    for (const invalid of ['Coral', '', 'red', ' coral', 'CORAL']) {
      expect(thrownKind(() => validateColorKey(invalid))).toBe('invalidAppearance');
    }
  });

  const rule = (frequency: Frequency = 'daily', options: { interval?: number; weekdays?: number[]; tz?: string } = {}) =>
    makeRule({ frequency, interval: options.interval ?? 1, weekdays: options.weekdays ?? null, timeZoneId: options.tz ?? 'Europe/Paris' });

  it('accepts intervals of 1 to 52', () => {
    expect(validateRecurrenceShape(rule('daily', { interval: 1 }))).toEqual(rule('daily', { interval: 1 }));
    expect(validateRecurrenceShape(rule('daily', { interval: 52 }))).toEqual(rule('daily', { interval: 52 }));
    for (const interval of [0, 53, -1]) {
      expect(thrownKind(() => validateRecurrenceShape(rule('daily', { interval })))).toBe('invalidRecurrence');
    }
  });

  it('accepts weekdays on weekly rules only', () => {
    expect(validateRecurrenceShape(rule('weekly', { weekdays: [1, 3, 5] })).weekdays).toEqual([1, 3, 5]);
    expect(validateRecurrenceShape(rule('weekly', { weekdays: [1, 2, 3, 4, 5, 6, 7] })).weekdays).toHaveLength(7);
    expect(validateRecurrenceShape(rule('weekly')).weekdays).toBeNull();
    for (const invalid of [
      rule('daily', { weekdays: [1] }),
      rule('monthly', { weekdays: [1] }),
      rule('weekly', { weekdays: [] }),
      rule('weekly', { weekdays: [0] }),
      rule('weekly', { weekdays: [8] }),
      rule('weekly', { weekdays: [1, 8] }),
    ]) {
      expect(thrownKind(() => validateRecurrenceShape(invalid))).toBe('invalidRecurrence');
    }
  });

  it('accepts exact IANA time zone names only', () => {
    for (const valid of ['Europe/Paris', 'UTC', 'America/Argentina/Buenos_Aires', 'America/New_York', 'Asia/Tokyo']) {
      expect([valid, isValidTimeZoneId(valid)]).toEqual([valid, true]);
      expect(validateRecurrenceShape(rule('daily', { tz: valid })).timeZoneId).toBe(valid);
    }
    for (const invalid of [
      '',
      'Europe/Pariss',
      'europe/paris',
      'EUROPE/PARIS',
      'posix/Europe/Paris',
      'right/Europe/Paris',
      'Factory',
      'UTC+3',
      'GMT+3',
      'CEST',
      'Europe/Paris ',
      'Mars/Olympus_Mons',
      // An alias in another case (engines canonicalize it to America/Buenos_Aires).
      'america/argentina/buenos_aires',
      'AMERICA/ARGENTINA/BUENOS_AIRES',
    ]) {
      expect([invalid, isValidTimeZoneId(invalid)]).toEqual([invalid, false]);
      expect(thrownKind(() => validateRecurrenceShape(rule('daily', { tz: invalid })))).toBe('invalidRecurrence');
    }
  });

  it('needs a due date after the shape', () => {
    const due = 2_000_000_000_000;
    expect(validateRecurrence(null, null)).toBeNull();
    expect(validateRecurrence(null, due)).toBeNull();
    expect(validateRecurrence(rule(), due)).toEqual(rule());
    expect(thrownKind(() => validateRecurrence(rule(), null))).toBe('recurrenceNeedsDueDate');
    expect(thrownKind(() => validateRecurrence(rule('daily', { interval: 0 }), null))).toBe('invalidRecurrence');
  });

  it('checks rotations', () => {
    const ids = Array.from({ length: 21 }, () => randomUuid());
    const weekly = rule('weekly');
    expect(validateRotation([], null)).toEqual([]);
    expect(validateRotation([], weekly)).toEqual([]);
    expect(validateRotation(ids.slice(0, 2), weekly)).toEqual(ids.slice(0, 2));
    expect(validateRotation(ids.slice(0, 20), weekly)).toEqual(ids.slice(0, 20));
    expect(thrownKind(() => validateRotation(ids.slice(0, 2), null))).toBe('invalidRotation');
    expect(thrownKind(() => validateRotation([ids[0]!], weekly))).toBe('invalidRotation');
    expect(thrownKind(() => validateRotation(ids, weekly))).toBe('invalidRotation');
    expect(thrownKind(() => validateRotation([ids[0]!, ids[1]!, ids[0]!], weekly))).toBe('invalidRotation');
  });

  it('checks checklist item titles', () => {
    expect(validateChecklistItemTitle('  Premier ')).toBe('Premier');
    expect(codePointLength(validateChecklistItemTitle('é'.repeat(200)))).toBe(200);
    for (const invalid of ['', ' \n ', 'é'.repeat(201), 'a\u{0}']) {
      expect(thrownKind(() => validateChecklistItemTitle(invalid))).toBe('invalidChecklistItem');
    }
  });

  it('checks every title, then the count', () => {
    expect(validateChecklist([])).toEqual([]);
    expect(validateChecklist(['  Premier ', 'Deuxième', 'Troisième'])).toEqual(['Premier', 'Deuxième', 'Troisième']);
    const thirty = Array.from({ length: 30 }, () => 'x');
    expect(validateChecklist(thirty)).toEqual(thirty);
    expect(thrownKind(() => validateChecklist([...thirty, 'x']))).toBe('tooManyChecklistItems');
    expect(thrownKind(() => validateChecklist([...thirty, 'x', 'y'.repeat(201)]))).toBe('invalidChecklistItem');
    expect(thrownKind(() => validateChecklist(['Ok', '  ']))).toBe('invalidChecklistItem');
  });
});
