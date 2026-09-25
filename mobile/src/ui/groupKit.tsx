import { Ionicons } from '@expo/vector-icons';
import type { ReactNode } from 'react';
import { Pressable, Text, View, useWindowDimensions, type StyleProp, type TextStyle, type ViewStyle } from 'react-native';
import Animated, { Extrapolation, FadeInUp, interpolate, useAnimatedStyle, useReducedMotion } from 'react-native-reanimated';

import type { EmphasizedText } from '@/core/activityText';
import { COLOR_KEYS, colorLabel, type ColorKey } from '@/core/colorKey';
import type { TurnCard } from '@/core/groups';
import { activityBadgeTone, type ActivityFeedRow, type PodiumEntry } from '@/core/groupScreens';
import type { ActivityKind, GroupSummary, MemberRole } from '@/core/models';
import {
  avatarSymbol,
  groupAppearance,
  ME_NAME,
  OVERVIEW_WEEK_TITLE,
  overviewMemberAvatars,
  overviewMoreMembersText,
  overviewSummaryText,
  overviewWeekProgress,
  overviewWeekProgressText,
  roleLabel,
  type AvatarAppearance,
  type GroupOverview,
} from '@/core/presentation';

import { Avatar, AvatarStack, Chip, GroupTile, tap, useChipColors, type IconName } from './components';
import { AnimatedProgressBar, fadeIn, GENTLE, listLayout, PopIn, PressableScale, useSpringValue } from './motion';
import { fonts, radius, type Soft, type Theme, type as typo, useTheme } from './theme';

// The pieces of the groups screens (docs/DESIGN-V2.md §5, §7.2, §7.4, §7.5; Swift `GroupCards`, `GroupTurnCard`,
// `Podium`, `Pickers`, `GroupActivityView`, `MembersView`).

// MARK: - Extra tokens

/** Tokens of docs/DESIGN-V2-COMPONENTS.md §1 used here (`SoftTone.neutral.fill` is not in `theme.ts`). */
export function extraTokens(theme: Theme) {
  return { trackStrong: theme.trackStrong, textTertiary: theme.textTertiary, neutral: theme.neutral, neutralFill: '#5F5C6E' };
}

/** `ColorKey.accent`: the fill in light mode, the bright soft text in dark mode (lines and glyphs on `card`). */
export function colorAccent(theme: Theme, key: ColorKey): string {
  return theme.dark ? theme.soft[key].text : theme.fill[key];
}

// MARK: - Basics

/** A rounded square with a symbol in a soft pair (radius 31 % of the side). Decorative. */
export function IconTile({ icon, soft, size = 32 }: { icon: IconName; soft: Soft; size?: number }) {
  return (
    <View
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.31,
        backgroundColor: soft.bg,
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <Ionicons name={icon} size={size * 0.52} color={soft.text} />
    </View>
  );
}

/** An avatar with an outer highlight ring (the current turn in the accent, the podium's first in amber). */
export function RingedAvatar({
  appearance,
  size,
  highlight,
  surface,
}: {
  appearance: AvatarAppearance;
  size: number;
  highlight: string | null;
  surface?: string;
}) {
  const theme = useTheme();
  if (!highlight) return <Avatar appearance={appearance} size={size} />;
  return (
    <View style={{ padding: 2, borderRadius: size, borderWidth: 2, borderColor: highlight, backgroundColor: surface ?? theme.card }}>
      <Avatar appearance={appearance} size={size} />
    </View>
  );
}

/** « Emoji », « Couleur »: a subheadline bold textSecondary header above a picker. */
export function PickerSection({ title, children }: { title: string; children: ReactNode }) {
  const theme = useTheme();
  return (
    <View style={{ gap: 10 }}>
      <Text accessibilityRole="header" style={[typo.subheadline, { fontFamily: fonts.extraBold, color: theme.textSecondary }]}>
        {title}
      </Text>
      {children}
    </View>
  );
}

/** A small section title above a card or a list (« Inviter », « Terminées », « Aujourd’hui »). */
export function SmallSectionTitle({ children, style }: { children: ReactNode; style?: StyleProp<ViewStyle> }) {
  const theme = useTheme();
  return (
    <View style={style}>
      <Text accessibilityRole="header" style={[typo.subheadline, { fontFamily: fonts.heavy, fontSize: 16, color: theme.textSecondary }]}>
        {children}
      </Text>
    </View>
  );
}

