import { Ionicons } from '@expo/vector-icons';
import { useState, type ReactNode } from 'react';
import { ActivityIndicator, Image, Platform, Pressable, Text, View, type StyleProp, type ViewStyle } from 'react-native';

import { COLOR_KEYS, colorLabel, type ColorKey } from '@/core/colorKey';
import type { AvatarAppearance } from '@/core/presentation';

import { Avatar, tap, type IconName } from './components';
import { fonts, radius, type Soft, type Theme, type as typo, useTheme } from './theme';

// The pieces of the onboarding and of the avatar editor (Swift `OnboardingView`, `OnboardingSteps`,
// `OnboardingIllustrations`, `AvatarEditorSheet`, and the design system's `StepProgress`, `CircleIconButton`,
// `IconTile`, `SwatchGrid`, `EmojiGrid`, `PickerSection`).

/** Tokens of docs/DESIGN-V2-COMPONENTS.md §1 that `theme.ts` does not carry. */
export function extraTokens(theme: Theme) {
  return theme.dark
    ? { trackStrong: '#3A3656', textTertiary: '#6E6A85', neutral: { bg: '#2A2833', text: '#C9C6D6' } as Soft, shadow: '#161428' }
    : { trackStrong: '#DDDAE8', textTertiary: '#A8A4B8', neutral: { bg: '#EEEDF3', text: '#5F5C6E' } as Soft, shadow: '#161428' };
}

/** `ColorKey.accent`: the fill in light mode, the bright soft text in dark mode. */
export function accentOf(theme: Theme, key: ColorKey): string {
  return theme.dark ? theme.soft[key].text : theme.fill[key];
}

/** The `raised` elevation (floating illustrations); a hairline in dark mode. */
export function raisedShadow(theme: Theme): ViewStyle {
  if (theme.dark) return { borderWidth: 1, borderColor: theme.hairline };
  return Platform.select<ViewStyle>({
    web: { boxShadow: '0 10px 28px rgba(22,20,40,0.12)' } as ViewStyle,
    default: { shadowColor: '#161428', shadowOpacity: 0.12, shadowRadius: 14, shadowOffset: { width: 0, height: 10 }, elevation: 4 },
  });
}

/** A rounded square (radius 31 %) with an icon in the tone's text on its background. Decorative. */
export function IconTile({ icon, soft, size = 32 }: { icon: IconName; soft: Soft; size?: number }) {
  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={{ width: size, height: size, borderRadius: size * 0.31, backgroundColor: soft.bg, alignItems: 'center', justifyContent: 'center' }}
    >
      <Ionicons name={icon} size={size * 0.55} color={soft.text} />
    </View>
  );
}

/** « 2 sur 4 »: capsules in `accentFill` for the steps done and current, `trackStrong` for the others. */
export function StepProgress({ current, total }: { current: number; total: number }) {
  const theme = useTheme();
  const extra = extraTokens(theme);
  return (
    <View
      accessible
      accessibilityLabel={`Étape ${current} sur ${total}`}
      style={{ flex: 1, flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 44 }}
    >
      <View style={{ flex: 1, flexDirection: 'row', gap: 6, minWidth: 72 }}>
        {Array.from({ length: Math.max(total, 1) }, (_, index) => (
          <View
            key={index}
            style={{ flex: 1, height: 6, borderRadius: 3, backgroundColor: index < current ? theme.accentFill : extra.trackStrong }}
          />
        ))}
      </View>
      <Text style={{ fontSize: 13, fontWeight: '700', color: theme.textSecondary, fontVariant: ['tabular-nums'] }}>
        {`${current} sur ${total}`}
      </Text>
    </View>
  );
}

/** A 44 pt round icon button on `card` (the onboarding's back button). */
export function CircleIconButton({
  icon,
  label,
  onPress,
  disabled,
}: {
  icon: IconName;
  label: string;
  onPress: () => void;
  disabled?: boolean;
}) {
  const theme = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        {
          width: 44,
          height: 44,
          borderRadius: 22,
          backgroundColor: theme.card,
          alignItems: 'center',
          justifyContent: 'center',
          opacity: disabled ? 0.5 : pressed ? 0.7 : 1,
        },
        theme.dark
          ? { borderWidth: 1, borderColor: theme.hairline }
          : { shadowColor: '#161428', shadowOpacity: 0.08, shadowRadius: 1.5, shadowOffset: { width: 0, height: 1 }, elevation: 1 },
      ]}
    >
      <Ionicons name={icon} size={20} color={theme.textPrimary} />
    </Pressable>
  );
}

