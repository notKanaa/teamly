import { Ionicons } from '@expo/vector-icons';
import * as Haptics from 'expo-haptics';
import type { ComponentProps, ReactNode } from 'react';
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
import Svg, { Circle } from 'react-native-svg';

import type { ColorKey } from '@/core/colorKey';
import type { TaskStatus } from '@/core/models';
import { avatarSymbol, type AvatarAppearance, type PersonBadge, type TaskRow } from '@/core/presentation';

import { radius, spacing, statusSoft, type Soft, type Theme, useTheme, type as typo } from './theme';

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

export function Card({ children, style, padded = true }: { children: ReactNode; style?: StyleProp<ViewStyle>; padded?: boolean }) {
  const theme = useTheme();
  return (
    <View
      style={[
        { backgroundColor: theme.card, borderRadius: radius.card, padding: padded ? spacing.inner : 0 },
        theme.cardShadow,
        style,
      ]}
    >
      {children}
    </View>
  );
}

/** A rounded square in the group fill with its emoji or initials (GroupTile). */
export function GroupTile({ appearance, size = 56, onWhite }: { appearance: AvatarAppearance; size?: number; onWhite?: boolean }) {
  const theme = useTheme();
  const bg = onWhite ? '#FFFFFF' : theme.fill[appearance.color];
  return (
    <View
      style={{
        width: size,
        height: size,
        borderRadius: size >= 64 ? 22 : 18 * (size / 56),
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

export function Avatar({ appearance, size = 32, ring }: { appearance: AvatarAppearance; size?: number; ring?: string }) {
  const theme = useTheme();
  return (
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
            : { fontFamily: 'Nunito_900Black', fontSize: size * 0.38, color: '#FFF' }
        }
      >
        {avatarSymbol(appearance)}
      </Text>
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
        <View key={index} style={{ marginLeft: index === 0 ? 0 : -size * 0.3 }}>
          <Avatar appearance={appearance} size={size} ring={ring} />
        </View>
      ))}
      {more ? (
        <View
          style={{
            marginLeft: avatars.length ? -size * 0.3 : 0,
            width: size,
            height: size,
            borderRadius: size / 2,
            backgroundColor: theme.track,
            borderWidth: 2,
            borderColor: ring,
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <Text style={{ fontSize: size * 0.36, fontWeight: '700', color: theme.textSecondary }}>{more}</Text>
        </View>
      ) : null}
    </View>
  );
}

export function Chip({ soft, icon, label, style }: { soft: Soft; icon?: IconName; label: string; style?: StyleProp<ViewStyle> }) {
  return (
    <View
      style={[
        {
          flexDirection: 'row',
          alignItems: 'center',
          gap: 4,
          backgroundColor: soft.bg,
          borderRadius: 999,
          paddingHorizontal: 9,
          paddingVertical: 3,
          alignSelf: 'flex-start',
        },
        style,
      ]}
    >
      {icon ? <Ionicons name={icon} size={12} color={soft.text} /> : null}
      <Text style={[typo.chip, { color: soft.text }]} numberOfLines={1}>
        {label}
      </Text>
    </View>
  );
}

/** A selectable chip (filters): selected = textPrimary fill, white text. */
export function FilterChip({ label, selected, onPress }: { label: string; selected: boolean; onPress: () => void }) {
  const theme = useTheme();
  return (
    <Pressable
      onPress={() => {
        tap();
        onPress();
      }}
      style={{
        backgroundColor: selected ? theme.textPrimary : theme.card,
        borderRadius: 999,
        paddingHorizontal: 14,
        paddingVertical: 8,
        minHeight: 36,
        justifyContent: 'center',
        ...(selected ? {} : theme.cardShadow),
      }}
    >
      <Text style={[typo.chip, { color: selected ? theme.background : theme.textPrimary }]}>{label}</Text>
    </Pressable>
  );
}

export function SegmentedPill<K extends string>({
  options,
  value,
  onChange,
}: {
  options: readonly { key: K; label: string }[];
  value: K;
  onChange: (key: K) => void;
}) {
  const theme = useTheme();
  return (
    <View style={{ flexDirection: 'row', backgroundColor: theme.track, borderRadius: radius.track, padding: 4 }}>
      {options.map((option) => {
        const selected = option.key === value;
        return (
          <Pressable
            key={option.key}
            accessibilityRole="button"
            accessibilityState={{ selected }}
            onPress={() => {
              tap();
              onChange(option.key);
            }}
            style={[
              {
                flex: 1,
                minHeight: 40,
                borderRadius: radius.segment,
                alignItems: 'center',
                justifyContent: 'center',
                paddingHorizontal: 6,
              },
              selected && [{ backgroundColor: theme.card }, theme.cardShadow],
            ]}
          >
            <Text
              style={{
                fontFamily: 'Nunito_800ExtraBold',
                fontSize: 15,
                color: selected ? theme.textPrimary : theme.textSecondary,
              }}
            >
              {option.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
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
  const inactive = disabled || loading;
  return (
    <Pressable
      accessibilityRole="button"
      disabled={inactive}
      onPress={onPress}
      style={({ pressed }) => [
        {
          height: 56,
          borderRadius: radius.button,
          backgroundColor: theme.accentFill,
          alignItems: 'center',
          justifyContent: 'center',
          flexDirection: 'row',
          gap: 8,
          opacity: disabled ? 0.5 : pressed ? 0.85 : 1,
        },
        !theme.dark &&
          Platform.select<ViewStyle>({
            web: { boxShadow: '0 8px 18px rgba(75,59,230,0.28)' } as ViewStyle,
            default: { shadowColor: '#4B3BE6', shadowOpacity: 0.28, shadowRadius: 12, shadowOffset: { width: 0, height: 6 } },
          }),
        style,
      ]}
    >
      {loading ? (
        <ActivityIndicator color="#FFF" />
      ) : (
        <>
          {icon ? <Ionicons name={icon} size={20} color="#FFF" /> : null}
          <Text style={[typo.button, { color: '#FFF' }]}>{title}</Text>
        </>
      )}
    </Pressable>
  );
}

export function SecondaryButton({
  title,
  onPress,
  color,
  disabled,
}: {
  title: string;
  onPress: () => void;
  color?: string;
  disabled?: boolean;
}) {
  const theme = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => ({ minHeight: 44, alignItems: 'center', justifyContent: 'center', opacity: pressed || disabled ? 0.5 : 1 })}
    >
      <Text style={{ fontFamily: 'Nunito_800ExtraBold', fontSize: 16, color: color ?? theme.accent }}>{title}</Text>
    </Pressable>
  );
}

export function Field({ label, ...props }: TextInputProps & { label?: string }) {
  const theme = useTheme();
  return (
    <View style={{ gap: 6 }}>
      {label ? <Text style={[typo.footnote, { color: theme.textSecondary, fontWeight: '600' }]}>{label}</Text> : null}
      <TextInput
        placeholderTextColor={theme.textSecondary}
        {...props}
        style={[
          typo.body,
          {
            backgroundColor: theme.card,
            color: theme.textPrimary,
            borderRadius: 14,
            paddingHorizontal: 14,
            minHeight: 50,
            borderWidth: 1,
            borderColor: theme.track,
          },
          props.style,
        ]}
      />
    </View>
  );
}

export function ErrorText({ message }: { message: string | null | undefined }) {
  const theme = useTheme();
  if (!message) return null;
  return (
    <View style={{ backgroundColor: theme.danger.bg, borderRadius: 14, padding: 12, flexDirection: 'row', gap: 8 }}>
      <Ionicons name="alert-circle" size={18} color={theme.danger.text} />
      <Text style={[typo.subheadline, { color: theme.danger.text, flex: 1 }]}>{message}</Text>
    </View>
  );
}

export function ProgressBar({ fraction, color, height = 8 }: { fraction: number; color: string; height?: number }) {
  const theme = useTheme();
  return (
    <View style={{ height, borderRadius: height / 2, backgroundColor: theme.track, overflow: 'hidden' }}>
      <View
        style={{ width: `${Math.round(Math.max(0, Math.min(1, fraction)) * 100)}%`, height, borderRadius: height / 2, backgroundColor: color }}
      />
    </View>
  );
}

export function ProgressRing({
  fraction,
  size = 76,
  stroke = 9,
  color,
  children,
}: {
  fraction: number;
  size?: number;
  stroke?: number;
  color: string;
  children?: ReactNode;
}) {
  const theme = useTheme();
  const r = (size - stroke) / 2;
  const circumference = 2 * Math.PI * r;
  const clamped = Math.max(0, Math.min(1, fraction));
  return (
    <View style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}>
      <Svg width={size} height={size} style={StyleSheet.absoluteFill}>
        <Circle cx={size / 2} cy={size / 2} r={r} stroke={theme.track} strokeWidth={stroke} fill="none" />
        <Circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          stroke={color}
          strokeWidth={stroke}
          fill="none"
          strokeLinecap="round"
          strokeDasharray={`${circumference} ${circumference}`}
          strokeDashoffset={circumference * (1 - clamped)}
          transform={`rotate(-90 ${size / 2} ${size / 2})`}
        />
      </Svg>
      {children}
    </View>
  );
}

/** Status control of a task row: ring in the group fill, amber half for « en cours », green check for « terminée ». */
export function StatusControl({
  status,
  color,
  onPress,
  disabled,
}: {
  status: TaskStatus;
  color: ColorKey;
  onPress?: () => void;
  disabled?: boolean;
}) {
  const theme = useTheme();
  const fill = theme.fill[color];
  let inner: ReactNode;
  if (status === 'done') {
    inner = (
      <View style={{ width: 24, height: 24, borderRadius: 12, backgroundColor: theme.fill.green, alignItems: 'center', justifyContent: 'center' }}>
        <Ionicons name="checkmark" size={16} color="#FFF" />
      </View>
    );
  } else if (status === 'in_progress') {
    inner = (
      <View style={{ width: 24, height: 24, borderRadius: 12, borderWidth: 2.5, borderColor: theme.fill.amber, overflow: 'hidden' }}>
        <View style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: '50%', backgroundColor: theme.fill.amber }} />
      </View>
    );
  } else {
    inner = <View style={{ width: 24, height: 24, borderRadius: 12, borderWidth: 2.5, borderColor: fill }} />;
  }
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel="Changer le statut"
      disabled={disabled || !onPress}
      hitSlop={6}
      onPress={() => {
        if (Platform.OS !== 'web') void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light).catch(() => undefined);
        onPress?.();
      }}
      style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center', opacity: disabled ? 0.5 : 1 }}
    >
      {inner}
    </Pressable>
  );
}

export function TaskRowCard({
  row,
  color,
  onPress,
  onToggleStatus,
}: {
  row: TaskRow;
  color: ColorKey;
  onPress: () => void;
  onToggleStatus?: () => void;
}) {
  const theme = useTheme();
  const shownAssignees: PersonBadge[] = row.assignees.slice(0, 3);
  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        {
          backgroundColor: theme.card,
          borderRadius: radius.row,
          paddingVertical: 10,
          paddingRight: 14,
          paddingLeft: 4,
          flexDirection: 'row',
          alignItems: 'center',
          gap: 6,
          opacity: pressed ? 0.9 : 1,
        },
        theme.cardShadow,
      ]}
    >
      <StatusControl status={row.status} color={color} onPress={onToggleStatus} disabled={!row.canChangeStatus} />
      <View style={{ flex: 1, gap: 6 }}>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
          <Text
            style={[
              typo.headline,
              { color: row.isDone ? theme.textSecondary : theme.textPrimary, flexShrink: 1 },
              row.isDone && { textDecorationLine: 'line-through' },
            ]}
          >
            {row.title}
          </Text>
          {row.isNew ? (
            <View style={{ backgroundColor: theme.accentFill, borderRadius: 999, paddingHorizontal: 7, paddingVertical: 2 }}>
              <Text style={{ color: '#FFF', fontSize: 11, fontWeight: '700' }}>Nouveau</Text>
            </View>
          ) : null}
        </View>
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
          {row.groupAppearance && row.groupShortName ? (
            <Chip
              soft={theme.soft[row.groupAppearance.color]}
              label={`${row.groupAppearance.emoji ? `${row.groupAppearance.emoji} ` : ''}${row.groupShortName}`}
            />
          ) : null}
          {row.dueText ? (
            <Chip
              soft={row.isOverdue && !row.isDone ? theme.danger : { bg: theme.track, text: theme.textSecondary }}
              icon="calendar-outline"
              label={row.dueText}
            />
          ) : null}
          {row.isMyTurn ? <Chip soft={theme.accentSoft} icon="repeat" label="Ton tour" /> : null}
          {row.recurrenceText && !row.isMyTurn ? (
            <Chip soft={{ bg: theme.track, text: theme.textSecondary }} icon="repeat" label={row.recurrenceText} />
          ) : null}
          {row.checklistProgress ? (
            <Chip
              soft={theme.soft.teal}
              icon="list"
              label={`${row.checklistProgress.done}/${row.checklistProgress.total}`}
            />
          ) : null}
          {row.status === 'in_progress' ? <Chip soft={statusSoft(theme, 'in_progress')} label="En cours" /> : null}
        </View>
      </View>
      {row.assigneesText !== null ? (
        shownAssignees.length > 0 ? (
          <AvatarStack
            avatars={shownAssignees.map((badge) => badge.appearance)}
            more={row.assignees.length > 3 ? `+${row.assignees.length - 3}` : null}
            size={28}
          />
        ) : (
          <View
            accessibilityLabel="Personne"
            style={{ width: 28, height: 28, borderRadius: 14, borderWidth: 1.5, borderStyle: 'dashed', borderColor: theme.textSecondary }}
          />
        )
      ) : null}
    </Pressable>
  );
}