/** A large block title (« À qui le tour ? », « Fil d’activité ») with an optional trailing text. */
export function LargeSectionTitle({ title, trailing }: { title: string; trailing?: string | null }) {
  const theme = useTheme();
  return (
    <View style={{ flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between', gap: 12 }}>
      <Text accessibilityRole="header" style={[typo.title3, { fontFamily: fonts.heavy, fontSize: 22, color: theme.textPrimary, flexShrink: 1 }]}>
        {title}
      </Text>
      {trailing ? <Text style={[typo.subheadline, { color: theme.textSecondary }]}>{trailing}</Text> : null}
    </View>
  );
}

/** A 44 pt filter chip: selected in textPrimary with background-colored text, idle on card with an outline. */
export function FilterChipButton({ label, selected, onPress }: { label: string; selected: boolean; onPress: () => void }) {
  const theme = useTheme();
  const extra = extraTokens(theme);
  // The colors cross-fade with the selection; the chip springs to its place when the counts change its width.
  const colors = useChipColors(selected, theme.textPrimary, theme.card, theme.background, theme.textPrimary, extra.trackStrong);
  return (
    <PressableScale
      accessibilityRole="button"
      accessibilityState={{ selected }}
      onPress={() => {
        tap();
        onPress();
      }}
      scaleTo={0.95}
      pressedOpacity={0.85}
      layout={listLayout}
      style={[{ minHeight: 44, paddingHorizontal: 18, borderRadius: 999, justifyContent: 'center', borderWidth: 1.5 }, colors.chip]}
    >
      <Animated.Text style={[{ fontFamily: fonts.extraBold, fontSize: 16 }, colors.text]}>{label}</Animated.Text>
    </PressableScale>
  );
}

/** A group tile that shows a people symbol while the name has no letter yet (the create preview). */
export function PreviewTile({ appearance, size }: { appearance: AvatarAppearance; size: number }) {
  const theme = useTheme();
  if (appearance.emoji || (appearance.initials !== '' && appearance.initials !== '?')) {
    return <GroupTile appearance={appearance} size={size} />;
  }
  return (
    <View
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.33,
        backgroundColor: theme.fill[appearance.color],
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <Ionicons name="people" size={size * 0.45} color="#FFF" />
    </View>
  );
}

/** The white tile of a group's hero, with the emoji or the initials in the group's fill. */
export function HeroTile({ appearance, size }: { appearance: AvatarAppearance; size: number }) {
  const theme = useTheme();
  return (
    <View
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.33,
        backgroundColor: '#FFFFFF',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <Text
        style={
          appearance.emoji
            ? { fontSize: size * 0.52 }
            : { fontFamily: fonts.heavy, fontSize: size * 0.36, color: theme.fill[appearance.color] }
        }
      >
        {avatarSymbol(appearance)}
      </Text>
    </View>
  );
}

// MARK: - Pickers

/** The 9 colors in a 3 × 3 grid of wide rounded swatches; the selected one has a white check and a ring. */
export function SwatchGrid({ isSelected, onSelect }: { isSelected: (key: ColorKey) => boolean; onSelect: (key: ColorKey) => void }) {
  const theme = useTheme();
  return (
    <View style={{ flexDirection: 'row', flexWrap: 'wrap', marginHorizontal: -5 }}>
      {COLOR_KEYS.map((key) => {
        const selected = isSelected(key);
        return (
          <View key={key} style={{ width: '33.333%', padding: 5 }}>
            <Pressable
              accessibilityRole="button"
              accessibilityLabel={colorLabel(key)}
              accessibilityState={{ selected }}
              onPress={() => {
                tap();
                onSelect(key);
              }}
              style={({ pressed }) => ({
                padding: 3,
                borderRadius: 17,
                borderWidth: 2,
                borderColor: selected ? colorAccent(theme, key) : 'transparent',
                transform: [{ scale: pressed ? 0.96 : 1 }],
              })}
            >
              <View
                style={{ height: 44, borderRadius: 14, backgroundColor: theme.fill[key], alignItems: 'center', justifyContent: 'center' }}
              >
                {selected ? (
                  <PopIn>
                    <Ionicons name="checkmark" size={24} color="#FFF" />
                  </PopIn>
                ) : null}
              </View>
            </Pressable>
          </View>
        );
      })}
    </View>
  );
}

/**
 * The emoji grid (6 columns of rounded bordered cells), the selected cell on accentSoft with an accent ring. With
 * `initials`, a first cell shows them and stands for null.
 */
export function EmojiGrid({
  options,
  selection,
  initials,
  columns = 6,
  onSelect,
}: {
  options: readonly string[];
  selection: string | null;
  initials?: string;
  columns?: number;
  onSelect: (emoji: string | null) => void;
}) {
  const theme = useTheme();
  const cell = (key: string, selected: boolean, label: ReactNode, accessibilityLabel: string, value: string | null) => (
    <View key={key} style={{ width: `${100 / columns}%`, padding: 4 }}>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={accessibilityLabel}
        accessibilityState={{ selected }}
        onPress={() => {
          tap();
          onSelect(value);
        }}
        style={({ pressed }) => ({
          minHeight: 48,
          aspectRatio: 1.08,
          borderRadius: 14,
          alignItems: 'center',
          justifyContent: 'center',
          backgroundColor: selected ? theme.accentSoft.bg : theme.card,
          borderWidth: selected ? 2.5 : 1.5,
          borderColor: selected ? theme.accent : theme.hairline,
          transform: [{ scale: pressed ? 0.95 : 1 }],
        })}
      >
        {label}
      </Pressable>
    </View>
  );
  return (
    <View style={{ flexDirection: 'row', flexWrap: 'wrap', marginHorizontal: -4 }}>
      {initials !== undefined
        ? cell(
            'initials',
            selection === null,
            <Text numberOfLines={1} adjustsFontSizeToFit style={{ fontFamily: fonts.heavy, fontSize: 18, color: theme.textPrimary }}>
              {initials}
            </Text>,
            'Initiales',
            null,
          )
        : null}
      {options.map((emoji) => cell(emoji, selection === emoji, <Text style={{ fontSize: 26 }}>{emoji}</Text>, emoji, emoji))}
    </View>
  );
}

// MARK: - Groups list

/** A group of « Groupes »: tile, name, « 3 membres · 4 à faire », avatars, and the week's progress. */
export function GroupCard({ summary, overview, onPress }: { summary: GroupSummary; overview: GroupOverview | null; onPress: () => void }) {
  const theme = useTheme();
  const appearance = groupAppearance(summary.group);
  const avatars = overview ? overviewMemberAvatars(overview) : [];
  const subtitle = overview ? overviewSummaryText(overview) : summary.myRole === 'admin' ? 'Tu es admin' : 'Tu es membre';
  return (
    <PressableScale
      accessibilityRole="button"
      accessibilityLabel={`${summary.group.name}, ${subtitle}${overview ? `, ${OVERVIEW_WEEK_TITLE} ${overviewWeekProgressText(overview)}` : ''}`}
      onPress={onPress}
      scaleTo={0.975}
      pressedOpacity={0.95}
      style={[{ backgroundColor: theme.card, borderRadius: radius.card, padding: 18, gap: 16 }, theme.cardShadow]}
    >
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
        <GroupTile appearance={appearance} size={56} />
        <View style={{ flex: 1, gap: 3 }}>
          <Text style={{ fontFamily: fonts.heavy, fontSize: 18, lineHeight: 23, color: theme.textPrimary }}>{summary.group.name}</Text>
          <Text style={[typo.subheadline, { color: theme.textSecondary }]}>{subtitle}</Text>
        </View>
        {avatars.length > 0 ? <AvatarStack avatars={avatars} more={overview ? overviewMoreMembersText(overview) : null} size={30} /> : null}
      </View>
      {overview ? (
        <View style={{ gap: 8 }}>
          <View style={{ flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between', gap: 8 }}>
            <Text style={[typo.footnote, { color: theme.textSecondary }]}>{OVERVIEW_WEEK_TITLE}</Text>
            <Text style={[typo.footnote, { fontWeight: '700', color: theme.textPrimary }]}>{overviewWeekProgressText(overview)}</Text>
          </View>
          <HairlineProgressBar fraction={overviewWeekProgress(overview)} color={theme.fill[appearance.color]} />
        </View>
      ) : null}
    </PressableScale>
  );
}

/** A progress bar on the `hairline` track (the group cards). */
function HairlineProgressBar({ fraction, color }: { fraction: number; color: string }) {
  const theme = useTheme();
  return <AnimatedProgressBar fraction={fraction} color={color} height={8} track={theme.dark ? theme.track : theme.hairline} delay={120} />;
}

/** The dashed « Rejoindre un groupe » card: key tile, title, « Avec un code d’invitation », chevron. */
export function JoinGroupCard({ onPress }: { onPress: () => void }) {
  const theme = useTheme();
  const extra = extraTokens(theme);
  return (
    <PressableScale
      accessibilityRole="button"
      accessibilityLabel="Rejoindre un groupe"
      accessibilityHint="Avec un code d’invitation"
      onPress={onPress}
      scaleTo={0.975}
      style={{
        flexDirection: 'row',
        alignItems: 'center',
        gap: 14,
        paddingHorizontal: 16,
        paddingVertical: 14,
        borderRadius: radius.card,
        borderWidth: 2,
        borderStyle: 'dashed',
        borderColor: extra.trackStrong,
      }}
    >
      <IconTile icon="key" soft={theme.accentSoft} size={48} />
      <View style={{ flex: 1, gap: 2 }}>
        <Text style={[typo.body, { fontWeight: '700', color: theme.textPrimary }]}>Rejoindre un groupe</Text>
        <Text style={[typo.subheadline, { color: theme.textSecondary }]}>Avec un code d’invitation</Text>
      </View>
      <Ionicons name="chevron-forward" size={18} color={theme.textSecondary} />
    </PressableScale>
  );
}

// MARK: - Group screen

/** A card of « À qui le tour ? »: the task and its due date, whose turn it is, who comes next. */
export function TurnCardView({ card, groupColor, onPress }: { card: TurnCard; groupColor: ColorKey; onPress: () => void }) {
  const theme = useTheme();
  const extra = extraTokens(theme);
  const { fontScale } = useWindowDimensions();
  const width = Math.min(236 * Math.max(fontScale, 1), 320);
  const holder = card.current;
  return (
    <PressableScale
      accessibilityRole="button"
      accessibilityLabel={[
        card.title,
        card.dueText ? `${card.isOverdue ? 'en retard, ' : ''}échéance ${card.dueText.toLowerCase()}` : null,
        holder ? (holder.isMe ? 'c’est ton tour' : `au tour de ${holder.shortName}`) : 'personne n’a le tour',
        card.nextText,
      ]
        .filter(Boolean)
        .join(', ')}
      onPress={onPress}
      scaleTo={0.97}
      pressedOpacity={0.95}
      style={[{ width, backgroundColor: theme.card, borderRadius: radius.row, padding: 14, gap: 12 }, theme.cardShadow]}
    >
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
        <IconTile icon="sync" soft={theme.soft[groupColor]} size={36} />
        <View style={{ flex: 1, gap: 1 }}>
          <Text style={[typo.subheadline, { fontWeight: '700', color: theme.textPrimary }]}>{card.title}</Text>
          {card.dueText ? (
            <Text
              style={[
                typo.footnote,
                { color: card.isOverdue ? theme.danger.text : theme.textSecondary, fontWeight: card.isOverdue ? '700' : '400' },
              ]}
            >
              {card.dueText}
            </Text>
          ) : null}
        </View>
      </View>
      <View style={{ flexDirection: 'row', alignItems: 'center', flexWrap: 'wrap', columnGap: 8, rowGap: 4 }}>
        {holder ? (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
            <RingedAvatar appearance={holder.appearance} size={28} highlight={card.isMyTurn ? theme.accent : null} />
            <Text style={[typo.subheadline, { fontFamily: fonts.heavy, color: card.isMyTurn ? theme.accent : theme.textPrimary }]}>
              {holder.isMe ? ME_NAME : holder.shortName}
            </Text>
          </View>
        ) : (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
            <View style={{ width: 28, height: 28, borderRadius: 14, borderWidth: 1.5, borderStyle: 'dashed', borderColor: extra.textTertiary }} />
            <Text style={[typo.subheadline, { fontFamily: fonts.heavy, color: theme.textSecondary }]}>Personne</Text>
          </View>
        )}
        {card.nextText ? <Text style={[typo.footnote, { color: theme.textSecondary }]}>{card.nextText}</Text> : null}
      </View>
    </PressableScale>
  );
}

// MARK: - Activité

/** Draws an `EmphasizedText`: the people in bold. */
export function Emphasized({ text, style }: { text: EmphasizedText; style?: StyleProp<TextStyle> }) {
  return (
    <Text style={style}>
      {text.map((part, index) => (
        <Text key={index} style={part.isEmphasized ? { fontWeight: '700' } : undefined}>
          {part.text}
        </Text>
      ))}
    </Text>
  );
}

const PODIUM_HEIGHTS = [104, 72, 52] as const;

/** The weekly podium, columns in the order given (pass the stage order: 2nd, 1st, 3rd). */
export function Podium({ entries }: { entries: readonly PodiumEntry[] }) {
  const theme = useTheme();
  const { fontScale } = useWindowDimensions();
  const scale = Math.min(Math.max(fontScale, 1), 1.8);
  return (
    <View style={{ flexDirection: 'row', alignItems: 'flex-end', gap: 10 }}>
      {entries.map((entry, index) => (
        <PodiumColumn key={entry.person.id} entry={entry} scale={scale} delay={PODIUM_STEP * index} />
      ))}
    </View>
  );
}

/** Delay between the columns growing, in stage order (2nd, 1st, 3rd). */
const PODIUM_STEP = 110;

/** A column of the podium: its bar grows from the floor, then the person and the trophy drop in on top. */
function PodiumColumn({ entry, scale, delay }: { entry: PodiumEntry; scale: number; delay: number }) {
  const theme = useTheme();
  const reduced = useReducedMotion();
  const first = entry.place === 1;
  const soft = first ? theme.soft.amber : theme.soft[entry.person.appearance.color];
  const grow = useSpringValue(1, { config: GENTLE, delay: 80 + delay });
  const barStyle = useAnimatedStyle(() => ({ transform: [{ scaleY: Math.max(grow.value, 0) }] }));
  // The labels of the bar show once it is nearly grown (so that they are never seen squashed).
  const labelStyle = useAnimatedStyle(() => ({ opacity: interpolate(grow.value, [0.7, 1], [0, 1], Extrapolation.CLAMP) }));
  const dropIn = reduced ? fadeIn : FadeInUp.delay(260 + delay).springify().damping(14).stiffness(180);
  return (
    <View
      accessible
      accessibilityLabel={`${entry.person.shortName}, ${entry.placeText}, ${entry.count} ${entry.count <= 1 ? 'tâche' : 'tâches'}`}
      style={{ flex: 1, alignItems: 'center', gap: 6 }}
    >
      <Animated.View entering={dropIn} style={{ alignItems: 'center', gap: 6 }}>
        {first ? <Ionicons name="trophy" size={24} color={colorAccent(theme, 'amber')} /> : null}
        <RingedAvatar appearance={entry.person.appearance} size={first ? 48 : 40} highlight={first ? colorAccent(theme, 'amber') : null} />
        <Text
          numberOfLines={2}
          style={[typo.subheadline, { fontFamily: first ? fonts.heavy : fonts.extraBold, fontSize: 16, color: theme.textPrimary, textAlign: 'center' }]}
        >
          {entry.person.shortName}
        </Text>
      </Animated.View>
      <Animated.View
        style={[
          {
            alignSelf: 'stretch',
            minHeight: (PODIUM_HEIGHTS[entry.place - 1] ?? 52) * scale,
            paddingVertical: 8,
            alignItems: 'center',
            justifyContent: 'center',
            backgroundColor: soft.bg,
            borderTopLeftRadius: 14,
            borderTopRightRadius: 14,
            borderBottomLeftRadius: 6,
            borderBottomRightRadius: 6,
            transformOrigin: 'bottom',
          },
          barStyle,
        ]}
      >
        <Animated.View style={[{ alignItems: 'center' }, labelStyle]}>
          <Text style={{ fontFamily: fonts.heavy, fontSize: first ? 30 : 24, lineHeight: first ? 36 : 30, color: soft.text, fontVariant: ['tabular-nums'] }}>
            {entry.count}
          </Text>
          <Text style={{ fontFamily: fonts.heavy, fontSize: 13, color: soft.text }}>{entry.placeText}</Text>
        </Animated.View>
      </Animated.View>
    </View>
  );
}

const ACTIVITY_SYMBOLS: Record<ActivityKind, IconName> = {
  task_created: 'add',
  task_completed: 'checkmark',
  turn_started: 'sync',
  checklist_item_done: 'list',
  member_joined: 'person-add',
  member_left: 'person-remove',
};

/** One event of the feed: the avatar with the kind's badge (or the kind's tile), the sentence, the time. */
export function ActivityRowView({ row, onPress }: { row: ActivityFeedRow; onPress?: () => void }) {
  const theme = useTheme();
  const extra = extraTokens(theme);
  const tone = activityBadgeTone(row.event.kind);
  const badgeFill = tone === 'accent' ? theme.accentFill : tone === 'neutral' ? extra.neutralFill : theme.fill[tone];
  const tileSoft = tone === 'accent' ? theme.accentSoft : tone === 'neutral' ? extra.neutral : theme.soft[tone];
  const symbol = ACTIVITY_SYMBOLS[row.event.kind];
  const content = (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 12 }}>
      {row.person ? (
        <View style={{ paddingRight: 5, paddingBottom: 5 }}>
          <Avatar appearance={row.person.appearance} size={38} />
          <View
            style={{
              position: 'absolute',
              right: -2,
              bottom: -2,
              width: 24,
              height: 24,
              borderRadius: 12,
              backgroundColor: theme.card,
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <View style={{ width: 20, height: 20, borderRadius: 10, backgroundColor: badgeFill, alignItems: 'center', justifyContent: 'center' }}>
              <Ionicons name={symbol} size={12} color="#FFF" />
            </View>
          </View>
        </View>
      ) : (
        <IconTile icon={symbol} soft={tileSoft} size={38} />
      )}
      <Emphasized text={row.text} style={[typo.subheadline, { flex: 1, fontSize: 16, lineHeight: 22, color: theme.textPrimary }]} />
      <Text style={[typo.footnote, { fontSize: 15, color: theme.textSecondary, fontVariant: ['tabular-nums'] }]}>{row.timeText}</Text>
    </View>
  );
  if (!onPress) return content;
  return (
    <Pressable accessibilityRole="button" onPress={onPress} style={({ pressed }) => ({ opacity: pressed ? 0.7 : 1 })}>
      {content}
    </Pressable>
  );
}

// MARK: - Membres

/** A card of rows separated by hairlines that start after the leading tile (the iOS inset grouped look). */
export function InsetCard({ children, style }: { children: ReactNode; style?: StyleProp<ViewStyle> }) {
  const theme = useTheme();
  return <View style={[{ backgroundColor: theme.card, borderRadius: radius.card, paddingLeft: 16, overflow: 'hidden' }, theme.cardShadow, style]}>{children}</View>;
}

/** A row of an `InsetCard`: an icon tile, the title, an optional trailing view. */
export function InsetRow({
  icon,
  soft,
  title,
  titleColor,
  trailing,
  onPress,
  disabled,
  first,
  inset = 50,
}: {
  icon?: IconName;
  soft?: Soft;
  title?: string;
  titleColor?: string;
  trailing?: ReactNode;
  onPress?: () => void;
  disabled?: boolean;
  first?: boolean;
  inset?: number;
}) {
  const theme = useTheme();
  const body = (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 16, minHeight: 60, paddingRight: 16 }}>
      {icon && soft ? <IconTile icon={icon} soft={soft} size={34} /> : null}
      <Text style={[typo.body, { flex: 1, fontSize: 18, color: titleColor ?? theme.textPrimary }]}>{title}</Text>
      {trailing}
    </View>
  );
  return (
    <View>
      {first ? null : <View style={{ height: 1, marginLeft: inset, backgroundColor: theme.dark ? theme.hairline : '#E6E4EE' }} />}
      {onPress ? (
        <PressableScale
          accessibilityRole="button"
          accessibilityState={{ disabled }}
          disabled={disabled}
          onPress={onPress}
          scaleTo={0.985}
          pressedOpacity={0.6}
        >
          {body}
        </PressableScale>
      ) : (
        body
      )}
    </View>
  );
}

/** « Admin » (a star on the soft accent) or « Membre » (neutral). */
export function RoleChip({ role }: { role: MemberRole }) {
  const theme = useTheme();
  const extra = extraTokens(theme);
  return (
    <View accessibilityLabel={`Rôle\u{a0}: ${roleLabel(role)}`}>
      <Chip
        soft={role === 'admin' ? theme.accentSoft : extra.neutral}
        icon={role === 'admin' ? 'star' : undefined}
        label={roleLabel(role)}
        style={{ paddingHorizontal: 12, paddingVertical: 5 }}
      />
    </View>
  );
}

/** Small footnote under a card (« Toute personne qui a ce code peut rejoindre le groupe. »). */
export function CardFooter({ children }: { children: ReactNode }) {
  const theme = useTheme();
  return <Text style={[typo.footnote, { fontSize: 14, color: theme.textSecondary, paddingHorizontal: 18, marginTop: -4 }]}>{children}</Text>;
}