/** Plain accent text, 44 pt tall (« Passer », « Plus tard »). */
export function TextButton({
  title,
  onPress,
  disabled,
  color,
  fullWidth = true,
}: {
  title: string;
  onPress: () => void;
  disabled?: boolean;
  color?: string;
  fullWidth?: boolean;
}) {
  const theme = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      hitSlop={4}
      style={({ pressed }) => ({
        minHeight: 44,
        alignSelf: fullWidth ? 'stretch' : 'auto',
        alignItems: 'center',
        justifyContent: 'center',
        paddingHorizontal: fullWidth ? 0 : 4,
        opacity: disabled ? 0.4 : pressed ? 0.6 : 1,
      })}
    >
      <Text style={{ fontFamily: fonts.extraBold, fontSize: 18, color: color ?? theme.accent }}>{title}</Text>
    </Pressable>
  );
}

/** The primary button with its icon before or after the title; disabled on `track`, a white spinner while busy. */
export function BigButton({
  title,
  onPress,
  icon,
  iconAfter,
  loading,
  disabled,
}: {
  title: string;
  onPress: () => void;
  icon?: IconName;
  iconAfter?: boolean;
  loading?: boolean;
  disabled?: boolean;
}) {
  const theme = useTheme();
  const idle = disabled && !loading;
  const color = idle ? theme.textSecondary : '#FFF';
  const glyph = icon ? <Ionicons name={icon} size={21} color={color} /> : null;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ disabled: disabled || loading, busy: loading }}
      disabled={disabled || loading}
      onPress={onPress}
      style={({ pressed }) => [
        {
          minHeight: 56,
          borderRadius: radius.button,
          backgroundColor: idle ? theme.track : theme.accentFill,
          flexDirection: 'row',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 10,
          paddingHorizontal: 20,
          opacity: pressed ? 0.85 : 1,
        },
        !theme.dark &&
          !idle &&
          Platform.select<ViewStyle>({
            web: { boxShadow: '0 8px 18px rgba(75,59,230,0.28)' } as ViewStyle,
            default: { shadowColor: '#4B3BE6', shadowOpacity: 0.28, shadowRadius: 12, shadowOffset: { width: 0, height: 6 } },
          }),
      ]}
    >
      {loading ? (
        <ActivityIndicator color="#FFF" accessibilityLabel="En cours" />
      ) : (
        <>
          {iconAfter ? null : glyph}
          <Text style={[typo.button, { fontSize: 18, color }]}>{title}</Text>
          {iconAfter ? glyph : null}
        </>
      )}
    </Pressable>
  );
}

/** A titled block of a picker (« Couleur », « Symbole », « Emoji »). */
export function PickerSection({ title, children }: { title: string; children: ReactNode }) {
  const theme = useTheme();
  return (
    <View style={{ gap: 10 }}>
      <Text accessibilityRole="header" style={[typo.subheadline, { fontWeight: '700', color: theme.textSecondary }]}>
        {title}
      </Text>
      {children}
    </View>
  );
}

/** Items in rows of `columns` equal cells (the last row padded). */
function GridRows<T>({
  items,
  columns,
  gap,
  render,
}: {
  items: readonly T[];
  columns: number;
  gap: number;
  render: (item: T, index: number) => ReactNode;
}) {
  const rows: T[][] = [];
  for (let index = 0; index < items.length; index += columns) rows.push(items.slice(index, index + columns));
  return (
    <View style={{ gap }}>
      {rows.map((row, rowIndex) => (
        <View key={rowIndex} style={{ flexDirection: 'row', gap }}>
          {row.map((item, index) => (
            <View key={index} style={{ flex: 1 }}>
              {render(item, rowIndex * columns + index)}
            </View>
          ))}
          {Array.from({ length: columns - row.length }, (_, index) => (
            <View key={`pad-${index}`} style={{ flex: 1 }} />
          ))}
        </View>
      ))}
    </View>
  );
}

