import { Ionicons } from '@expo/vector-icons';
import * as Haptics from 'expo-haptics';
import { useEffect, useRef, useState, type ComponentProps, type ReactNode } from 'react';
import {
  ActivityIndicator,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
  type StyleProp,
  type TextInputProps,
  type TextStyle,
  type ViewStyle,
} from 'react-native';
import Animated, { LayoutAnimationConfig, useAnimatedStyle, useReducedMotion, useSharedValue, type SharedValue } from 'react-native-reanimated';
import Svg, { Circle, Path } from 'react-native-svg';

import type { ColorKey } from '@/core/colorKey';
import type { TaskPriority, TaskStatus } from '@/core/models';
import { NEW_BADGE_TEXT } from '@/core/myTasks';
import {
  avatarSymbol,
  MY_TURN_LABEL,
  priorityLabel,
  progressCompactText,
  progressIsComplete,
  ROTATION_LABEL,
  statusLabel,
  nextStatus,
  type AvatarAppearance,
  type PersonBadge,
  type TaskRow,
} from '@/core/presentation';

import {
  AnimatedProgressBar,
  AnimatedProgressRing,
  bounce,
  DURATION,
  fadeIn,
  popIn,
  PressableScale,
  springTo,
  useTimingValue,
} from './motion';
import { colorAccent, prioritySoft, radius, spacing, statusSoft, type Soft, type Theme, useTheme, type as typo } from './theme';

// The shared components of docs/DESIGN-V2.md §5 (docs/DESIGN-V2-COMPONENTS.md).

export type IconName = ComponentProps<typeof Ionicons>['name'];

export function tap() {
  if (Platform.OS !== 'web') void Haptics.selectionAsync().catch(() => undefined);
}

export function T({
  style,
  children,
  secondary,
  numberOfLines,
}: {
  style?: StyleProp<TextStyle>;
  children: ReactNode;
  secondary?: boolean;
  numberOfLines?: number;
}) {
  const theme = useTheme();
  return (
    <Text
      numberOfLines={numberOfLines}
      style={[typo.body, { color: secondary ? theme.textSecondary : theme.textPrimary }, style]}
    >
      {children}
    </Text>
  );
}

// MARK: - Surfaces

export function Card({
  children,
  style,
  padded = true,
  radius: cornerRadius = radius.card,
}: {
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
  padded?: boolean;
  radius?: number;
}) {
  const theme = useTheme();
  return (
    <View
      style={[
        { backgroundColor: theme.card, borderRadius: cornerRadius, padding: padded ? spacing.inner : 0 },
        theme.cardShadow,
        style,
      ]}
    >
      {children}
    </View>
  );
}

/** A rounded square (radius 31 %) with a symbol in a soft pair: the rows of the info cards, headers. Decorative. */
export function IconTile({ icon, soft, size = 32 }: { icon: IconName; soft?: Soft; size?: number }) {
  const theme = useTheme();
  const pair = soft ?? theme.accentSoft;
  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.31,
        backgroundColor: pair.bg,
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <Ionicons name={icon} size={size * 0.52} color={pair.text} />
    </View>
  );
}

// MARK: - People and groups

/** A rounded square in the group fill with its emoji or initials (GroupTile). */
export function GroupTile({ appearance, size = 56, onWhite }: { appearance: AvatarAppearance; size?: number; onWhite?: boolean }) {
  const theme = useTheme();
  const bg = onWhite ? '#FFFFFF' : theme.fill[appearance.color];
  return (
    <View
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.33,
        backgroundColor: bg,
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <Text
        style={
          appearance.emoji
            ? { fontSize: size * 0.5 }
            : { fontFamily: 'Nunito_900Black', fontSize: size * 0.36, color: onWhite ? theme.fill[appearance.color] : '#FFF' }
        }
      >
        {avatarSymbol(appearance)}
      </Text>
    </View>
  );
}

/**
 * A circle in the person's fill with the emoji or the initials (the first letter only below 60 pt). `ring`: a 2 pt ring
 * the color of the surface behind; `highlight`: one more 2 pt ring outside it (the current turn in the accent).
 */
export function Avatar({
  appearance,
  size = 32,
  ring,
  highlight,
}: {
  appearance: AvatarAppearance;
  size?: number;
  ring?: string;
  highlight?: string;
}) {
  const theme = useTheme();
  const symbol = appearance.emoji ?? (size < 60 ? appearance.initials.slice(0, 1) : appearance.initials);
  const circle = (
    <View
      style={{
        width: size,
        height: size,
        borderRadius: size / 2,
        backgroundColor: theme.fill[appearance.color],
        alignItems: 'center',
        justifyContent: 'center',
        borderWidth: ring ? 2 : 0,
        borderColor: ring,
      }}
    >
      <Text
        style={
          appearance.emoji
            ? { fontSize: size * 0.52 }
            : { fontFamily: 'Nunito_900Black', fontSize: size * 0.42, color: '#FFF' }
        }
      >
        {symbol}
      </Text>
    </View>
  );
  if (!highlight) return circle;
  return (
    <View
      style={{
        padding: 2,
        borderRadius: size,
        borderWidth: 2,
        borderColor: highlight,
      }}
    >
      {circle}
    </View>
  );
}

