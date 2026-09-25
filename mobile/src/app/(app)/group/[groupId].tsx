import { Ionicons } from '@expo/vector-icons';
import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState } from 'react';
import { ActionSheetIOS, Alert, Platform, Pressable, ScrollView, Share, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { activityDayTitle, activityText } from '@/core/activityText';
import { errorMessage } from '@/core/appError';
import { FrenchCalendar } from '@/core/calendar';
import {
  GROUP_EMPTY_MESSAGE,
  GROUP_GONE_MESSAGE,
  GROUP_NO_MATCH_MESSAGE,
  groupFilterChips,
  groupTabLabel,
  groupTaskRows,
  membersSummary,
  TURN_CARDS_TITLE,
  turnCards,
  type GroupContext,
  type GroupTab,
  type TurnCard,
} from '@/core/groups';
import { formatInviteCode } from '@/core/inviteCode';
import type { ActivityEvent } from '@/core/models';
import { GroupPermissions, canCreateTask } from '@/core/permissions';
import {
  groupAppearance,
  MemberDirectory,
  nextStatus,
  profileAppearance,
  togglingFilterChip,
} from '@/core/presentation';
import { ALL_TASKS_FILTER, type TaskFilter } from '@/core/taskList';
import { groups, tasks } from '@/data/api';
import { keys, useActivity, useGroupTasks, useMembers, useMyGroups, useTaskMutation } from '@/data/queries';
import { useUserId } from '@/data/session';
import {
  Avatar,
  AvatarStack,
  Card,
  EmptyState,
  ErrorText,
  FilterChip,
  FloatingAddButton,
  GroupTile,
  Loading,
  SegmentedPill,
  TaskRowCard,
} from '@/ui/components';
import { spacing, type as typo, useTheme } from '@/ui/theme';

/** The group screen (screenshots 05-groupe, 06-activite). */
export default function GroupScreen() {
  const { groupId = '' } = useLocalSearchParams<{ groupId: string }>();
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const userId = useUserId();
  const client = useQueryClient();
  const myGroups = useMyGroups();
  const summary = myGroups.data?.find((item) => item.group.id === groupId) ?? null;
  const members = useMembers(groupId);
  const groupTasks = useGroupTasks(groupId);
  const [tab, setTab] = useState<GroupTab>('tasks');
  const [filter, setFilter] = useState<TaskFilter>(ALL_TASKS_FILTER);
  const activity = useActivity(groupId, tab === 'activity');
  const statusMutation = useTaskMutation((args: { id: string; status: 'todo' | 'in_progress' | 'done' }) =>
    tasks.setStatus(args.id, args.status),
  );

  const now = Date.now();
  const calendar = useMemo(() => FrenchCalendar.device(), []);
  const context: GroupContext | null =
    groupTasks.data && members.data
      ? { tasks: groupTasks.data, members: members.data, myRole: summary?.myRole ?? null, userId, now, calendar }
      : null;

  if (myGroups.isSuccess && summary === null) {
    return (
      <View style={{ flex: 1, backgroundColor: theme.background, paddingTop: insets.top + 20 }}>
        <EmptyState icon="alert-circle" title="Groupe introuvable" message={GROUP_GONE_MESSAGE} />
      </View>
    );
  }
  if (summary === null) return <Loading />;

  const group = summary.group;
  const appearance = groupAppearance(group);
  const fill = theme.fill[appearance.color];
  const soft = theme.soft[appearance.color];
  const role = summary.myRole;
  const directory = members.data ? new MemberDirectory(members.data, userId) : null;

  const invite = async () => {
    try {
      const code = formatInviteCode(await groups.inviteCode(groupId));
      await Share.share({ message: `Rejoins « ${group.name} » sur Équipe avec le code ${code}` });
    } catch (caught) {
      Alert.alert('Inviter', errorMessage(caught) ?? '');
    }
  };

  const confirm = (title: string, message: string, action: string, run: () => Promise<void>) => {
    Alert.alert(title, message, [
      { text: 'Annuler', style: 'cancel' },
      {
        text: action,
        style: 'destructive',
        onPress: () => {
          run()
            .then(() => {
              void client.invalidateQueries({ queryKey: keys.groups });
              router.back();
            })
            .catch((caught: unknown) => Alert.alert(title, errorMessage(caught) ?? ''));
        },
      },
    ]);
  };

  const menu = () => {
    const items: { label: string; run: () => void; destructive?: boolean }[] = [];
    if (GroupPermissions.canSeeInviteCode(role)) items.push({ label: 'Inviter', run: () => void invite() });
    items.push({
      label: 'Quitter le groupe',
      destructive: true,
      run: () => confirm('Quitter le groupe', `Tu ne verras plus « ${group.name} ».`, 'Quitter', () => groups.leave(groupId)),
    });
    if (GroupPermissions.canDelete(role)) {
      items.push({
        label: 'Supprimer le groupe',
        destructive: true,
        run: () =>
          confirm(
            'Supprimer le groupe',
            `« ${group.name} » et toutes ses tâches seront supprimés pour tous ses membres.`,
            'Supprimer',
            () => groups.delete(groupId),
          ),
      });
    }
    if (Platform.OS === 'ios') {
      ActionSheetIOS.showActionSheetWithOptions(
        {
          options: [...items.map((item) => item.label), 'Annuler'],
          cancelButtonIndex: items.length,
          destructiveButtonIndex: items.flatMap((item, index) => (item.destructive ? [index] : [])),
        },
        (index) => items[index]?.run(),
      );
    } else {
      Alert.alert(group.name, undefined, [
        ...items.map((item) => ({ text: item.label, onPress: item.run, style: item.destructive ? ('destructive' as const) : ('default' as const) })),
        { text: 'Annuler', style: 'cancel' as const },
      ]);
    }
  };

  const rows = context ? groupTaskRows(context, filter) : [];
  const chips = context ? groupFilterChips(context, filter) : [];
  const cards = context ? turnCards(context) : [];
  const error = members.error ?? groupTasks.error;

  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      <ScrollView contentContainerStyle={{ paddingBottom: insets.bottom + 110 }}>
        {/* Hero */}
        <View
          style={{
            backgroundColor: fill,
            paddingTop: insets.top + 6,
            paddingHorizontal: spacing.page,
            paddingBottom: 22,
            borderBottomLeftRadius: 32,
            borderBottomRightRadius: 32,
            gap: 18,
          }}
        >
          <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
            <HeroButton icon="chevron-back" label="Retour" onPress={() => router.back()} />
            <View style={{ flexDirection: 'row', gap: 10 }}>
              {GroupPermissions.canSeeInviteCode(role) ? (
                <Pressable
                  onPress={() => void invite()}
                  style={{
                    backgroundColor: '#FFF',
                    borderRadius: 999,
                    paddingHorizontal: 14,
                    height: 40,
                    flexDirection: 'row',
                    alignItems: 'center',
                    gap: 6,
                  }}
                >
                  <Ionicons name="person-add" size={16} color={fill} />
                  <Text style={{ fontFamily: 'Nunito_800ExtraBold', color: fill, fontSize: 15 }}>Inviter</Text>
                </Pressable>
              ) : null}
              <HeroButton icon="ellipsis-horizontal" label="Plus" onPress={menu} />
            </View>
          </View>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
            <GroupTile appearance={appearance} size={64} onWhite />
            <View style={{ flex: 1, gap: 6 }}>
              <Text style={{ fontFamily: 'Nunito_900Black', fontSize: 26, lineHeight: 31, color: '#FFF' }}>{group.name}</Text>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                {members.data ? (
                  <AvatarStack
                    avatars={members.data.slice(0, 3).map((member) => profileAppearance(member.user))}
                    more={members.data.length > 3 ? `+${members.data.length - 3}` : null}
                    size={24}
                    ringColor={fill}
                  />
                ) : null}
                <Text style={[typo.footnote, { color: 'rgba(255,255,255,0.92)', flexShrink: 1 }]}>
                  {membersSummary(members.data?.length ?? 0, role)}
                </Text>
              </View>
            </View>
          </View>
        </View>

        <View style={{ paddingHorizontal: spacing.dense, paddingTop: 16, gap: 14 }}>
          <SegmentedPill
            options={(['tasks', 'activity'] as const).map((key) => ({ key, label: groupTabLabel(key) }))}
            value={tab}
            onChange={setTab}
          />
          {error ? <ErrorText message={errorMessage(error)} /> : null}

          {tab === 'tasks' ? (
            <>
              {!context && !error ? <Loading /> : null}
              {cards.length > 0 ? (
                <View style={{ gap: 8 }}>
                  <Text style={[typo.title3, { color: theme.textPrimary }]}>{TURN_CARDS_TITLE}</Text>
                  <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 10, paddingVertical: 4 }}>
                    {cards.map((card) => (
                      <TurnCardView key={card.id} card={card} />
                    ))}
                  </ScrollView>
                </View>
              ) : null}
              {context && context.tasks.length > 0 ? (
                <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8, paddingVertical: 4 }}>
                  {chips.map((chip) => (
                    <FilterChip
                      key={chip.id}
                      label={chip.countedLabel}
                      selected={chip.isSelected}
                      onPress={() => setFilter(togglingFilterChip(chip.kind, filter))}
                    />
                  ))}
                </ScrollView>
              ) : null}
              {context && rows.length === 0 ? (
                <EmptyState
                  icon="checkmark-done"
                  title={context.tasks.length === 0 ? 'Rien à faire' : 'Aucun résultat'}
                  message={context.tasks.length === 0 ? GROUP_EMPTY_MESSAGE : GROUP_NO_MATCH_MESSAGE}
                />
              ) : null}
              {rows.map((row) => (
                <TaskRowCard
                  key={row.id}
                  row={row}
                  color={appearance.color}
                  onPress={() => router.push(`/task/${row.id}`)}
                  onToggleStatus={() => statusMutation.mutate({ id: row.id, status: nextStatus(row.status) })}
                />
              ))}
              {statusMutation.error ? <ErrorText message={errorMessage(statusMutation.error)} /> : null}
            </>
          ) : (
            <ActivityList events={activity.data} loading={activity.isPending} error={activity.error} directory={directory} />
          )}
        </View>
      </ScrollView>
      {tab === 'tasks' && canCreateTask(role) ? (
        <FloatingAddButton label="Nouvelle tâche" onPress={() => router.push({ pathname: '/new-task', params: { groupId } })} />
      ) : null}
    </View>
  );
}