/** The 9 colors in a 3 × 3 grid of 44 pt wide swatches; the selected one has a white check and a ring in its accent. */
export function SwatchGrid({ value, onChange }: { value: ColorKey; onChange: (key: ColorKey) => void }) {
  const theme = useTheme();
  return (
    <GridRows
      items={COLOR_KEYS}
      columns={3}
      gap={10}
      render={(key) => {
        const selected = key === value;
        return (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={colorLabel(key)}
            accessibilityState={{ selected }}
            onPress={() => {
              tap();
              onChange(key);
            }}
            style={({ pressed }) => ({
              padding: 3,
              borderRadius: 17,
              borderWidth: 2,
              borderColor: selected ? accentOf(theme, key) : 'transparent',
              transform: [{ scale: pressed ? 0.96 : 1 }],
            })}
          >
            <View style={{ height: 44, borderRadius: 13, backgroundColor: theme.fill[key], alignItems: 'center', justifyContent: 'center' }}>
              {selected ? <Ionicons name="checkmark-sharp" size={24} color="#FFF" /> : null}
            </View>
          </Pressable>
        );
      }}
    />
  );
}

/**
 * The curated emojis in 6 columns of 48 pt cells, the selected one on `accentSoft` with an accent ring. With
 * `initials`, a first cell shows them and stands for null (the avatar picker).
 */
export function EmojiGrid({
  choices,
  value,
  initials,
  onChange,
}: {
  choices: readonly string[];
  value: string | null;
  initials?: string;
  onChange: (emoji: string | null) => void;
}) {
  const theme = useTheme();
  const cells: (string | null)[] = initials === undefined ? [...choices] : [null, ...choices];
  return (
    <GridRows
      items={cells}
      columns={6}
      gap={8}
      render={(emoji) => {
        const selected = emoji === value;
        return (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={emoji === null ? 'Initiales' : emoji}
            accessibilityState={{ selected }}
            onPress={() => {
              tap();
              onChange(emoji);
            }}
            style={({ pressed }) => ({
              minHeight: 48,
              padding: 4,
              borderRadius: 14,
              backgroundColor: selected ? theme.accentSoft.bg : theme.card,
              borderWidth: selected ? 2.5 : 1.5,
              borderColor: selected ? theme.accent : theme.hairline,
              alignItems: 'center',
              justifyContent: 'center',
              transform: [{ scale: pressed ? 0.94 : 1 }],
            })}
          >
            {emoji === null ? (
              <Text numberOfLines={1} adjustsFontSizeToFit style={{ fontFamily: fonts.heavy, fontSize: 17, color: theme.textPrimary }}>
                {initials}
              </Text>
            ) : (
              <Text style={{ fontSize: 24 }}>{emoji}</Text>
            )}
          </Pressable>
        );
      }}
    />
  );
}

/** The big preview of an avatar being edited: 116 pt, a 6 pt `card` ring and a soft shadow. */
export function AvatarPreview({ appearance }: { appearance: AvatarAppearance }) {
  const theme = useTheme();
  return (
    <View
      accessible
      accessibilityLabel="Aperçu de ton avatar"
      accessibilityValue={{ text: `${appearance.emoji ?? `initiales ${appearance.initials}`}, ${colorLabel(appearance.color).toLowerCase()}` }}
      style={{ alignItems: 'center', paddingVertical: 12 }}
    >
      <View
        style={[
          { padding: 6, borderRadius: 64, backgroundColor: theme.card },
          theme.dark
            ? null
            : Platform.select<ViewStyle>({
                web: { boxShadow: '0 14px 30px rgba(22,20,40,0.18)' } as ViewStyle,
                default: { shadowColor: '#161428', shadowOpacity: 0.18, shadowRadius: 15, shadowOffset: { width: 0, height: 14 }, elevation: 6 },
              }),
        ]}
      >
        <Avatar appearance={appearance} size={116} />
      </View>
    </View>
  );
}