export function AvatarStack({
  avatars,
  more,
  size = 28,
  ringColor,
}: {
  avatars: readonly AvatarAppearance[];
  more?: string | null;
  size?: number;
  ringColor?: string;
}) {
  const theme = useTheme();
  const ring = ringColor ?? theme.card;
  return (
    <View style={{ flexDirection: 'row' }}>
      {avatars.map((appearance, index) => (
        <View key={index} style={{ marginLeft: index === 0 ? 0 : -size * 0.27 }}>
          <Avatar appearance={appearance} size={size} ring={ring} />
        </View>
      ))}
      {more ? (
        <View
          style={{
            marginLeft: avatars.length ? -size * 0.27 : 0,
            width: size,
            height: size,
            borderRadius: size / 2,
            backgroundColor: theme.neutral.bg,
            borderWidth: 2,
            borderColor: ring,
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <Text style={{ fontSize: size * 0.36, fontWeight: '700', color: theme.neutral.text }}>{more}</Text>
        </View>
      ) : null}
    </View>
  );
}

/** The dashed circle of « Personne ». */
export function UnassignedAvatar({ size = 32 }: { size?: number }) {
  const theme = useTheme();
  return (
    <View
      accessibilityLabel="Personne"
      style={{ width: size, height: size, borderRadius: size / 2, borderWidth: 1.5, borderStyle: 'dashed', borderColor: theme.textTertiary }}
    />
  );
}

/** The assignees of a row: up to 3 avatars (else 2 and « +N »), or the dashed circle. */
function AssigneesStack({ people, size = 32 }: { people: readonly PersonBadge[]; size?: number }) {
  if (people.length === 0) return <UnassignedAvatar size={size} />;
  const shown = people.length <= 3 ? people : people.slice(0, 2);
  return (
    <AvatarStack
      avatars={shown.map((badge) => badge.appearance)}
      more={people.length > 3 ? `+${people.length - 2}` : null}
      size={size}
    />
  );
}

// MARK: - Chips and badges

/**
 * A small label: `soft` (default) draws the pair's background; `plain` only its text color (a due date, « Ton tour »,
 * « 2/4 »). `bold` for an overdue date or « Ton tour ».
 */
export function Chip({
  soft,
  icon,
  label,
  style,
  plain,
  bold,
}: {
  soft: Soft;
  icon?: IconName;
  label: string;
  style?: StyleProp<ViewStyle>;
  plain?: boolean;
  bold?: boolean;
}) {
  return (
    <View
      style={[
        {
          flexDirection: 'row',
          alignItems: 'center',
          gap: 4,
          backgroundColor: plain ? 'transparent' : soft.bg,
          borderRadius: 12,
          paddingHorizontal: plain ? 0 : 9,
          paddingVertical: plain ? 0 : 4,
          alignSelf: 'flex-start',
          flexShrink: 1,
        },
        style,
      ]}
    >
      {icon ? <Ionicons name={icon} size={13} color={soft.text} /> : null}
      <Text style={[typo.chip, { color: soft.text, flexShrink: 1 }, bold && { fontWeight: '700' }]}>{label}</Text>
    </View>
  );
}

/** « Nouveau »: white on the accent fill, never truncated. */
export function NewBadge({ text }: { text?: string }) {
  const theme = useTheme();
  return (
    <View style={{ backgroundColor: theme.accentFill, borderRadius: 999, paddingHorizontal: 8, paddingVertical: 3, alignSelf: 'center' }}>
      <Text style={{ color: '#FFF', fontSize: 12, fontWeight: '800' }} numberOfLines={1}>
        {text ?? NEW_BADGE_TEXT}
      </Text>
    </View>
  );
}

/** A selectable chip (filters): selected = textPrimary fill with the background color as text; idle = outlined card. */
export function FilterChip({ label, selected, onPress }: { label: string; selected: boolean; onPress: () => void }) {
  const theme = useTheme();
  const colors = useChipColors(selected, theme.textPrimary, theme.card, theme.background, theme.textPrimary, theme.trackStrong);
  return (
    <PressableScale
      accessibilityRole="button"
      accessibilityState={{ selected }}
      scaleTo={0.95}
      onPress={() => {
        tap();
        onPress();
      }}
      style={[{ borderRadius: 999, paddingHorizontal: 16, minHeight: 44, justifyContent: 'center', borderWidth: 1.5 }, colors.chip]}
    >
      <Animated.Text style={[{ fontSize: 15, fontWeight: selected ? '800' : '700' }, colors.text]}>{label}</Animated.Text>
    </PressableScale>
  );
}

/**
 * The cross-fading colors of a selectable chip: `fill` / `idle` backgrounds, `on` / `off` texts, and the outline
 * (`fill` when selected, `outline` otherwise). Shared with the group screen's filter chips.
 */
export function useChipColors(selected: boolean, fill: string, idle: string, on: string, off: string, outline: string) {
  const background = useTimingValue(selected ? fill : idle);
  const border = useTimingValue(selected ? fill : outline);
  const text = useTimingValue(selected ? on : off);
  const chip = useAnimatedStyle(() => ({ backgroundColor: background.value, borderColor: border.value }));
  const label = useAnimatedStyle(() => ({ color: text.value }));
  return { chip, text: label };
}

// MARK: - Controls

/** The selected segment's colors: null = a `card` segment with a shadow. */
export type SegmentTone = { bg: string; text: string } | null;

export function SegmentedPill<K extends string>({
  options,
  value,
  onChange,
  tone,
  track,
  style,
}: {
  options: readonly { key: K; label: string }[];
  value: K;
  onChange: (key: K) => void;
  /** The selected segment's colors per option (status, priority, repetition). */
  tone?: (key: K) => SegmentTone;
  /** Track color: `track` on the ground, `hairline` inside a card. */
  track?: string;
  style?: StyleProp<ViewStyle>;
}) {
  const theme = useTheme();
  const reduced = useReducedMotion();
  // The selected segment is a card sliding under the labels (measured: the segments share the width equally).
  const [width, setWidth] = useState(0);
  const index = Math.max(0, options.findIndex((option) => option.key === value));
  const segment = width > 0 ? (width - 8) / Math.max(options.length, 1) : 0;
  const selectedTone = tone?.(value) ?? null;
  const x = useSharedValue(0);
  const placed = useRef(false);
  useEffect(() => {
    if (segment === 0) return;
    x.value = placed.current ? springTo(index * segment, reduced) : index * segment;
    placed.current = true;
  }, [index, segment, reduced, x]);
  const indicatorColor = useTimingValue(selectedTone?.bg ?? theme.card);
  // Clamped to the track, so that the spring's overshoot never pokes out at the ends.
  const maxX = segment * (options.length - 1);
  const indicatorStyle = useAnimatedStyle(() => ({
    transform: [{ translateX: Math.min(Math.max(x.value, 0), maxX) }],
    backgroundColor: indicatorColor.value,
  }));
  const measured = segment > 0;
  return (
    <View
      onLayout={(event) => setWidth(event.nativeEvent.layout.width)}
      style={[{ flexDirection: 'row', backgroundColor: track ?? theme.track, borderRadius: radius.track, padding: 4 }, style]}
    >
      {measured ? (
        <Animated.View
          pointerEvents="none"
          style={[
            { position: 'absolute', top: 4, bottom: 4, left: 4, width: segment, borderRadius: radius.segment },
            selectedTone ? null : [theme.subtleShadow, theme.cardShadow],
            indicatorStyle,
          ]}
        />
      ) : null}
      {options.map((option) => {
        const selected = option.key === value;
        const colors = selected ? (tone?.(option.key) ?? null) : null;
        return (
          <Pressable
            key={option.key}
            accessibilityRole="button"
            accessibilityState={{ selected }}
            onPress={() => {
              if (selected) return;
              tap();
              onChange(option.key);
            }}
            style={[
              {
                flex: 1,
                minHeight: 44,
                borderRadius: radius.segment,
                alignItems: 'center',
                justifyContent: 'center',
                paddingHorizontal: 6,
              },
              // Until measured, the selected segment draws its own card.
              selected &&
                !measured &&
                (colors ? { backgroundColor: colors.bg } : [{ backgroundColor: theme.card }, theme.subtleShadow, theme.cardShadow]),
            ]}
          >
            <SegmentLabel
              label={option.label}
              selected={selected}
              color={selected ? (colors?.text ?? theme.textPrimary) : theme.textSecondary}
            />
          </Pressable>
        );
      })}
    </View>
  );
}

/** A segment's label, its color cross-fading with the selection. */
function SegmentLabel({ label, selected, color }: { label: string; selected: boolean; color: string }) {
  const animated = useTimingValue(color);
  const colorStyle = useAnimatedStyle(() => ({ color: animated.value }));
  return (
    <Animated.Text numberOfLines={1} adjustsFontSizeToFit style={[{ fontSize: 15, fontWeight: selected ? '800' : '600' }, colorStyle]}>
      {label}
    </Animated.Text>
  );
}

export function PrimaryButton({
  title,
  onPress,
  loading,
  disabled,
  icon,
  style,
}: {
  title: string;
  onPress: () => void;
  loading?: boolean;
  disabled?: boolean;
  icon?: IconName;
  style?: StyleProp<ViewStyle>;
}) {
  const theme = useTheme();
  const off = disabled && !loading;
  return (
    <PressableScale
      accessibilityRole="button"
      accessibilityState={{ disabled: disabled || loading, busy: loading }}
      disabled={disabled || loading}
      onPress={onPress}
      pressedOpacity={0.88}
      style={[
        {
          minHeight: 56,
          borderRadius: radius.button,
          backgroundColor: off ? theme.track : theme.accentFill,
          alignItems: 'center',
          justifyContent: 'center',
          flexDirection: 'row',
          gap: 8,
          paddingHorizontal: 16,
        },
        !off && theme.accentShadow,
        style,
      ]}
    >
      {loading ? (
        <ActivityIndicator color="#FFF" />
      ) : (
        <>
          {icon ? <Ionicons name={icon} size={20} color={off ? theme.textSecondary : '#FFF'} /> : null}
          <Text style={[typo.button, { color: off ? theme.textSecondary : '#FFF' }]}>{title}</Text>
        </>
      )}
    </PressableScale>
  );
}

export function SecondaryButton({
  title,
  onPress,
  color,
  disabled,
  style,
  fontSize = 16,
}: {
  title: string;
  onPress: () => void;
  color?: string;
  disabled?: boolean;
  style?: StyleProp<ViewStyle>;
  fontSize?: number;
}) {
  const theme = useTheme();
  return (
    <PressableScale
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      opacity={disabled ? 0.5 : 1}
      pressedOpacity={0.5}
      style={[{ minHeight: 44, alignItems: 'center', justifyContent: 'center' }, style]}
    >
      <Text style={{ fontSize, fontWeight: '700', color: color ?? theme.accent }}>{title}</Text>
    </PressableScale>
  );
}

/** A round icon button (44 pt): `card` (a card circle) or `translucent` (white 22 %, on a colored hero). */
export function CircleIconButton({
  icon,
  label,
  onPress,
  variant = 'card',
  color,
  size = 44,
}: {
  icon: IconName;
  label: string;
  onPress: () => void;
  variant?: 'card' | 'translucent';
  color?: string;
  size?: number;
}) {
  const theme = useTheme();
  return (
    <PressableScale
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      hitSlop={4}
      scaleTo={0.92}
      pressedOpacity={0.75}
      style={[
        {
          width: size,
          height: size,
          borderRadius: size / 2,
          alignItems: 'center',
          justifyContent: 'center',
          backgroundColor: variant === 'card' ? theme.card : 'rgba(255,255,255,0.22)',
        },
        variant === 'card' && theme.cardShadow,
      ]}
    >
      <Ionicons name={icon} size={size * 0.5} color={color ?? (variant === 'card' ? theme.accent : '#FFF')} />
    </PressableScale>
  );
}

/** A capsule text button on a card (« Annuler », « Créer » of a sheet header, « Retour »). */
export function CapsuleButton({
  title,
  onPress,
  icon,
  bold,
  disabled,
  loading,
}: {
  title: string;
  onPress: () => void;
  icon?: IconName;
  bold?: boolean;
  disabled?: boolean;
  loading?: boolean;
}) {
  const theme = useTheme();
  return (
    <PressableScale
      accessibilityRole="button"
      accessibilityLabel={title}
      disabled={disabled || loading}
      onPress={onPress}
      scaleTo={0.95}
      pressedOpacity={0.75}
      style={[
        {
          minHeight: 44,
          flexDirection: 'row',
          alignItems: 'center',
          gap: 2,
          paddingLeft: icon ? 10 : 18,
          paddingRight: 18,
          borderRadius: 999,
          backgroundColor: theme.card,
        },
        theme.cardShadow,
      ]}
    >
      {loading ? (
        <ActivityIndicator color={theme.accent} />
      ) : (
        <>
          {icon ? <Ionicons name={icon} size={22} color={disabled ? theme.textTertiary : theme.accent} /> : null}
          <Text style={{ fontSize: 17, fontWeight: bold ? '700' : '500', color: disabled ? theme.textTertiary : theme.accent }}>{title}</Text>
        </>
      )}
    </PressableScale>
  );
}

/**
 * A text field. With `icon`, the v2 look of the sign-in screens: a white rounded row (radius 16, 56 pt) with a leading
 * icon, an eye toggle for `secureTextEntry`, and `error` under it (the outline turns red).
 */
export function Field({
  label,
  icon,
  error,
  ...props
}: TextInputProps & { label?: string; icon?: IconName; error?: string | null }) {
  const theme = useTheme();
  const [revealed, setRevealed] = useState(false);
  if (icon) {
    const secure = props.secureTextEntry === true;
    return (
      <View style={{ gap: 6 }}>
        {label ? <Text style={[typo.subheadline, { color: theme.textSecondary, fontWeight: '600', marginLeft: 4 }]}>{label}</Text> : null}
        <View
          style={[
            {
              flexDirection: 'row',
              alignItems: 'center',
              gap: 12,
              minHeight: 56,
              paddingLeft: 16,
              paddingRight: secure ? 4 : 16,
              backgroundColor: theme.card,
              borderRadius: radius.field,
              borderWidth: 1.5,
              borderColor: error ? theme.danger.text : 'transparent',
            },
            theme.subtleShadow,
          ]}
        >
          <View style={{ width: 24, alignItems: 'center' }}>
            <Ionicons name={icon} size={20} color={error ? theme.danger.text : theme.textSecondary} />
          </View>
          <TextInput
            placeholderTextColor={theme.textTertiary}
            {...props}
            secureTextEntry={secure && !revealed}
            style={[typo.body, { flex: 1, color: theme.textPrimary, paddingVertical: 14 }, props.style]}
          />
          {secure ? (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel={revealed ? 'Masquer le mot de passe' : 'Afficher le mot de passe'}
              onPress={() => setRevealed((value) => !value)}
              style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center' }}
            >
              <Ionicons name={revealed ? 'eye-off-outline' : 'eye-outline'} size={22} color={theme.textSecondary} />
            </Pressable>
          ) : null}
        </View>
        {error ? (
          <View style={{ flexDirection: 'row', gap: 6, paddingLeft: 4 }}>
            <Ionicons name="alert-circle" size={15} color={theme.danger.text} style={{ marginTop: 1 }} />
            <Text style={[typo.footnote, { color: theme.danger.text, flex: 1 }]}>{error}</Text>
          </View>
        ) : null}
      </View>
    );
  }
  return (
    <View style={{ gap: 6 }}>
      {label ? <Text style={[typo.footnote, { color: theme.textSecondary, fontWeight: '600' }]}>{label}</Text> : null}
      <TextInput
        placeholderTextColor={theme.textTertiary}
        {...props}
        style={[
          typo.body,
          {
            backgroundColor: theme.card,
            color: theme.textPrimary,
            borderRadius: radius.field,
            paddingHorizontal: 16,
            minHeight: 50,
            borderWidth: 1,
            borderColor: error ? theme.danger.text : theme.track,
          },
          props.style,
        ]}
      />
      {error ? <Text style={[typo.footnote, { color: theme.danger.text }]}>{error}</Text> : null}
    </View>
  );
}

export function ErrorText({ message }: { message: string | null | undefined }) {
  const theme = useTheme();
  if (!message) return null;
  return (
    <Animated.View entering={fadeIn} style={{ backgroundColor: theme.danger.bg, borderRadius: 14, padding: 12, flexDirection: 'row', gap: 8 }}>
      <Ionicons name="alert-circle" size={18} color={theme.danger.text} />
      <Text style={[typo.subheadline, { color: theme.danger.text, flex: 1 }]}>{message}</Text>
    </Animated.View>
  );
}

// MARK: - Progress

export function ProgressBar({
  fraction,
  color,
  height = 8,
  track,
}: {
  fraction: number;
  color: string;
  height?: number;
  track?: string;
}) {
  const theme = useTheme();
  // Springs from 0 on mount and on each change (motion.tsx).
  return <AnimatedProgressBar fraction={fraction} color={color} height={height} track={track ?? theme.track} />;
}

export function ProgressRing({
  fraction,
  size = 76,
  stroke = 9,
  color,
  track,
  children,
}: {
  fraction: number;
  size?: number;
  stroke?: number;
  color: string;
  track?: string;
  children?: ReactNode;
}) {
  const theme = useTheme();
  // The arc springs from 0 on mount and on each change (motion.tsx).
  return (
    <AnimatedProgressRing fraction={fraction} size={size} stroke={stroke} color={color} track={track ?? theme.accentSoft.bg}>
      {children}
    </AnimatedProgressRing>
  );
}

// MARK: - Tasks

/** The glyph of a status: a ring in `tint`; « en cours », an amber ring half filled; « terminée », a green disc with a check. */
export function StatusGlyph({ status, tint, size = 24 }: { status: TaskStatus; tint: string; size?: number }) {
  const theme = useTheme();
  const line = Math.max(2, size * 0.105);
  const c = size / 2;
  if (status === 'done') {
    return (
      <View style={{ width: size, height: size, borderRadius: c, backgroundColor: theme.fill.green, alignItems: 'center', justifyContent: 'center' }}>
        <Ionicons name="checkmark" size={size * 0.62} color="#FFF" />
      </View>
    );
  }
  const amber = colorAccent(theme, 'amber');
  const inner = c - line - size * 0.08;
  return (
    <Svg width={size} height={size}>
      <Circle cx={c} cy={c} r={c - line / 2} stroke={status === 'in_progress' ? amber : tint} strokeWidth={line} fill="none" />
      {status === 'in_progress' ? <Path d={`M ${c} ${c - inner} A ${inner} ${inner} 0 0 0 ${c} ${c + inner} Z`} fill={amber} /> : null}
    </Svg>
  );
}

/** Status control of a task row: the glyph in a 44 pt target; a tap asks for the next status. */
export function StatusControl({
  status,
  color,
  tint,
  onPress,
  disabled,
  busy,
}: {
  status: TaskStatus;
  color: ColorKey;
  /** The ring color; defaults to the accent of `color`. */
  tint?: string;
  onPress?: () => void;
  disabled?: boolean;
  busy?: boolean;
}) {
  const theme = useTheme();
  const reduced = useReducedMotion();
  const enabled = !disabled && onPress !== undefined;
  // A tap squashes the glyph and springs it back past its size; the new status then pops in.
  const scale = useSharedValue(1);
  const bounceStyle = useAnimatedStyle(() => ({ transform: [{ scale: scale.value }] }));
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`Statut\u{a0}: ${statusLabel(status)}`}
      accessibilityHint={enabled ? `Passer à «\u{a0}${statusLabel(nextStatus(status))}\u{a0}»` : undefined}
      disabled={!enabled || busy}
      hitSlop={6}
      onPress={() => {
        if (Platform.OS !== 'web') {
          if (nextStatus(status) === 'done') void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => undefined);
          else void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light).catch(() => undefined);
        }
        scale.value = bounce(reduced);
        onPress?.();
      }}
      style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center' }}
    >
      {/* The glyph shown with the row does not animate; a later status does. */}
      <LayoutAnimationConfig skipEntering>
        {busy ? (
          <ActivityIndicator size="small" color={theme.accent} />
        ) : (
          <Animated.View style={[{ opacity: enabled ? 1 : 0.45 }, bounceStyle]}>
            <StatusGlyphTransition key={status} status={status} tint={tint ?? colorAccent(theme, color)} />
          </Animated.View>
        )}
      </LayoutAnimationConfig>
    </Pressable>
  );
}