function HeroButton({ icon, label, onPress }: { icon: 'chevron-back' | 'ellipsis-horizontal'; label: string; onPress: () => void }) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(255,255,255,0.22)', alignItems: 'center', justifyContent: 'center' }}
    >
      <Ionicons name={icon} size={22} color="#FFF" />
    </Pressable>
  );
}

function TurnCardView({ card }: { card: TurnCard }) {
  const theme = useTheme();
  return (
    <Pressable onPress={() => router.push(`/task/${card.id}`)}>
      <Card style={{ width: 210, gap: 10 }}>
        <Text style={[typo.headline, { color: theme.textPrimary }]} numberOfLines={1}>
          {card.title}
        </Text>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
          {card.current ? <Avatar appearance={card.current.appearance} size={32} ring={card.isMyTurn ? theme.accent : undefined} /> : null}
          <View style={{ flex: 1 }}>
            <Text style={[typo.subheadline, { color: theme.textPrimary, fontWeight: '700' }]} numberOfLines={1}>
              {card.isMyTurn ? 'C’est ton tour' : card.current ? card.current.shortName : 'Personne'}
            </Text>
            {card.nextText ? (
              <Text style={[typo.footnote, { color: theme.textSecondary }]} numberOfLines={1}>
                {card.nextText}
              </Text>
            ) : null}
          </View>
        </View>
        {card.dueText ? (
          <Text style={[typo.footnote, { color: card.isOverdue ? theme.danger.text : theme.textSecondary }]}>{card.dueText}</Text>
        ) : null}
      </Card>
    </Pressable>
  );
}

