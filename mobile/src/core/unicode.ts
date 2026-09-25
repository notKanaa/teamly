/**
 * Unicode helpers shared by the core: code points (what Postgres `char_length` counts), a Swift-like string order
 * (Unicode scalar values of the NFC form), the case- and diacritic-insensitive keys of the French sorts, and
 * letters/graphemes. Only APIs available in Hermes are used at runtime: `\p{…}` regular expressions are tried once and
 * replaced by a fallback when the engine lacks them.
 */

/** The code points of `value` (a lone surrogate counts as one). */
export function codePoints(value: string): string[] {
  return Array.from(value);
}

/** Number of code points (Postgres `char_length`, Swift `unicodeScalars.count`). */
export function codePointLength(value: string): number {
  let count = 0;
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  for (const _ of value) count += 1;
  return count;
}

/** Byte length of the UTF-8 encoding (a lone surrogate is encoded as U+FFFD, 3 bytes). */
export function utf8Length(value: string): number {
  let bytes = 0;
  for (const character of value) {
    const code = character.codePointAt(0) ?? 0;
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code < 0x10000) bytes += 3;
    else bytes += 4;
  }
  return bytes;
}

function safeNormalize(value: string, form: 'NFC' | 'NFD' | 'NFKD'): string {
  try {
    return value.normalize(form);
  } catch {
    return value;
  }
}

/**
 * Swift's `String` order: the Unicode scalar values of the NFC forms, compared one by one (JavaScript's `<` compares
 * UTF-16 code units, which differs above U+FFFF).
 */
export function compareStrings(lhs: string, rhs: string): number {
  if (lhs === rhs) return 0;
  const left = codePoints(safeNormalize(lhs, 'NFC'));
  const right = codePoints(safeNormalize(rhs, 'NFC'));
  const length = Math.min(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const a = left[index]!.codePointAt(0)!;
    const b = right[index]!.codePointAt(0)!;
    if (a !== b) return a < b ? -1 : 1;
  }
  if (left.length === right.length) return 0;
  return left.length < right.length ? -1 : 1;
}

/** Combining marks removed by the diacritic-insensitive folds (Latin, Greek and Cyrillic accents, and more). */
const COMBINING_MARKS =
  /[\u{0300}-\u{036f}\u{0483}-\u{0489}\u{0591}-\u{05bd}\u{1ab0}-\u{1aff}\u{1dc0}-\u{1dff}\u{20d0}-\u{20ff}\u{fe20}-\u{fe2f}]/gu;

/**
 * Case- and diacritic-insensitive key, like Foundation's `folding(options: [.caseInsensitive, .diacriticInsensitive])`
 * (`NameOrder.key`): « Élodie » and « elodie » have the same key.
 */
export function foldCaseAndDiacritics(value: string): string {
  return safeNormalize(safeNormalize(value, 'NFD').replace(COMBINING_MARKS, '').toLowerCase(), 'NFC');
}

/**
 * The same, also width-insensitive (full-width letters read as ASCII), with the French ligatures spelled out
 * (`TaskSort.titleKey`): « œufs » sorts as « oeufs ».
 */
export function foldForTitleSort(value: string): string {
  return safeNormalize(safeNormalize(value, 'NFKD').replace(COMBINING_MARKS, '').toLowerCase(), 'NFC')
    .replace(/œ/g, 'oe')
    .replace(/æ/g, 'ae')
    .replace(/ß/g, 'ss');
}

type LetterTest = (character: string) => boolean;

function makeLetterOrNumberTest(): LetterTest {
  try {
    const pattern = new RegExp('^[\\p{L}\\p{N}]', 'u');
    return (character) => pattern.test(character);
  } catch {
    // Engines without Unicode property escapes: cased letters, digits, and the main uncased scripts.
    return (character) => {
      if (/[0-9]/.test(character)) return true;
      if (character.toLowerCase() !== character.toUpperCase()) return true;
      const code = character.codePointAt(0) ?? 0;
      return (
        code === 0xaa ||
        code === 0xba ||
        (code >= 0x0590 && code <= 0x08ff) || // Hebrew, Arabic…
        (code >= 0x0900 && code <= 0x0dff) || // Indic scripts
        (code >= 0x0e00 && code <= 0x0eff) || // Thai, Lao
        (code >= 0x1100 && code <= 0x11ff) || // Hangul Jamo
        (code >= 0x3040 && code <= 0x30ff) || // Hiragana, Katakana
        (code >= 0x3400 && code <= 0x9fff) || // CJK
        (code >= 0xac00 && code <= 0xd7af) // Hangul syllables
      );
    };
  }
}

/** Swift's `Character.isLetter || Character.isNumber` on the first code point of `character`. */
export const isLetterOrNumber: LetterTest = makeLetterOrNumberTest();

/** Whitespace as Swift's `Character.isWhitespace` sees it (JavaScript's `\s` covers the same spaces). */
export function isWhitespace(character: string): boolean {
  return /^\s$/.test(character) || character === '\u{85}';
}

interface SegmenterLike {
  segment(input: string): Iterable<{ segment: string }>;
}

function makeGraphemeSplitter(): (value: string) => string[] {
  const IntlWithSegmenter = Intl as unknown as {
    Segmenter?: new (locale: string, options: { granularity: 'grapheme' }) => SegmenterLike;
  };
  if (typeof IntlWithSegmenter.Segmenter === 'function') {
    try {
      const segmenter = new IntlWithSegmenter.Segmenter('fr', { granularity: 'grapheme' });
      return (value) => Array.from(segmenter.segment(value), (part) => part.segment);
    } catch {
      // Fall through to the approximation below.
    }
  }
  // Approximation: code points of the NFC form, combining marks, joiners and variation selectors kept with the
  // character before them.
  return (value) => {
    const out: string[] = [];
    let joinNext = false;
    for (const character of safeNormalize(value, 'NFC')) {
      const code = character.codePointAt(0) ?? 0;
      const extends_ =
        (code >= 0x0300 && code <= 0x036f) ||
        (code >= 0xfe00 && code <= 0xfe0f) ||
        code === 0x200d ||
        (code >= 0x1f3fb && code <= 0x1f3ff) ||
        code === 0x20e3;
      if (out.length > 0 && (extends_ || joinNext)) {
        out[out.length - 1] += character;
      } else {
        out.push(character);
      }
      joinNext = code === 0x200d;
    }
    return out;
  };
}

/** The user-perceived characters of `value` (Swift's `Character`s). */
export const graphemes: (value: string) => string[] = makeGraphemeSplitter();