/** A status glyph entering: « terminée » fills in green and its check pops in after; the others fade in. */
function StatusGlyphTransition({ status, tint }: { status: TaskStatus; tint: string }) {
  const theme = useTheme();
  const reduced = useReducedMotion();
  if (status === 'done') {
    return (
      <Animated.View
        entering={popIn(reduced)}
        style={{ width: 24, height: 24, borderRadius: 12, backgroundColor: theme.fill.green, alignItems: 'center', justifyContent: 'center' }}
      >
        <Animated.View entering={popIn(reduced, 90)}>
          <Ionicons name="checkmark" size={24 * 0.62} color="#FFF" />
        </Animated.View>
      </Animated.View>
    );
  }
  return (
    <Animated.View entering={fadeIn}>
      <StatusGlyph status={status} tint={tint} />
    </Animated.View>
  );
}

function rowAccessibilityLabel(row: TaskRow): string {
  const parts = [row.title];
  if (row.isNew) parts.push(NEW_BADGE_TEXT.toLowerCase());
  parts.push(statusLabel(row.status), `priorité ${priorityLabel(row.priority).toLowerCase()}`);
  if (row.dueText) parts.push(row.isOverdue ? `en retard, échéance ${row.dueText.toLowerCase()}` : `échéance ${row.dueText.toLowerCase()}`);
  if (row.isMyTurn) parts.push(MY_TURN_LABEL.toLowerCase());
  else if (row.hasRotation) parts.push(ROTATION_LABEL.toLowerCase());
  else if (row.recurrenceText) parts.push(row.recurrenceText.toLowerCase());
  if (row.checklistProgress) parts.push(`checklist ${row.checklistProgress.done} sur ${row.checklistProgress.total}`);
  if (row.groupName) parts.push(`groupe ${row.groupName}`);
  if (row.assigneesText) parts.push(row.assignees.length === 0 ? row.assigneesText.toLowerCase() : `assignée à ${row.assigneesText}`);
  return parts.join(', ');
}