function ActivityList({
  events,
  loading,
  error,
  directory,
}: {
  events: ActivityEvent[] | undefined;
  loading: boolean;
  error: unknown;
  directory: MemberDirectory | null;
}) {
  const theme = useTheme();
  const userId = useUserId();
  const calendar = useMemo(() => FrenchCalendar.device(), []);
  if (error) return <ErrorText message={errorMessage(error)} />;
  if (loading || !events) return <Loading />;
  if (events.length === 0) return <EmptyState icon="flash" title="Aucune activité" message="Ce qui se passe dans le groupe apparaîtra ici." />;
  const now = Date.now();
  const names = directory?.shortNames ?? new Map<string, string>();
  const days: { title: string; events: ActivityEvent[] }[] = [];
  for (const event of events) {
    const title = activityDayTitle(event.createdAt, now, calendar);
    const last = days[days.length - 1];
    if (last && last.title === title) last.events.push(event);
    else days.push({ title, events: [event] });
  }
  return (
    <View style={{ gap: 12 }}>
      {days.map((day) => (
        <View key={day.title} style={{ gap: 8 }}>
          <Text style={[typo.headline, { color: theme.textSecondary }]}>{day.title}</Text>
          <Card padded={false}>
            {day.events.map((event, index) => {
              const member = directory?.members.find((item) => item.user.id === event.actorId);
              const time = calendar.components(event.createdAt);
              return (
                <View
                  key={event.id}
                  style={{
                    flexDirection: 'row',
                    gap: 12,
                    padding: 14,
                    alignItems: 'center',
                    borderTopWidth: index === 0 ? 0 : 1,
                    borderTopColor: theme.hairline,
                  }}
                >
                  {member ? <Avatar appearance={profileAppearance(member.user)} size={36} /> : <Avatar appearance={{ color: 'indigo', emoji: null, initials: '?' }} size={36} />}
                  <Text style={[typo.subheadline, { color: theme.textPrimary, flex: 1 }]}>
                    {activityText(event, userId, names).map((part, partIndex) => (
                      <Text key={partIndex} style={part.isEmphasized ? { fontWeight: '700' } : undefined}>
                        {part.text}
                      </Text>
                    ))}
                  </Text>
                  <Text style={[typo.footnote, { color: theme.textSecondary }]}>
                    {`${String(time.hour).padStart(2, '0')}:${String(time.minute).padStart(2, '0')}`}
                  </Text>
                </View>
              );
            })}
          </Card>
        </View>
      ))}
    </View>
  );
}
