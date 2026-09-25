import { Ionicons } from '@expo/vector-icons';
import { router } from 'expo-router';
import { Pressable, Text, View } from 'react-native';

import { errorMessage } from '@/core/appError';
import { GROUPS_EMPTY_MESSAGE, GROUPS_EMPTY_TITLE, groupsHeaderText } from '@/core/groups';
import type { GroupSummary } from '@/core/models';
import {
  groupAppearance,
  OVERVIEW_WEEK_TITLE,
  overviewMemberAvatars,
  overviewMoreMembersText,
  overviewSummaryText,
  overviewWeekProgress,
  overviewWeekProgressText,
  type GroupOverview,
} from '@/core/presentation';
import { useMyGroups, useOverviews } from '@/data/queries';
import { AvatarStack, Card, EmptyState, ErrorText, GroupTile, Loading, PrimaryButton, ProgressBar } from '@/ui/components';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

/** « Groupes » (screenshot 03-groupes). */
export default function GroupsScreen() {
  const theme = useTheme();
  const groups = useMyGroups();
  const overviews = useOverviews(groups.data);
  const list = groups.data ?? [];
  const header = groupsHeaderText(list, overviews.data ?? null);

  return (
    <Screen
      refreshing={groups.isRefetching}
      onRefresh={() => {
        void groups.refetch();
        void overviews.refetch();
      }}
    >
      <View style={{ flexDirection: 'row', alignItems: 'flex-end', justifyContent: 'space-between' }}>
        <View style={{ flex: 1 }}>
          <Text style={[typo.largeTitle, { color: theme.textPrimary }]}>Groupes</Text>
          {header ? <Text style={[typo.subheadline, { color: theme.textSecondary }]}>{header}</Text> : null}
        </View>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Créer ou rejoindre un groupe"
          onPress={() => router.push('/new-group')}
          style={{
            width: 44,
            height: 44,
            borderRadius: 22,
            backgroundColor: theme.accentFill,
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <Ionicons name="add" size={26} color="#FFF" />
        </Pressable>
      </View>

      {groups.isPending ? <Loading /> : null}
      {groups.error ? <ErrorText message={errorMessage(groups.error)} /> : null}

      {groups.isSuccess && list.length === 0 ? (
        <EmptyState icon="people" title={GROUPS_EMPTY_TITLE} message={GROUPS_EMPTY_MESSAGE}>
          <PrimaryButton title="Créer un groupe" onPress={() => router.push('/new-group')} style={{ alignSelf: 'stretch', marginTop: 10 }} />
        </EmptyState>
      ) : null}

      {list.map((summary) => (
        <GroupCard key={summary.group.id} summary={summary} overview={overviews.data?.get(summary.group.id) ?? null} />
      ))}

      {list.length > 0 ? (
        <Pressable
          onPress={() => router.push({ pathname: '/new-group', params: { mode: 'join' } })}
          style={{
            borderRadius: 22,
            borderWidth: 2,
            borderStyle: 'dashed',
            borderColor: theme.track,
            minHeight: 64,
            flexDirection: 'row',
            alignItems: 'center',
            justifyContent: 'center',
            gap: 8,
          }}
        >
          <Ionicons name="key" size={18} color={theme.accent} />
          <Text style={{ fontFamily: 'Nunito_800ExtraBold', fontSize: 16, color: theme.accent }}>Rejoindre un groupe</Text>
        </Pressable>
      ) : null}
    </Screen>
  );
}

function GroupCard({ summary, overview }: { summary: GroupSummary; overview: GroupOverview | null }) {
  const theme = useTheme();
  const appearance = groupAppearance(summary.group);
  return (
    <Pressable onPress={() => router.push(`/group/${summary.group.id}`)} style={({ pressed }) => ({ opacity: pressed ? 0.9 : 1 })}>
      <Card style={{ gap: 14 }}>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
          <GroupTile appearance={appearance} />
          <View style={{ flex: 1, gap: 2 }}>
            <Text style={[typo.title3, { color: theme.textPrimary }]} numberOfLines={2}>
              {summary.group.name}
            </Text>
            {overview ? (
              <Text style={[typo.subheadline, { color: theme.textSecondary }]}>{overviewSummaryText(overview)}</Text>
            ) : null}
          </View>
          {overview ? <AvatarStack avatars={overviewMemberAvatars(overview)} more={overviewMoreMembersText(overview)} /> : null}
        </View>
        {overview ? (
          <View style={{ gap: 6 }}>
            <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
              <Text style={[typo.footnote, { color: theme.textSecondary, fontWeight: '600' }]}>{OVERVIEW_WEEK_TITLE}</Text>
              <Text style={[typo.footnote, { color: theme.textSecondary }]}>{overviewWeekProgressText(overview)}</Text>
            </View>
            <ProgressBar fraction={overviewWeekProgress(overview)} color={theme.fill[appearance.color]} />
          </View>
        ) : null}
      </Card>
    </Pressable>
  );
}