/**
 * A task as a card (radius 20): the status control, the title (struck through when done) and « Nouveau », a wrapping
 * line of chips (group, due date, « Ton tour » / « À tour de rôle » / repetition, checklist, « En cours », priority
 * unless « Moyenne »), and on the group screen the assignees or the dashed circle.
 */
export function TaskRowCard({
  row,
  color,
  onPress,
  onToggleStatus,
  tint,
  busy,
}: {
  row: TaskRow;
  color: ColorKey;
  onPress: () => void;
  onToggleStatus?: () => void;
  tint?: string;
  busy?: boolean;
}) {
  const theme = useTheme();
  const secondary = { bg: 'transparent', text: theme.textSecondary };
  return (
    <PressableScale
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={rowAccessibilityLabel(row)}
      scaleTo={0.98}
      pressedOpacity={0.95}
      style={[
        {
          backgroundColor: theme.card,
          borderRadius: radius.row,
          paddingVertical: 12,
          paddingRight: 14,
          paddingLeft: 6,
          flexDirection: 'row',
          alignItems: 'center',
          gap: 6,
        },
        theme.cardShadow,
      ]}
    >
      <StatusControl
        status={row.status}
        color={color}
        tint={tint}
        busy={busy}
        onPress={onToggleStatus}
        disabled={!row.canChangeStatus}
      />
      <View style={{ flex: 1, gap: 6, paddingLeft: 4 }}>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
          <Text
            style={[
              typo.headline,
              { color: row.isDone ? theme.textSecondary : theme.textPrimary, flexShrink: 1 },
              row.isDone && { textDecorationLine: 'line-through' },
            ]}
          >
            {row.title}
          </Text>
          {row.isNew ? <NewBadge /> : null}
        </View>
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', columnGap: 10, rowGap: 6 }}>
          {row.groupAppearance && row.groupShortName ? (
            <Chip
              soft={theme.soft[row.groupAppearance.color]}
              label={`${row.groupAppearance.emoji ? `${row.groupAppearance.emoji} ` : ''}${row.groupShortName}`}
            />
          ) : null}
          {row.dueText ? (
            <Chip
              plain
              bold={row.isOverdue}
              soft={row.isOverdue ? { bg: 'transparent', text: theme.danger.text } : secondary}
              icon="time-outline"
              label={row.dueText}
            />
          ) : null}
          {row.isMyTurn ? (
            <Chip plain bold soft={{ bg: 'transparent', text: theme.accent }} icon="sync" label={MY_TURN_LABEL} />
          ) : row.hasRotation ? (
            <Chip plain soft={secondary} icon="sync" label={ROTATION_LABEL} />
          ) : row.recurrenceText ? (
            <Chip plain soft={secondary} icon="sync" label={row.recurrenceText} />
          ) : null}
          {row.checklistProgress ? (
            <Chip
              plain
              bold
              soft={{
                bg: 'transparent',
                text: colorAccent(theme, progressIsComplete(row.checklistProgress) ? 'green' : 'teal'),
              }}
              icon="list"
              label={progressCompactText(row.checklistProgress)}
            />
          ) : null}
          {row.status === 'in_progress' ? <Chip soft={statusSoft(theme, 'in_progress')} label={statusLabel('in_progress')} /> : null}
          {row.priority !== 'medium' ? <Chip soft={prioritySoft(theme, row.priority)} icon="flag" label={priorityLabel(row.priority)} /> : null}
        </View>
      </View>
      {row.assigneesText !== null ? <AssigneesStack people={row.assignees} /> : null}
    </PressableScale>
  );
}

