import { Ionicons } from '@expo/vector-icons';
import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState } from 'react';
import { Alert, Pressable, RefreshControl, ScrollView, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { RECAP_EMPTY_MESSAGE, RECAP_TITLE, recapRange, recapTotalLabel } from '@/core/activityText';
import { errorMessage } from '@/core/appError';
import { FrenchCalendar } from '@/core/calendar';
import { GROUP_NAME_MAX } from '@/core/forms';
import {
  deleteGroupConfirmationMessage,
  GROUP_EMPTY_MESSAGE,
  GROUP_GONE_MESSAGE,
  GROUP_NO_MATCH_MESSAGE,
  groupFilterChips,
  groupTabLabel,
  groupTaskRows,
  membersSummary,
  TURN_CARDS_TITLE,
  turnCards,
  turnCardsSubtitle,
  type GroupContext,
  type GroupTab,
} from '@/core/groups';
import {
  ACTIVITY_EMPTY_MESSAGE,
  ACTIVITY_EMPTY_TITLE,
  ACTIVITY_FEED_TITLE,
  activityFeedSections,
  isLastAdmin,
  leaveConfirmationMessage,
  leaveConfirmTitle,
  podiumEntries,
  podiumStageOrder,
  recapStreakText,
  renameGroupMessage,
} from '@/core/groupScreens';
import type { GroupSummary, Membership } from '@/core/models';
import { GroupPermissions, canCreateTask } from '@/core/permissions';
import { groupAppearance, MemberDirectory, nextStatus, togglingFilterChip, type AvatarAppearance } from '@/core/presentation';
import { activeCriteriaCount, ALL_TASKS_FILTER, type TaskFilter } from '@/core/taskList';
import type { Uuid } from '@/core/uuid';
import { computeWeeklyRecap } from '@/core/weeklyRecap';
import { groups, tasks } from '@/data/api';
import { useCompletions } from '@/data/groupQueries';
import { keys, useActivity, useGroupTasks, useMembers, useMyGroups, useTaskMutation } from '@/data/queries';
import { useUserId } from '@/data/session';
import {
  AvatarStack,
  EmptyState,
  ErrorText,
  FloatingAddButton,
  Loading,
  PrimaryButton,
  SecondaryButton,
  SegmentedPill,
  TaskRowCard,
} from '@/ui/components';
import {
  ActivityRowView,
  colorAccent,
  Emphasized,
  FilterChipButton,
  HeroTile,
  IconTile,
  LargeSectionTitle,
  Podium,
  SmallSectionTitle,
  TurnCardView,
} from '@/ui/groupKit';
import { CircleButton, MenuButton, PromptModal, type MenuSection } from '@/ui/sheet';
import { fonts, radius, spacing, type as typo, useTheme } from '@/ui/theme';

/** The group screen (docs/DESIGN-V2.md §7.4–§7.5, screenshots 06-detail-groupe, 15-groupe-vitrine, 16-groupe-activite). */
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
  const [identityHeight, setIdentityHeight] = useState(0);
  const [collapsed, setCollapsed] = useState(false);
  const [renaming, setRenaming] = useState(false);
  const statusMutation = useTaskMutation((args: { id: string; status: 'todo' | 'in_progress' | 'done' }) =>
    tasks.setStatus(args.id, args.status),
  );
  const calendar = useMemo(() => FrenchCalendar.device(), []);

  if (myGroups.isSuccess && summary === null) {
    return (
      <View style={{ flex: 1, backgroundColor: theme.background, paddingTop: insets.top + 6, paddingHorizontal: spacing.page }}>
        <CircleButton icon="chevron-back" label="Retour" onPress={() => router.back()} />
        <EmptyState icon="people-outline" title="Groupe indisponible" message={GROUP_GONE_MESSAGE} />
      </View>
    );
  }
  if (summary === null) return <Loading />;

  const group = summary.group;
  const appearance = groupAppearance(group);
  const fill = theme.fill[appearance.color];
  const role = summary.myRole;
  const now = Date.now();
  const context: GroupContext | null =
    groupTasks.data && members.data ? { tasks: groupTasks.data, members: members.data, myRole: role, userId, now, calendar } : null;
  const isActivity = tab === 'activity';

  const leaveGroups = () => {
    void client.invalidateQueries({ queryKey: keys.groups });
    void client.invalidateQueries({ queryKey: ['overviews'] });
    void client.invalidateQueries({ queryKey: keys.myTasks });
    router.back();
  };

  const confirmLeave = () => {
    const state = { members: members.data ?? [], userId, myRole: role };
    if (isLastAdmin(state)) {
      Alert.alert('Quitter le groupe', leaveConfirmationMessage(state, group.name));
      return;
    }
    Alert.alert('Quitter le groupe\u{a0}?', leaveConfirmationMessage(state, group.name), [
      { text: 'Annuler', style: 'cancel' },
      {
        text: leaveConfirmTitle(state),
        style: 'destructive',
        onPress: () => {
          groups
            .leave(groupId)
            .then(leaveGroups)
            .catch((caught: unknown) => Alert.alert('Quitter le groupe', errorMessage(caught) ?? ''));
        },
      },
    ]);
  };

  const confirmDelete = () => {
    Alert.alert('Supprimer le groupe\u{a0}?', deleteGroupConfirmationMessage(group.name), [
      { text: 'Annuler', style: 'cancel' },
      {
        text: 'Supprimer le groupe',
        style: 'destructive',
        onPress: () => {
          groups
            .delete(groupId)
            .then(leaveGroups)
            .catch((caught: unknown) => Alert.alert('Supprimer le groupe', errorMessage(caught) ?? ''));
        },
      },
    ]);
  };

  const rename = (name: string) => {
    setRenaming(false);
    groups
      .rename(groupId, name)
      .then((renamed) => {
        client.setQueryData<GroupSummary[]>(keys.groups, (list) =>
          list?.map((item) => (item.group.id === groupId ? { ...item, group: renamed } : item)),
        );
        void client.invalidateQueries({ queryKey: keys.groups });
        void client.invalidateQueries({ queryKey: keys.myTasks });
      })
      .catch((caught: unknown) => Alert.alert('Renommer le groupe', errorMessage(caught) ?? ''));
  };

  const openMembers = () => router.push({ pathname: '/group/members', params: { groupId } });
  const openInvite = () => router.push({ pathname: '/group/invite', params: { groupId } });
  const isAdmin = GroupPermissions.canSeeInviteCode(role);

  const menu: MenuSection[] = [
    activeCriteriaCount(filter) > 0
      ? [{ label: 'Réinitialiser les filtres', icon: 'funnel-outline', onPress: () => setFilter(ALL_TASKS_FILTER) }]
      : [],
    [
      { label: 'Membres', icon: 'people-outline', onPress: openMembers },
      ...(isAdmin ? [{ label: 'Code d’invitation', icon: 'qr-code-outline' as const, onPress: openInvite }] : []),
      ...(GroupPermissions.canSetAppearance(role)
        ? [{ label: 'Apparence', icon: 'color-palette-outline' as const, onPress: () => router.push({ pathname: '/group/appearance', params: { groupId } }) }]
        : []),
      ...(GroupPermissions.canRename(role) ? [{ label: 'Renommer le groupe', icon: 'pencil' as const, onPress: () => setRenaming(true) }] : []),
    ],
    [{ label: 'Quitter le groupe', icon: 'log-out-outline', destructive: true, onPress: confirmLeave }],
    GroupPermissions.canDelete(role) ? [{ label: 'Supprimer le groupe', icon: 'trash-outline', destructive: true, onPress: confirmDelete }] : [],
  ];

  const showsInlineTitle = isActivity || collapsed;
  const refreshing = groupTasks.isRefetching || members.isRefetching;

  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      {/* The pinned bar: back, « Inviter », « … » (the tile and the name on « Activité » or once scrolled). */}
      <View
        style={{
          zIndex: 2,
          backgroundColor: fill,
          paddingTop: insets.top + 6,
          paddingHorizontal: spacing.page,
          paddingBottom: isActivity ? 18 : 6,
          borderBottomLeftRadius: isActivity ? 28 : 0,
          borderBottomRightRadius: isActivity ? 28 : 0,
          flexDirection: 'row',
          alignItems: 'center',
          gap: 10,
        }}
      >
        <CircleButton icon="chevron-back" label="Retour" variant="translucent" onPress={() => router.back()} />
        {showsInlineTitle ? (
          <>
            <HeroTile appearance={appearance} size={40} />
            <Text
              accessibilityRole="header"
              numberOfLines={isActivity ? 2 : 1}
              style={{ flex: 1, fontFamily: fonts.heavy, fontSize: 22, lineHeight: 27, color: '#FFF' }}
            >
              {group.name}
            </Text>
          </>
        ) : (
          <>
            <View style={{ flex: 1 }} />
            {isAdmin ? <InviteButton color={fill} onPress={openInvite} /> : null}
          </>
        )}
        <MenuButton accessibilityLabel="Options du groupe" sections={menu}>
          <View style={{ width: 44, height: 44, borderRadius: 22, backgroundColor: 'rgba(255,255,255,0.22)', alignItems: 'center', justifyContent: 'center' }}>
            <Ionicons name="ellipsis-horizontal" size={22} color="#FFF" />
          </View>
        </MenuButton>
      </View>

      <ScrollView
        scrollEventThrottle={32}
        onScroll={(event) => {
          const next = !isActivity && identityHeight > 0 && event.nativeEvent.contentOffset.y > identityHeight * 0.7;
          if (next !== collapsed) setCollapsed(next);
        }}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            tintColor={isActivity ? theme.accent : '#FFF'}
            onRefresh={() => {
              void groupTasks.refetch();
              void members.refetch();
              void myGroups.refetch();
              if (isActivity) void client.invalidateQueries({ queryKey: keys.activity(groupId) });
              if (isActivity) void client.invalidateQueries({ queryKey: keys.completions(groupId) });
            }}
          />
        }
        contentContainerStyle={{ paddingBottom: insets.bottom + 110 }}
      >
        {!isActivity ? (
          <View onLayout={(event) => setIdentityHeight(event.nativeEvent.layout.height)}>
            <View style={{ position: 'absolute', left: 0, right: 0, top: -800, height: 800, backgroundColor: fill }} />
            <View
              style={{
                backgroundColor: fill,
                paddingHorizontal: spacing.page,
                paddingTop: 4,
                paddingBottom: 22,
                borderBottomLeftRadius: 32,
                borderBottomRightRadius: 32,
                flexDirection: 'row',
                alignItems: 'center',
                gap: 14,
              }}
            >
              <HeroTile appearance={appearance} size={64} />
              <View style={{ flex: 1, gap: 6 }}>
                <Text accessibilityRole="header" style={{ fontFamily: fonts.heavy, fontSize: 26, lineHeight: 32, color: '#FFF' }}>
                  {group.name}
                </Text>
                <MembersLink
                  members={members.data ?? null}
                  userId={userId}
                  text={membersSummary(members.data?.length ?? 0, role)}
                  onPress={openMembers}
                />
              </View>
            </View>
          </View>
        ) : null}

        <View style={{ paddingHorizontal: spacing.page, paddingTop: 16, gap: 18 }}>
          <SegmentedPill
            options={(['tasks', 'activity'] as const).map((key) => ({ key, label: groupTabLabel(key) }))}
            value={tab}
            onChange={(next) => {
              setTab(next);
              setCollapsed(false);
            }}
          />
          {tab === 'tasks' ? (
            <TasksTab
              groupId={groupId}
              context={context}
              error={members.error ?? groupTasks.error}
              color={appearance.color}
              filter={filter}
              setFilter={setFilter}
              canCreate={canCreateTask(role)}
              onToggle={(id, status) => statusMutation.mutate({ id, status: nextStatus(status) })}
              mutationError={statusMutation.error}
            />
          ) : (
            <ActivityTab groupId={groupId} members={members.data ?? null} userId={userId} openable={new Set((groupTasks.data ?? []).map((task) => task.id))} />
          )}
        </View>
      </ScrollView>

      {tab === 'tasks' && canCreateTask(role) ? (
        <FloatingAddButton
          label="Nouvelle tâche"
          bottom={insets.bottom + 20}
          onPress={() => router.push({ pathname: '/new-task', params: { groupId } })}
        />
      ) : null}

      <PromptModal
        visible={renaming}
        title="Renommer le groupe"
        message={renameGroupMessage()}
        initialValue={group.name}
        placeholder="Nom du groupe"
        confirmTitle="Renommer"
        maxLength={GROUP_NAME_MAX + 20}
        onCancel={() => setRenaming(false)}
        onConfirm={rename}
      />
    </View>
  );
}

