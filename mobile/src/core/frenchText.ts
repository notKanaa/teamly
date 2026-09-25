import { trimmed } from './inputValidation';
import { graphemes, isLetterOrNumber, isWhitespace } from './unicode';

// French wording helpers (Swift `FrenchText`, `Initials`, `GroupShortName`): guillemets, the elision of « de », first
// names, feminine ordinals and counts. The app's typography: the apostrophe ’ (U+2019) and a no-break space (U+00A0)
// inside « » and before « ? ! : ; ».

/** `«\u{a0}text\u{a0}»`: guillemets with a no-break space inside each of them. */
export function quoted(text: string): string {
  return `«\u{a0}${text}\u{a0}»`;
}

const VOWELS = new Set(['a', 'à', 'â', 'ä', 'e', 'é', 'è', 'ê', 'ë', 'i', 'î', 'ï', 'o', 'ô', 'ö', 'u', 'ù', 'û', 'ü', 'œ', 'æ']);

/** True when `word` starts with a vowel, accented or not, in any case (« h » and « y » are left out). */
export function startsWithVowel(word: string): boolean {
  const first = graphemes(word)[0];
  if (first === undefined) return false;
  const lowered = Array.from(first.normalize('NFC').toLowerCase())[0];
  return lowered !== undefined && VOWELS.has(lowered);
}

/** « d’ » before a vowel (« d’Inès »), « de » and a space otherwise (« de Lucas »). */
export function dePrefix(word: string): string {
  return startsWithVowel(word) ? 'd’' : 'de ';
}

/** « de Lucas », « d’Inès », « d’un ancien membre ». */
export function de(word: string): string {
  return dePrefix(word) + word;
}

function splitWords(text: string, separator: (character: string) => boolean): string[] {
  const words: string[] = [];
  let current = '';
  for (const character of text) {
    if (separator(character)) {
      if (current !== '') words.push(current);
      current = '';
    } else {
      current += character;
    }
  }
  if (current !== '') words.push(current);
  return words;
}

/** The first word of a display name (« Camille Martin » → « Camille », « Jean-Pierre Durand » → « Jean-Pierre »). */
export function firstName(displayName: string): string {
  const value = trimmed(displayName);
  return splitWords(value, isWhitespace)[0] ?? value;
}

/** Feminine ordinal of a place or a week: « 1re », « 2e », « 3e ». */
export function ordinal(value: number): string {
  return value === 1 ? '1re' : `${value}e`;
}

/** True when a count takes the singular in French (0 and 1). */
export function isSingular(value: number): boolean {
  return value <= 1;
}

/** A count and its noun: « 1 tâche », « 3 tâches », « 0 tâche ». */
export function frenchCount(value: number, singular: string, plural: string): string {
  return `${value} ${isSingular(value) ? singular : plural}`;
}

/** Uppercases the first character (`aujourd’hui à 20:00` → `Aujourd’hui à 20:00`). */
export function capitalizingFirstLetter(text: string): string {
  const characters = graphemes(text);
  if (characters.length === 0) return text;
  return characters[0]!.toUpperCase() + characters.slice(1).join('');
}

/** Shown when a name has no letter nor digit, and for people the app does not know. */
export const UNKNOWN_INITIALS = '?';

/**
 * Initials of a name, as the avatars show them: the first letter or digit of the first two words (« Camille Martin »
 * → « CM », « Coloc’ rue des Lilas » → « CR », « Jean-Pierre » → « JP »), uppercased; « ? » when there is none.
 */
export function initialsOf(name: string, maxLetters = 2): string {
  const letters: string[] = [];
  for (const word of splitWords(name.normalize('NFC'), (character) => isWhitespace(character) || character === '-')) {
    const first = graphemes(word).find((character) => isLetterOrNumber(character));
    if (first !== undefined) letters.push(first);
    if (letters.length >= maxLetters) break;
  }
  const initials = letters.join('').toUpperCase();
  return initials === '' ? UNKNOWN_INITIALS : initials;
}

/** Longest short name of a group chip. */
export const GROUP_SHORT_NAME_MAX = 14;

const LEADING_ARTICLES = new Set([
  'le',
  'la',
  'les',
  'un',
  'une',
  'des',
  'du',
  'de',
  'mon',
  'ma',
  'mes',
  'ton',
  'ta',
  'tes',
  'notre',
  'nos',
  'votre',
  'vos',
  'the',
  'a',
  'an',
]);

/**
 * The short name of a group for the chips outside the group (« Mes tâches »): the whole name up to 14 characters;
 * otherwise its first significant word (« Les copains du foot » → « Copains »), capitalized, shortened with « … » when
 * still too long. « Coloc’ rue des Lilas » → « Coloc’ ».
 */
export function groupShortName(name: string): string {
  const value = trimmed(name);
  if (graphemes(value).length <= GROUP_SHORT_NAME_MAX) return value;
  const words = splitWords(value, isWhitespace);
  const word = words.find((candidate) => !LEADING_ARTICLES.has(candidate.toLowerCase())) ?? words[0] ?? value;
  const short = capitalizingFirstLetter(word);
  const characters = graphemes(short);
  if (characters.length <= GROUP_SHORT_NAME_MAX) return short;
  return characters.slice(0, GROUP_SHORT_NAME_MAX - 1).join('') + '…';
}