/** « ! Haute », « — Moyenne », « ↓ Basse » (the rows of « Mes tâches »). */
export function PriorityBadge({ priority }: { priority: TaskPriority }) {
  const theme = useTheme();
  const soft = prioritySoft(theme, priority);
  const glyph = priority === 'high' ? '!' : priority === 'medium' ? '—' : '↓';
  return (
    <View
      accessibilityLabel={`Priorité ${priorityLabel(priority).toLowerCase()}`}
      style={{ flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: soft.bg, borderRadius: 999, paddingHorizontal: 9, paddingVertical: 3 }}
    >
      <Text style={{ color: soft.text, fontSize: 13, fontWeight: '800' }}>{glyph}</Text>
      <Text style={{ color: soft.text, fontSize: 13, fontWeight: '600' }}>{priorityLabel(priority)}</Text>
    </View>
  );
}

/**
 * A row of « Mes tâches » (screenshot 07) as a card: the status, the title and « Nouveau », the group line, the
 * priority and the due date, then the repetition, turn and checklist, and a chevron.
 */
export function MyTaskRowCard({
  row,
  onPress,
  onToggleStatus,
  busy,
}: {
  row: TaskRow;
  onPress: () => void;
  onToggleStatus?: () => void;
  busy?: boolean;
}) {
  const theme = useTheme();
  const color = row.groupAppearance?.color ?? 'indigo';
  const secondary = { bg: 'transparent', text: theme.textSecondary };
  return (
    <PressableScale
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={rowAccessibilityLabel(row)}
      scaleTo={0.98}
      pressedOpacity={0.95}
      style={[
        {
          backgroundColor: theme.card,
          borderRadius: radius.row + 4,
          paddingVertical: 14,
          paddingRight: 12,
          paddingLeft: 10,
          flexDirection: 'row',
          alignItems: 'center',
          gap: 8,
        },
        theme.cardShadow,
      ]}
    >
      <View style={{ alignSelf: 'flex-start', marginTop: -8 }}>
        <StatusControl
          status={row.status}
          color={color}
          tint={theme.textSecondary}
          busy={busy}
          onPress={onToggleStatus}
          disabled={!row.canChangeStatus}
        />
      </View>
      <View style={{ flex: 1, gap: 5, opacity: row.isDone ? 0.75 : 1 }}>
        <View style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 8 }}>
          <Text
            style={[
              typo.headline,
              { flex: 1, fontSize: 18, fontWeight: '500', color: row.isDone ? theme.textSecondary : theme.textPrimary },
              row.isDone && { textDecorationLine: 'line-through' },
            ]}
            numberOfLines={2}
          >
            {row.title}
          </Text>
          {row.isNew ? <NewBadge /> : null}
        </View>
        {row.groupName ? (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
            <Ionicons name="people-outline" size={15} color={theme.textSecondary} />
            <Text style={[typo.footnote, { color: theme.textSecondary, flexShrink: 1 }]} numberOfLines={1}>
              {row.groupAppearance?.emoji ? `${row.groupAppearance.emoji} ` : ''}
              {row.groupName}
            </Text>
          </View>
        ) : null}
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', columnGap: 10, rowGap: 6 }}>
          <PriorityBadge priority={row.priority} />
          {row.dueText ? (
            <Chip
              plain
              bold={row.isOverdue}
              soft={row.isOverdue ? { bg: 'transparent', text: theme.danger.text } : secondary}
              icon={row.isOverdue ? 'alert-circle' : 'calendar-outline'}
              label={row.dueText}
            />
          ) : null}
          {row.isMyTurn ? <Chip plain bold soft={{ bg: 'transparent', text: theme.accent }} icon="sync" label={MY_TURN_LABEL} /> : null}
          {!row.isMyTurn && row.recurrenceText ? <Chip plain soft={secondary} icon="sync" label={row.recurrenceText} /> : null}
          {row.checklistProgress ? (
            <Chip
              plain
              bold
              soft={{ bg: 'transparent', text: colorAccent(theme, progressIsComplete(row.checklistProgress) ? 'green' : 'teal') }}
              icon="list"
              label={progressCompactText(row.checklistProgress)}
            />
          ) : null}
        </View>
      </View>
      <Ionicons name="chevron-forward" size={20} color={theme.textTertiary} />
    </PressableScale>
  );
}