/** « Inviter »: a white capsule, its text in the group's fill. */
function InviteButton({ color, onPress }: { color: string; onPress: () => void }) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel="Inviter avec un code"
      onPress={onPress}
      style={({ pressed }) => ({
        minHeight: 44,
        paddingHorizontal: 16,
        borderRadius: 999,
        backgroundColor: '#FFF',
        flexDirection: 'row',
        alignItems: 'center',
        gap: 6,
        opacity: pressed ? 0.8 : 1,
      })}
    >
      <Ionicons name="person-add-outline" size={18} color={color} />
      <Text style={{ fontFamily: fonts.heavy, fontSize: 16, color }}>Inviter</Text>
    </Pressable>
  );
}

/** The members' avatars (ringed in white) and « 3 membres · Tu es admin › »: opens « Membres ». */
function MembersLink({
  members,
  userId,
  text,
  onPress,
}: {
  members: readonly Membership[] | null;
  userId: Uuid;
  text: string;
  onPress: () => void;
}) {
  const badges = members ? new MemberDirectory(members, userId).memberBadges : [];
  const shown = badges.length <= 3 ? badges : badges.slice(0, 2);
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`Membres, ${text}`}
      accessibilityHint="Affiche les membres du groupe"
      onPress={onPress}
      style={({ pressed }) => ({ flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 44, flexWrap: 'wrap', opacity: pressed ? 0.8 : 1 })}
    >
      {shown.length > 0 ? (
        <AvatarStack
          avatars={shown.map((badge) => badge.appearance)}
          more={badges.length > 3 ? `+${badges.length - 2}` : null}
          size={26}
          ringColor="#FFFFFF"
        />
      ) : null}
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, flexShrink: 1 }}>
        <Text style={[typo.subheadline, { fontSize: 16, fontWeight: '600', color: '#FFF', flexShrink: 1 }]}>{text}</Text>
        <Ionicons name="chevron-forward" size={14} color="rgba(255,255,255,0.85)" />
      </View>
    </Pressable>
  );
}