export function FloatingAddButton({ onPress, label }: { onPress: () => void; label: string }) {
  const theme = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      style={({ pressed }) => [
        {
          position: 'absolute',
          right: 20,
          bottom: 20,
          width: 60,
          height: 60,
          borderRadius: 20,
          backgroundColor: theme.accentFill,
          alignItems: 'center',
          justifyContent: 'center',
          opacity: pressed ? 0.85 : 1,
        },
        theme.cardShadow,
      ]}
    >
      <Ionicons name="add" size={32} color="#FFF" />
    </Pressable>
  );
}

export function EmptyState({ icon, title, message, children }: { icon: IconName; title: string; message?: string; children?: ReactNode }) {
  const theme = useTheme();
  return (
    <View style={{ alignItems: 'center', gap: 10, paddingVertical: 40, paddingHorizontal: 24 }}>
      <View style={{ width: 72, height: 72, borderRadius: 24, backgroundColor: theme.accentSoft.bg, alignItems: 'center', justifyContent: 'center' }}>
        <Ionicons name={icon} size={34} color={theme.accentSoft.text} />
      </View>
      <Text style={[typo.title3, { color: theme.textPrimary, textAlign: 'center' }]}>{title}</Text>
      {message ? <Text style={[typo.subheadline, { color: theme.textSecondary, textAlign: 'center' }]}>{message}</Text> : null}
      {children}
    </View>
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
    <Pressable
      disabled={!onPress}
      onPress={onPress}
      style={({ pressed }) => ({
        flexDirection: 'row',
        alignItems: 'center',
        gap: 12,
        minHeight: 52,
        paddingHorizontal: spacing.inner,
        borderBottomWidth: last ? 0 : StyleSheet.hairlineWidth * 2,
        borderBottomColor: theme.hairline,
        opacity: pressed ? 0.6 : 1,
      })}
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
    </Pressable>
  );
}

export function SectionTitle({ children, color }: { children: ReactNode; color?: string }) {
  const theme = useTheme();
  return (
    <Text style={[typo.title3, { color: color ?? theme.textPrimary, marginTop: 8, marginBottom: 2 }]}>{children}</Text>
  );
}

export function useThemeStyles<T>(make: (theme: Theme) => T): T {
  return make(useTheme());
}
