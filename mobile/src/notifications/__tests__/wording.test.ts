import { readFileSync } from 'fs';
import { join } from 'path';

import { typographyProblems } from '@/core/__tests__/support';

// The French texts of the onboarding, « Réglages » and the notifications: « tu », and the no-break spaces.

const FILES = [
  'app/(app)/onboarding.tsx',
  'app/(app)/avatar.tsx',
  'app/(app)/(tabs)/settings.tsx',
  'ui/onboardingKit.tsx',
  'ui/settingsKit.tsx',
  'notifications/planning.ts',
  'notifications/push.ts',
];

/** `${…}` of a template literal, nested braces included, becomes « X ». */
function withoutInterpolations(template: string): string {
  let out = '';
  let depth = 0;
  for (let index = 0; index < template.length; index += 1) {
    if (depth === 0 && template.startsWith('${', index)) {
      depth = 1;
      index += 1;
      out += 'X';
    } else if (depth > 0) {
      if (template[index] === '{') depth += 1;
      if (template[index] === '}') depth -= 1;
    } else {
      out += template[index];
    }
  }
  return out;
}

function literals(source: string): string[] {
  const found: string[] = [];
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  const pattern = /'((?:[^'\\\n]|\\.)*)'|`((?:[^`\\]|\\.)*)`/g;
  for (const match of code.matchAll(pattern)) {
    const raw = match[1] ?? withoutInterpolations(match[2] ?? '');
    const text = raw.replace(/\\u\{a0\}/gi, '\u{a0}');
    // Only the sentences shown to the user (a letter and a space).
    if (/\p{L} /u.test(text)) found.push(text);
  }
  return found;
}

describe('wording of the notifications and settings screens', () => {
  const texts = FILES.flatMap((file) => literals(readFileSync(join(__dirname, '..', '..', file), 'utf8')));

  it('reads some texts', () => {
    expect(texts.length).toBeGreaterThan(20);
  });

  it('keeps the French typography', () => {
    const problems = texts.flatMap((text) => typographyProblems(text).map((problem) => `${problem} in « ${text} »`));
    expect(problems).toEqual([]);
  });

  it('says « tu »', () => {
    expect(texts.filter((text) => /\b(vous|votre|vos|êtes|avez)\b/iu.test(text))).toEqual([]);
  });
});
