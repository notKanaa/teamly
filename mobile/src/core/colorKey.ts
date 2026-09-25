import { type Uuid, uuidString } from './uuid';

/**
 * A color of the « Équipe » palette, for groups and avatars (docs/CONTRACTS-V2.md §1). Stored as its exact text:
 * `Coral` and `''` are refused by the server (`invalid_color`); where a color is optional, null means « automatic »
 * (`automaticColor`). Declared in palette order (color pickers).
 */
export const COLOR_KEYS = ['indigo', 'violet', 'blue', 'teal', 'green', 'amber', 'orange', 'coral', 'pink'] as const;
export type ColorKey = (typeof COLOR_KEYS)[number];

/** The automatic colors, indexed by `djb2(id) % 9`; this order keeps the hues of the v1 avatars. */
export const AUTOMATIC_COLOR_ORDER: readonly ColorKey[] = [
  'blue',
  'indigo',
  'violet',
  'pink',
  'orange',
  'teal',
  'green',
  'coral',
  'amber',
];

const MASK_64 = (BigInt(1) << BigInt(64)) - BigInt(1);

/**
 * The color of a group or a person whose color is automatic: `h = 5381; for byte in utf8(uppercase uuid string):
 * h = h * 33 + byte` on a wrapping 64-bit unsigned integer, then `AUTOMATIC_COLOR_ORDER[h % 9]`.
 */
export function automaticColor(id: Uuid): ColorKey {
  let hash = BigInt(5381);
  const thirtyThree = BigInt(33);
  // The uppercase uuid string is ASCII: its UTF-8 bytes are its char codes.
  for (const character of uuidString(id)) {
    hash = (hash * thirtyThree + BigInt(character.charCodeAt(0))) & MASK_64;
  }
  return AUTOMATIC_COLOR_ORDER[Number(hash % BigInt(AUTOMATIC_COLOR_ORDER.length))]!;
}

/** `color`, or the automatic color of `id` when it is null. */
export function resolvedColor(color: ColorKey | null | undefined, id: Uuid): ColorKey {
  return color ?? automaticColor(id);
}

/** True for a stored color text of the palette (exact case). */
export function isColorKey(value: unknown): value is ColorKey {
  return typeof value === 'string' && (COLOR_KEYS as readonly string[]).includes(value);
}

/** The color of a stored text; null for NULL (automatic) and for a text unknown to this client. */
export function storedColor(text: string | null | undefined): ColorKey | null {
  return isColorKey(text) ? text : null;
}

/** French name of the color, for the accessibility labels of the pickers. */
export function colorLabel(key: ColorKey): string {
  switch (key) {
    case 'indigo':
      return 'Indigo';
    case 'violet':
      return 'Violet';
    case 'blue':
      return 'Bleu';
    case 'teal':
      return 'Turquoise';
    case 'green':
      return 'Vert';
    case 'amber':
      return 'Ambre';
    case 'orange':
      return 'Orange';
    case 'coral':
      return 'Corail';
    case 'pink':
      return 'Rose';
  }
}