function TasksTab({
  groupId,
  context,
  error,
  color,
  filter,
  setFilter,
  canCreate,
  onToggle,
  mutationError,
}: {
  groupId: Uuid;
  context: GroupContext | null;
  error: unknown;
  color: AvatarAppearance['color'];
  filter: TaskFilter;
  setFilter: (filter: TaskFilter) => void;
  canCreate: boolean;
  onToggle: (id: string, status: 'todo' | 'in_progress' | 'done') => void;
  mutationError: unknown;
}) {
  if (error) return <ErrorText message={errorMessage(error)} />;
  if (!context) return <Loading />;
  const cards = turnCards(context);
  const chips = groupFilterChips(context, filter);
  const rows = groupTaskRows(context, filter);
  const openRows = rows.filter((row) => !row.isDone);
  const doneRows = rows.filter((row) => row.isDone);
  const hasNoTask = context.tasks.length === 0;
  const renderRow = (row: (typeof rows)[number]) => (
    <TaskRowCard
      key={row.id}
      row={row}
      color={color}
      onPress={() => router.push(`/task/${row.id}`)}
      onToggleStatus={() => onToggle(row.id, row.status)}
    />
  );
  return (
    <>
      {cards.length > 0 ? (
        <View style={{ gap: 12 }}>
          <LargeSectionTitle title={TURN_CARDS_TITLE} trailing={turnCardsSubtitle(cards)} />
          <ScrollView
            horizontal
            showsHorizontalScrollIndicator={false}
            style={{ marginHorizontal: -spacing.page, overflow: 'visible' }}
            contentContainerStyle={{ gap: 12, paddingHorizontal: spacing.page, paddingVertical: 4, alignItems: 'stretch' }}
          >
            {cards.map((card) => (
              <TurnCardView key={card.id} card={card} groupColor={color} onPress={() => router.push(`/task/${card.id}`)} />
            ))}
          </ScrollView>
        </View>
      ) : null}
      {!hasNoTask ? (
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          style={{ marginHorizontal: -spacing.page }}
          contentContainerStyle={{ gap: 8, paddingHorizontal: spacing.page }}
        >
          {chips.map((chip) => (
            <FilterChipButton
              key={chip.id}
              label={chip.countedLabel}
              selected={chip.isSelected}
              onPress={() => setFilter(togglingFilterChip(chip.kind, filter))}
            />
          ))}
        </ScrollView>
      ) : null}
      {rows.length === 0 ? (
        <EmptyState
          icon={hasNoTask ? 'list' : 'funnel-outline'}
          title={hasNoTask ? 'Aucune tâche' : 'Aucun résultat'}
          message={hasNoTask ? GROUP_EMPTY_MESSAGE : GROUP_NO_MATCH_MESSAGE}
        >
          {hasNoTask && canCreate ? (
            <PrimaryButton
              title="Nouvelle tâche"
              icon="add"
              onPress={() => router.push({ pathname: '/new-task', params: { groupId } })}
              style={{ alignSelf: 'stretch', marginTop: 10 }}
            />
          ) : null}
          {!hasNoTask && activeCriteriaCount(filter) > 0 ? (
            <SecondaryButton title="Réinitialiser les filtres" onPress={() => setFilter(ALL_TASKS_FILTER)} />
          ) : null}
        </EmptyState>
      ) : (
        <View style={{ gap: 10 }}>
          {openRows.map(renderRow)}
          {openRows.length > 0 && doneRows.length > 0 ? <SmallSectionTitle style={{ marginTop: 10 }}>Terminées</SmallSectionTitle> : null}
          {doneRows.map(renderRow)}
        </View>
      )}
      {mutationError ? <ErrorText message={errorMessage(mutationError)} /> : null}
    </>
  );
}