/** The avatar picker: the preview, « Couleur », then « Symbole » (the initials or an emoji). */
export function AvatarEditorContent({
  appearance,
  choices,
  onColor,
  onEmoji,
}: {
  appearance: AvatarAppearance;
  choices: readonly string[];
  onColor: (key: ColorKey) => void;
  onEmoji: (emoji: string | null) => void;
}) {
  return (
    <View style={{ gap: 24 }}>
      <AvatarPreview appearance={appearance} />
      <PickerSection title="Couleur">
        <SwatchGrid value={appearance.color} onChange={onColor} />
      </PickerSection>
      <PickerSection title="Symbole">
        <EmojiGrid choices={choices} value={appearance.emoji} initials={appearance.initials} onChange={onEmoji} />
      </PickerSection>
    </View>
  );
}

/** The title (rounded heavy) and the message of a step. */
export function StepHeader({ title, message, large }: { title: string; message: string; large?: boolean }) {
  const theme = useTheme();
  return (
    <View style={{ gap: 10 }}>
      <Text
        accessibilityRole="header"
        style={{ fontFamily: fonts.heavy, fontSize: large ? 36 : 30, lineHeight: large ? 43 : 36, color: theme.textPrimary }}
      >
        {title}
      </Text>
      <Text style={[typo.body, { fontSize: 18, lineHeight: 25, color: theme.textSecondary }]}>{message}</Text>
    </View>
  );
}

/** A highlight of the welcome step: a 48 pt icon tile, its title and its message. */
export function HighlightRow({ icon, soft, title, message }: { icon: IconName; soft: Soft; title: string; message: string }) {
  const theme = useTheme();
  return (
    <View accessible style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
      <IconTile icon={icon} soft={soft} size={48} />
      <View style={{ flex: 1, gap: 2 }}>
        <Text style={{ fontSize: 16, lineHeight: 21, fontWeight: '700', color: theme.textPrimary }}>{title}</Text>
        <Text style={[typo.subheadline, { color: theme.textSecondary }]}>{message}</Text>
      </View>
    </View>
  );
}

// MARK: - Illustrations

const CANVAS = { width: 342, height: 200 } as const;

/** A task's status glyph: a ring in `tint`, or a green disc with a check when done. */
function StatusGlyph({ done, tint, size = 24 }: { done: boolean; tint: string; size?: number }) {
  const theme = useTheme();
  if (done) {
    return (
      <View style={{ width: size, height: size, borderRadius: size / 2, backgroundColor: theme.fill.green, alignItems: 'center', justifyContent: 'center' }}>
        <Ionicons name="checkmark-sharp" size={size * 0.66} color="#FFF" />
      </View>
    );
  }
  return <View style={{ width: size, height: size, borderRadius: size / 2, borderWidth: 2.5, borderColor: tint }} />;
}

function SampleTaskCard({
  title,
  done,
  tint,
  person,
  symbol,
  chip,
  style,
}: {
  title: string;
  done?: boolean;
  tint: string;
  person: AvatarAppearance;
  symbol?: IconName;
  chip?: string;
  style: StyleProp<ViewStyle>;
}) {
  const theme = useTheme();
  return (
    <View
      style={[
        { position: 'absolute', height: 60, borderRadius: 18, backgroundColor: theme.card, flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 12 },
        raisedShadow(theme),
        style,
      ]}
    >
      <StatusGlyph done={done ?? false} tint={tint} />
      <Text
        numberOfLines={1}
        style={[
          { flex: 1, fontSize: 14.5, fontWeight: '700', color: done ? theme.textSecondary : theme.textPrimary },
          done && { textDecorationLine: 'line-through' },
        ]}
      >
        {title}
      </Text>
      {symbol ? <Ionicons name={symbol} size={17} color={theme.accent} /> : null}
      {chip ? (
        <View style={{ height: 24, paddingHorizontal: 8, borderRadius: 12, backgroundColor: theme.soft.teal.bg, justifyContent: 'center' }}>
          <Text style={{ fontFamily: fonts.heavy, fontSize: 13, color: theme.soft.teal.text }}>{chip}</Text>
        </View>
      ) : null}
      <Avatar appearance={person} size={28} />
    </View>
  );
}

