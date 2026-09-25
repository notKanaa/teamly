import { Platform, useColorScheme, type TextStyle, type ViewStyle } from 'react-native';

import type { ColorKey } from '@/core/colorKey';
import type { TaskPriority, TaskStatus } from '@/core/models';

// Design tokens of docs/DESIGN-V2.md §3–§4, light and dark.

export interface Soft {
  bg: string;
  text: string;
}

export interface Theme {
  dark: boolean;
  background: string;
  card: string;
  track: string;
  hairline: string;
  textPrimary: string;
  textSecondary: string;
  /** Accent as text (links, selection). */
  accent: string;
  /** Accent as a fill (primary buttons). */
  accentFill: string;
  accentSoft: Soft;
  onFill: string;
  danger: Soft;
  /** Inactive onboarding steps, dashed borders, outlines of idle filter chips. */
  trackStrong: string;
  /** Decorative glyphs only (« Personne » circle, drag handles), never text. */
  textTertiary: string;
  /** « Priorité basse », « +N » circles. */
  neutral: Soft;
  /** The red count badge of the tab bar. */
  badge: string;
  fill: Record<ColorKey, string>;
  soft: Record<ColorKey, Soft>;
  cardShadow: ViewStyle;
  /** `Elevation.subtle`: fields. */
  subtleShadow: ViewStyle;
  /** `Elevation.raised`: floating bars and menus. */
  raisedShadow: ViewStyle;
  /** The soft accent shadow of primary buttons (none in dark mode). */
  accentShadow: ViewStyle;
}

const FILL: Record<ColorKey, string> = {
  indigo: '#4B3BE6',
  violet: '#7C3AED',
  blue: '#2563EB',
  teal: '#0F766E',
  green: '#15803D',
  amber: '#A16207',
  orange: '#C2410C',
  coral: '#D6385A',
  pink: '#BE185D',
};

const SOFT_LIGHT: Record<ColorKey, Soft> = {
  indigo: { bg: '#ECEAFD', text: '#4B3BE6' },
  violet: { bg: '#EDE9FE', text: '#6D28D9' },
  blue: { bg: '#DBEAFE', text: '#1D4ED8' },
  teal: { bg: '#CCFBF1', text: '#0F766E' },
  green: { bg: '#DCFCE7', text: '#15803D' },
  amber: { bg: '#FEF3C7', text: '#B45309' },
  orange: { bg: '#FFEDD5', text: '#C2410C' },
  coral: { bg: '#FFE4E9', text: '#B01F3F' },
  pink: { bg: '#FCE7F3', text: '#BE185D' },
};

const SOFT_DARK: Record<ColorKey, Soft> = {
  indigo: { bg: '#2A2650', text: '#B7B0FF' },
  violet: { bg: '#2A1F4A', text: '#B9A6FF' },
  blue: { bg: '#172542', text: '#93B4FF' },
  teal: { bg: '#0F2E2B', text: '#5EEAD4' },
  green: { bg: '#12301F', text: '#6EE7A8' },
  amber: { bg: '#3A2A0E', text: '#FCC76A' },
  orange: { bg: '#3B2210', text: '#FFA86B' },
  coral: { bg: '#3A1D28', text: '#FF8FA3' },
  pink: { bg: '#3B1830', text: '#F9A8D4' },
};

const shadow: ViewStyle = Platform.select<ViewStyle>({
  web: { boxShadow: '0 6px 12px rgba(0,0,0,0.06), 0 1px 1px rgba(0,0,0,0.04)' } as ViewStyle,
  default: { shadowColor: '#000', shadowOpacity: 0.06, shadowRadius: 12, shadowOffset: { width: 0, height: 6 }, elevation: 2 },
});

const subtle: ViewStyle = Platform.select<ViewStyle>({
  web: { boxShadow: '0 1px 2px rgba(22,20,40,0.06)' } as ViewStyle,
  default: { shadowColor: '#161428', shadowOpacity: 0.06, shadowRadius: 2, shadowOffset: { width: 0, height: 1 }, elevation: 1 },
});

const raised: ViewStyle = Platform.select<ViewStyle>({
  web: { boxShadow: '0 10px 28px rgba(22,20,40,0.12)' } as ViewStyle,
  default: { shadowColor: '#161428', shadowOpacity: 0.12, shadowRadius: 14, shadowOffset: { width: 0, height: 8 }, elevation: 8 },
});