function ActivityTab({
  groupId,
  members,
  userId,
  openable,
}: {
  groupId: Uuid;
  members: readonly Membership[] | null;
  userId: Uuid;
  openable: ReadonlySet<Uuid>;
}) {
  const theme = useTheme();
  const calendar = useMemo(() => FrenchCalendar.device(), []);
  const activity = useActivity(groupId);
  const completions = useCompletions(groupId);
  const error = activity.error ?? completions.error;
  if (error) return <ErrorText message={errorMessage(error)} />;
  if (!activity.data || !completions.data || !members) return <Loading />;

  const now = Date.now();
  const recap = computeWeeklyRecap(completions.data, members, now, calendar);
  const podium = podiumStageOrder(podiumEntries(recap, members, userId));
  const streak = recapStreakText(recap, members, userId);
  const sections = activityFeedSections(activity.data, members, userId, now, calendar);

  return (
    <>
      <View style={[{ backgroundColor: theme.card, borderRadius: radius.card, padding: 18, gap: 16 }, theme.cardShadow]}>
        <View style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 12 }}>
          <View style={{ flex: 1, gap: 2 }}>
            <Text accessibilityRole="header" style={[typo.title, { color: theme.textPrimary }]}>
              {RECAP_TITLE}
            </Text>
            <Text style={[typo.subheadline, { fontSize: 17, lineHeight: 22, color: theme.textSecondary }]}>
              {recapRange(recap.weekStart, recap.weekEnd, calendar)}
            </Text>
          </View>
          <View accessible style={{ alignItems: 'flex-end' }}>
            <Text style={{ fontFamily: fonts.heavy, fontSize: 40, lineHeight: 46, color: theme.accent, fontVariant: ['tabular-nums'] }}>
              {recap.total}
            </Text>
            <Text style={[typo.footnote, { fontSize: 15, color: theme.textSecondary }]}>{recapTotalLabel(recap.total)}</Text>
          </View>
        </View>
        {recap.total === 0 ? (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
            <IconTile icon="trophy" soft={theme.soft.amber} size={36} />
            <Text style={[typo.subheadline, { flex: 1, color: theme.textSecondary }]}>{RECAP_EMPTY_MESSAGE}</Text>
          </View>
        ) : (
          <Podium entries={podium} />
        )}
        {streak ? (
          <View
            accessible
            style={{
              flexDirection: 'row',
              alignItems: 'center',
              gap: 10,
              paddingHorizontal: 14,
              paddingVertical: 10,
              borderRadius: 14,
              backgroundColor: theme.soft.amber.bg,
            }}
          >
            <Ionicons name="flame" size={20} color={colorAccent(theme, 'orange')} />
            <Emphasized text={streak} style={[typo.subheadline, { flex: 1, fontSize: 16, color: theme.textPrimary }]} />
          </View>
        ) : null}
      </View>

      <View style={{ marginTop: 4 }}>
        <LargeSectionTitle title={ACTIVITY_FEED_TITLE} />
      </View>
      {sections.length === 0 ? (
        <View style={[{ backgroundColor: theme.card, borderRadius: radius.card }, theme.cardShadow]}>
          <EmptyState icon="flash-outline" title={ACTIVITY_EMPTY_TITLE} message={ACTIVITY_EMPTY_MESSAGE} />
        </View>
      ) : (
        sections.map((section) => (
          <View key={section.title} style={{ gap: 8 }}>
            <SmallSectionTitle style={{ paddingHorizontal: 4 }}>{section.title}</SmallSectionTitle>
            <View style={[{ backgroundColor: theme.card, borderRadius: radius.card, paddingHorizontal: 16, paddingVertical: 4 }, theme.cardShadow]}>
              {section.rows.map((row, index) => {
                const taskId = row.event.taskId;
                return (
                  <View key={row.event.id} style={index > 0 ? { borderTopWidth: 1, borderTopColor: theme.hairline } : undefined}>
                    <ActivityRowView
                      row={row}
                      onPress={taskId && openable.has(taskId) ? () => router.push(`/task/${taskId}`) : undefined}
                    />
                  </View>
                );
              })}
            </View>
          </View>
        ))
      )}
    </>
  );
}