/**
 * The floating « + »: it pops in on mount; with `shrink` (0 → 1, e.g. while scrolling down), it shrinks a little and
 * stays tappable.
 */
export function FloatingAddButton({
  onPress,
  label,
  bottom = 20,
  shrink,
}: {
  onPress: () => void;
  label: string;
  bottom?: number;
  shrink?: SharedValue<number>;
}) {
  const theme = useTheme();
  const reduced = useReducedMotion();
  const shrinkStyle = useAnimatedStyle(() => {
    const amount = shrink ? shrink.value : 0;
    return { opacity: 1 - 0.12 * amount, transform: [{ scale: 1 - 0.18 * amount }] };
  });
  return (
    <Animated.View entering={popIn(reduced, 150)} style={{ position: 'absolute', right: 20, bottom }}>
      <Animated.View style={shrinkStyle}>
        <PressableScale
          accessibilityRole="button"
          accessibilityLabel={label}
          onPress={onPress}
          scaleTo={0.92}
          pressedOpacity={0.88}
          style={[
            { width: 60, height: 60, borderRadius: 20, backgroundColor: theme.accentFill, alignItems: 'center', justifyContent: 'center' },
            theme.accentShadow,
          ]}
        >
          <Ionicons name="add" size={34} color="#FFF" />
        </PressableScale>
      </Animated.View>
    </Animated.View>
  );
}