const accentShadow: ViewStyle = Platform.select<ViewStyle>({
  web: { boxShadow: '0 8px 18px rgba(75,59,230,0.28)' } as ViewStyle,
  default: { shadowColor: '#4B3BE6', shadowOpacity: 0.28, shadowRadius: 12, shadowOffset: { width: 0, height: 6 }, elevation: 4 },
});

const darkEdge: ViewStyle = { borderWidth: 1, borderColor: '#2B2840' };

export const lightTheme: Theme = {
  dark: false,
  background: '#F4F3F8',
  card: '#FFFFFF',
  track: '#E9E7F0',
  hairline: '#F1EFF6',
  textPrimary: '#16141F',
  textSecondary: '#5F5C6E',
  accent: '#4B3BE6',
  accentFill: '#4B3BE6',
  accentSoft: { bg: '#ECEAFD', text: '#4B3BE6' },
  onFill: '#FFFFFF',
  danger: { bg: '#FFE4E6', text: '#BE123C' },
  trackStrong: '#DDDAE8',
  textTertiary: '#A8A4B8',
  neutral: { bg: '#EEEDF3', text: '#5F5C6E' },
  badge: '#FF3B30',
  fill: FILL,
  soft: SOFT_LIGHT,
  cardShadow: shadow,
  subtleShadow: subtle,
  raisedShadow: raised,
  accentShadow,
};

export const darkTheme: Theme = {
  dark: true,
  background: '#0F0E17',
  card: '#1C1A27',
  track: '#2B2840',
  hairline: '#2B2840',
  textPrimary: '#F4F3F8',
  textSecondary: '#ABA8BD',
  accent: '#9D93FF',
  accentFill: '#5B4CF0',
  accentSoft: { bg: '#2A2650', text: '#B7B0FF' },
  onFill: '#FFFFFF',
  danger: { bg: '#3A1818', text: '#FF8B8B' },
  trackStrong: '#3A3656',
  textTertiary: '#6E6A85',
  neutral: { bg: '#2A2833', text: '#C9C6D6' },
  badge: '#FF453A',
  fill: FILL,
  soft: SOFT_DARK,
  cardShadow: darkEdge,
  subtleShadow: darkEdge,
  raisedShadow: darkEdge,
  accentShadow: {},
};

export function useTheme(): Theme {
  return useColorScheme() === 'dark' ? darkTheme : lightTheme;
}

export function statusSoft(theme: Theme, status: TaskStatus): Soft {
  switch (status) {
    case 'todo':
      return theme.soft.indigo;
    case 'in_progress':
      return theme.soft.amber;
    case 'done':
      return theme.soft.green;
  }
}

export function prioritySoft(theme: Theme, priority: TaskPriority): Soft {
  switch (priority) {
    case 'high':
      return theme.danger;
    case 'medium':
      return theme.soft.orange;
    case 'low':
      return theme.neutral;
  }
}

/**
 * A color drawn as a line or a glyph on `card` / `background` (`ColorKey.accent`): the fill in light mode, the bright
 * soft text in dark mode (the ring of a task to do, a group's icons).
 */
export function colorAccent(theme: Theme, key: ColorKey): string {
  return theme.dark ? theme.soft[key].text : theme.fill[key];
}

export const radius = { card: 22, row: 20, button: 18, field: 16, track: 16, segment: 12 } as const;
export const spacing = { page: 20, dense: 16, gap: 12, inner: 16 } as const;

/** Rounded titles (Nunito, loaded in the root layout). */
export const fonts = {
  heavy: 'Nunito_900Black',
  extraBold: 'Nunito_800ExtraBold',
  bold: 'Nunito_700Bold',
} as const;

export const type = {
  largeTitle: { fontFamily: fonts.heavy, fontSize: 34, lineHeight: 41 } satisfies TextStyle,
  title: { fontFamily: fonts.heavy, fontSize: 26, lineHeight: 32 } satisfies TextStyle,
  title3: { fontFamily: fonts.extraBold, fontSize: 20, lineHeight: 25 } satisfies TextStyle,
  headline: { fontSize: 17, fontWeight: '600', lineHeight: 22 } satisfies TextStyle,
  body: { fontSize: 17, lineHeight: 22 } satisfies TextStyle,
  subheadline: { fontSize: 15, lineHeight: 20 } satisfies TextStyle,
  footnote: { fontSize: 13, lineHeight: 18 } satisfies TextStyle,
  chip: { fontSize: 13, fontWeight: '600', lineHeight: 18 } satisfies TextStyle,
  button: { fontFamily: fonts.extraBold, fontSize: 17 } satisfies TextStyle,
} as const;