/** The welcome illustration: three task cards stacked at slight angles over soft shapes, on a 342 × 200 canvas. */
export function TaskCardsIllustration() {
  const theme = useTheme();
  const [width, setWidth] = useState<number>(CANVAS.width);
  const scale = Math.min(width, CANVAS.width) / CANVAS.width;
  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      onLayout={(event) => setWidth(event.nativeEvent.layout.width)}
      style={{ width: '100%', height: CANVAS.height * scale, alignItems: 'center' }}
    >
      <View style={{ width: CANVAS.width * scale, height: CANVAS.height * scale }}>
        <View style={{ width: CANVAS.width, height: CANVAS.height, transformOrigin: 'top left', transform: [{ scale }] }}>
          <View style={{ position: 'absolute', left: 242, top: 0, width: 96, height: 96, borderRadius: 48, backgroundColor: theme.soft.coral.bg }} />
          <View
            style={{
              position: 'absolute',
              left: 0,
              top: 132,
              width: 64,
              height: 64,
              borderRadius: 22,
              backgroundColor: theme.soft.amber.bg,
              transform: [{ rotate: '12deg' }],
            }}
          />
          <View style={{ position: 'absolute', left: 266, top: 160, width: 40, height: 40, borderRadius: 20, backgroundColor: theme.soft.teal.bg }} />
          <SampleTaskCard
            title="Arroser les plantes"
            done
            tint={accentOf(theme, 'green')}
            person={{ color: 'orange', emoji: null, initials: 'I' }}
            style={{ left: 30, top: 14, width: 262, transform: [{ rotate: '-5deg' }] }}
          />
          <SampleTaskCard
            title="Sortir les poubelles"
            tint={accentOf(theme, 'coral')}
            person={{ color: 'indigo', emoji: null, initials: 'C' }}
            symbol="sync"
            style={{ left: 62, top: 76, width: 270, transform: [{ rotate: '3deg' }] }}
          />
          <SampleTaskCard
            title="Faire les courses"
            tint={accentOf(theme, 'amber')}
            person={{ color: 'teal', emoji: null, initials: 'L' }}
            chip="2/5"
            style={{ left: 16, top: 136, width: 282, transform: [{ rotate: '-2deg' }] }}
          />
        </View>
      </View>
    </View>
  );
}

const NOTIFICATION_SAMPLES = [
  { time: 'maintenant', text: 'C’est ton tour\u{a0}: «\u{a0}Sortir les poubelles\u{a0}», ce soir à 20:00.' },
  { time: 'il y a 5 min', text: 'Lucas t’a confié «\u{a0}Faire les courses\u{a0}» pour demain.' },
  { time: 'lundi', text: 'Le récap de la semaine est prêt\u{a0}: 14 tâches faites dans ta coloc.' },
] as const;

// eslint-disable-next-line @typescript-eslint/no-require-imports
const APP_ICON = require('../../assets/images/icon.png') as number;

/** The notifications illustration: three sample notifications of « Équipe », with the app icon. */
export function NotificationSamples() {
  const theme = useTheme();
  return (
    <View accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={{ gap: 10 }}>
      {NOTIFICATION_SAMPLES.map((sample) => (
        <View
          key={sample.time}
          style={[
            { flexDirection: 'row', alignItems: 'flex-start', gap: 12, paddingVertical: 12, paddingHorizontal: 14, borderRadius: 22, backgroundColor: theme.card },
            raisedShadow(theme),
          ]}
        >
          <Image source={APP_ICON} style={{ width: 38, height: 38, borderRadius: 9 }} />
          <View style={{ flex: 1, gap: 2 }}>
            <View style={{ flexDirection: 'row', alignItems: 'baseline', gap: 8 }}>
              <Text style={[typo.subheadline, { flex: 1, fontWeight: '700', color: theme.textPrimary }]}>Équipe</Text>
              <Text style={{ fontSize: 12, color: theme.textSecondary }}>{sample.time}</Text>
            </View>
            <Text style={[typo.subheadline, { color: theme.textPrimary }]}>{sample.text}</Text>
          </View>
        </View>
      ))}
    </View>
  );
}