export function EmptyState({ icon, title, message, children }: { icon: IconName; title: string; message?: string; children?: ReactNode }) {
  const theme = useTheme();
  return (
    <Animated.View entering={fadeIn} style={{ alignItems: 'center', gap: 10, paddingVertical: 40, paddingHorizontal: 24 }}>
      <View style={{ width: 72, height: 72, borderRadius: 24, backgroundColor: theme.accentSoft.bg, alignItems: 'center', justifyContent: 'center' }}>
        <Ionicons name={icon} size={34} color={theme.accentSoft.text} />
      </View>
      <Text style={[typo.title3, { color: theme.textPrimary, textAlign: 'center' }]}>{title}</Text>
      {message ? <Text style={[typo.subheadline, { color: theme.textSecondary, textAlign: 'center' }]}>{message}</Text> : null}
      {children}
    </Animated.View>
  );
}

export function Loading() {
  const theme = useTheme();
  return (
    <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', padding: 40 }}>
      <ActivityIndicator color={theme.accent} />
    </View>
  );
}

/** A row of a settings-like card: icon tile, label, value, chevron. */
export function ListRow({
  icon,
  iconColor,
  label,
  value,
  onPress,
  destructive,
  last,
}: {
  icon?: IconName;
  iconColor?: string;
  label: string;
  value?: string | null;
  onPress?: () => void;
  destructive?: boolean;
  last?: boolean;
}) {
  const theme = useTheme();
  return (
    <PressableScale
      disabled={!onPress}
      onPress={onPress}
      scaleTo={0.985}
      pressedOpacity={0.6}
      style={{
        flexDirection: 'row',
        alignItems: 'center',
        gap: 12,
        minHeight: 52,
        paddingHorizontal: spacing.inner,
        borderBottomWidth: last ? 0 : StyleSheet.hairlineWidth * 2,
        borderBottomColor: theme.hairline,
      }}
    >
      {icon ? (
        <View
          style={{
            width: 32,
            height: 32,
            borderRadius: 10,
            backgroundColor: iconColor ?? theme.accentFill,
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <Ionicons name={icon} size={18} color="#FFF" />
        </View>
      ) : null}
      <Text style={[typo.body, { flex: 1, color: destructive ? theme.danger.text : theme.textPrimary }]}>{label}</Text>
      {value ? (
        <Text style={[typo.body, { color: theme.textSecondary, flexShrink: 1 }]} numberOfLines={1}>
          {value}
        </Text>
      ) : null}
      {onPress && !destructive ? <Ionicons name="chevron-forward" size={18} color={theme.textSecondary} /> : null}
    </PressableScale>
  );
}

/**
 * A title above a list or a card. `large` (default): rounded heavy title3; `small`: subheadline heavy in
 * `textSecondary`. Optional leading icon and a trailing text (a count).
 */
export function SectionTitle({
  children,
  color,
  icon,
  trailing,
  size = 'large',
}: {
  children: ReactNode;
  color?: string;
  icon?: IconName;
  trailing?: string | number | null;
  size?: 'small' | 'large';
}) {
  const theme = useTheme();
  const tint = color ?? (size === 'large' ? theme.textPrimary : theme.textSecondary);
  const textStyle: StyleProp<TextStyle> =
    size === 'large' ? [typo.title3, { color: tint }] : [{ fontSize: 17, fontWeight: '600', color: tint }];
  if (!icon && trailing == null) {
    return (
      <Text accessibilityRole="header" style={[textStyle, { marginTop: 8, marginBottom: 2 }]}>
        {children}
      </Text>
    );
  }
  return (
    <View accessibilityRole="header" style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 8, marginBottom: 2, paddingHorizontal: 4 }}>
      {icon ? <Ionicons name={icon} size={20} color={tint} /> : null}
      <Text style={[textStyle, { flex: 1 }]}>{children}</Text>
      {trailing != null ? <Text style={{ fontSize: 17, fontWeight: '600', color: tint }}>{trailing}</Text> : null}
    </View>
  );
}

export function useThemeStyles<T>(make: (theme: Theme) => T): T {
  return make(useTheme());
}
