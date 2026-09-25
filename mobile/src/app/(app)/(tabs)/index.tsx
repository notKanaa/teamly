import { Ionicons } from '@expo/vector-icons';
import { router } from 'expo-router';
import { Text, View } from 'react-native';

import { errorMessage } from '@/core/appError';
import { GROUPS_EMPTY_MESSAGE, GROUPS_EMPTY_TITLE, groupsHeaderText } from '@/core/groups';
import { useMyGroups, useOverviews } from '@/data/queries';
import { EmptyState, ErrorText, Loading, PrimaryButton, SecondaryButton } from '@/ui/components';
import { GroupCard, JoinGroupCard } from '@/ui/groupKit';
import { Screen } from '@/ui/Screen';
import { MenuButton } from '@/ui/sheet';
import { type as typo, useTheme } from '@/ui/theme';

const openCreate = () => router.push('/new-group');
const openJoin = () => router.push({ pathname: '/new-group', params: { mode: 'join' } });

/** « Groupes » (docs/DESIGN-V2.md §7.2, screenshot 02-groupes). */
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
      contentStyle={{ paddingHorizontal: 16 }}
    >
      <View style={{ alignItems: 'flex-end' }}>
        <MenuButton
          accessibilityLabel="Créer ou rejoindre un groupe"
          sections={[
            [
              { label: 'Créer un groupe', icon: 'add', onPress: openCreate },
              { label: 'Rejoindre un groupe', icon: 'key', onPress: openJoin },
            ],
          ]}
        >
          <View
            style={[
              {
                width: 50,
                height: 50,
                borderRadius: 25,
                backgroundColor: theme.card,
                alignItems: 'center',
                justifyContent: 'center',
              },
              theme.cardShadow,
            ]}
          >
            <Ionicons name="add" size={30} color={theme.accent} />
          </View>
        </MenuButton>
      </View>
      <View style={{ gap: 2, paddingHorizontal: 4, marginTop: -4 }}>
        <Text accessibilityRole="header" style={[typo.largeTitle, { color: theme.textPrimary }]}>
          Groupes
        </Text>
        {header ? <Text style={[typo.subheadline, { fontSize: 17, color: theme.textSecondary }]}>{header}</Text> : null}
      </View>

      {groups.isPending ? <Loading /> : null}
      {groups.error ? <ErrorText message={errorMessage(groups.error)} /> : null}

      {groups.isSuccess && list.length === 0 ? (
        <EmptyState icon="people" title={GROUPS_EMPTY_TITLE} message={GROUPS_EMPTY_MESSAGE}>
          <View style={{ alignSelf: 'stretch', marginTop: 10, gap: 4 }}>
            <PrimaryButton title="Créer un groupe" icon="add" onPress={openCreate} />
            <SecondaryButton title="Rejoindre avec un code" onPress={openJoin} />
          </View>
        </EmptyState>
      ) : null}

      {list.map((summary) => (
        <GroupCard
          key={summary.group.id}
          summary={summary}
          overview={overviews.data?.get(summary.group.id) ?? null}
          onPress={() => router.push(`/group/${summary.group.id}`)}
        />
      ))}

      {list.length > 0 ? <JoinGroupCard onPress={openJoin} /> : null}
    </Screen>
  );
}
