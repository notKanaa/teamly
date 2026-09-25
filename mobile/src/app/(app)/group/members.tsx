import { Ionicons } from '@expo/vector-icons';
import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState } from 'react';
import { ActivityIndicator, Alert, Platform, Share, Text, View } from 'react-native';

import { errorMessage } from '@/core/appError';
import { FrenchCalendar } from '@/core/calendar';
import { GROUP_GONE_MESSAGE } from '@/core/groups';
import {
  canChangeRole,
  canRemoveMember,
  INVITE_FOOTER,
  inviteShareText,
  isLastAdmin,
  isMe,
  leaveConfirmationMessage,
  leaveConfirmTitle,
  leaveFooter,
  memberDisplayName,
  memberSinceText,
  membersSectionTitle,
  REGENERATE_MESSAGE,
  REGENERATE_TITLE,
  removeMemberMessage,
  roleActionTitle,
  SELF_DEMOTION_MESSAGE,
  SELF_DEMOTION_TITLE,
  type MembersState,
} from '@/core/groupScreens';
import { formatInviteCode } from '@/core/inviteCode';
import type { Membership } from '@/core/models';
import { GroupPermissions } from '@/core/permissions';
import { profileAppearance } from '@/core/presentation';
import { groups } from '@/data/api';
import { groupKeys, useInviteCode } from '@/data/groupQueries';
import { keys, useMembers, useMyGroups } from '@/data/queries';
import { useUserId } from '@/data/session';
import { Avatar, EmptyState, ErrorText, Loading } from '@/ui/components';
import { CardFooter, extraTokens, InsetCard, InsetRow, RoleChip, SmallSectionTitle } from '@/ui/groupKit';
import { Screen } from '@/ui/Screen';
import { CircleButton, MenuButton } from '@/ui/sheet';
import { type as typo, useTheme } from '@/ui/theme';

const MONOSPACE = Platform.select({ ios: 'Menlo', android: 'monospace', default: 'monospace' });

/** « Membres » (screenshot 08-membres): the invite code for admins, the members and their roles, « Quitter le groupe ». */
export default function MembersScreen() {
  const { groupId = '' } = useLocalSearchParams<{ groupId: string }>();
  const theme = useTheme();
  const extra = extraTokens(theme);
  const client = useQueryClient();
  const userId = useUserId();
  const myGroups = useMyGroups();
  const summary = myGroups.data?.find((item) => item.group.id === groupId) ?? null;
  const role = summary?.myRole ?? null;
  const members = useMembers(groupId);
  const isAdmin = GroupPermissions.canSeeInviteCode(role);
  const code = useInviteCode(groupId, isAdmin);
  const calendar = useMemo(() => FrenchCalendar.device(), []);
  const [busy, setBusy] = useState<ReadonlySet<string>>(new Set());
  const [regenerating, setRegenerating] = useState(false);
  const [leaving, setLeaving] = useState(false);

  const header = (
    <>
      <View style={{ alignItems: 'flex-start' }}>
        <CircleButton icon="chevron-back" label="Retour" onPress={() => router.back()} size={50} />
      </View>
      <Text accessibilityRole="header" style={[typo.largeTitle, { color: theme.textPrimary, paddingHorizontal: 4 }]}>
        Membres
      </Text>
    </>
  );

  if (myGroups.isSuccess && summary === null) {
    return (
      <Screen>
        {header}
        <EmptyState icon="people-outline" title="Groupe indisponible" message={GROUP_GONE_MESSAGE} />
      </Screen>
    );
  }
  if (!summary || !members.data) {
    return (
      <Screen>
        {header}
        {members.error ? <ErrorText message={errorMessage(members.error)} /> : <Loading />}
      </Screen>
    );
  }

  const groupName = summary.group.name;
  const list = members.data;
  const state: MembersState = { members: list, userId, myRole: role };
  const refresh = () => {
    void client.invalidateQueries({ queryKey: keys.members(groupId) });
    void client.invalidateQueries({ queryKey: keys.groups });
    void client.invalidateQueries({ queryKey: ['overviews'] });
  };

  const run = (member: Membership, title: string, action: () => Promise<void>) => {
    setBusy((current) => new Set(current).add(member.user.id));
    action()
      .then(refresh)
      .catch((caught: unknown) => Alert.alert(title, errorMessage(caught) ?? ''))
      .finally(() =>
        setBusy((current) => {
          const next = new Set(current);
          next.delete(member.user.id);
          return next;
        }),
      );
  };

  const changeRole = (member: Membership) => {
    const title = roleActionTitle(member);
    const nextRole = member.role === 'admin' ? 'member' : 'admin';
    const apply = () => run(member, title, () => groups.setRole(groupId, member.user.id, nextRole));
    if (isMe(state, member) && member.role === 'admin') {
      Alert.alert(SELF_DEMOTION_TITLE, SELF_DEMOTION_MESSAGE, [
        { text: 'Annuler', style: 'cancel' },
        { text: 'Retirer mon rôle d’admin', style: 'destructive', onPress: apply },
      ]);
    } else {
      apply();
    }
  };

  const remove = (member: Membership) => {
    Alert.alert('Retirer ce membre\u{a0}?', removeMemberMessage(member, groupName), [
      { text: 'Annuler', style: 'cancel' },
      {
        text: `Retirer ${member.user.displayName}`,
        style: 'destructive',
        onPress: () => run(member, 'Retirer du groupe', () => groups.removeMember(groupId, member.user.id)),
      },
    ]);
  };

  const regenerate = () => {
    Alert.alert(REGENERATE_TITLE, REGENERATE_MESSAGE, [
      { text: 'Annuler', style: 'cancel' },
      {
        text: 'Générer un nouveau code',
        style: 'destructive',
        onPress: () => {
          setRegenerating(true);
          groups
            .regenerateInviteCode(groupId)
            .then((next) => client.setQueryData(groupKeys.inviteCode(groupId), next))
            .catch((caught: unknown) => Alert.alert('Code d’invitation', errorMessage(caught) ?? ''))
            .finally(() => setRegenerating(false));
        },
      },
    ]);
  };

  const leave = () => {
    if (isLastAdmin(state)) return;
    Alert.alert('Quitter le groupe\u{a0}?', leaveConfirmationMessage(state, groupName), [
      { text: 'Annuler', style: 'cancel' },
      {
        text: leaveConfirmTitle(state),
        style: 'destructive',
        onPress: () => {
          setLeaving(true);
          groups
            .leave(groupId)
            .then(() => {
              refresh();
              void client.invalidateQueries({ queryKey: keys.myTasks });
              router.dismissAll();
            })
            .catch((caught: unknown) => Alert.alert('Quitter le groupe', errorMessage(caught) ?? ''))
            .finally(() => setLeaving(false));
        },
      },
    ]);
  };

  const blocked = isLastAdmin(state);
  const footer = leaveFooter(state, groupName);

  return (
    <Screen refreshing={members.isRefetching} onRefresh={() => void members.refetch()} contentStyle={{ gap: 12 }}>
      {header}

      {isAdmin ? (
        <>
          <SmallSectionTitle style={{ paddingHorizontal: 18, marginTop: 6 }}>Inviter</SmallSectionTitle>
          <InsetCard>
            <InsetRow
              first
              icon="qr-code-outline"
              soft={theme.accentSoft}
              title="Code d’invitation"
              trailing={
                code.data ? (
                  <Text
                    selectable
                    accessibilityLabel={formatInviteCode(code.data).split('').join(' ')}
                    style={{ fontFamily: MONOSPACE, fontWeight: '700', fontSize: 20, color: theme.accent }}
                  >
                    {formatInviteCode(code.data)}
                  </Text>
                ) : code.error ? (
                  <Text style={{ color: theme.textSecondary }}>—</Text>
                ) : (
                  <ActivityIndicator color={theme.accent} />
                )
              }
            />
            <InsetRow
              icon="share-outline"
              soft={theme.soft.blue}
              title="Partager le code"
              disabled={!code.data}
              onPress={() => {
                if (code.data) void Share.share({ message: inviteShareText(groupName, code.data), title: 'Invitation dans Équipe' });
              }}
            />
            <InsetRow
              icon="sync"
              soft={theme.soft.orange}
              title="Générer un nouveau code"
              disabled={regenerating}
              onPress={regenerate}
              trailing={regenerating ? <ActivityIndicator color={theme.accent} /> : null}
            />
          </InsetCard>
          <CardFooter>{INVITE_FOOTER}</CardFooter>
          {code.error ? <ErrorText message={errorMessage(code.error)} /> : null}
        </>
      ) : null}

      <SmallSectionTitle style={{ paddingHorizontal: 18, marginTop: 10 }}>{membersSectionTitle(groupName, list.length)}</SmallSectionTitle>
      <InsetCard>
        {list.map((member, index) => {
          const me = isMe(state, member);
          const actions = [
            ...(canChangeRole(state, member)
              ? [{ label: roleActionTitle(member), icon: member.role === 'admin' ? ('star-outline' as const) : ('star' as const), onPress: () => changeRole(member) }]
              : []),
            ...(canRemoveMember(state, member)
              ? [{ label: 'Retirer du groupe', icon: 'person-remove-outline' as const, destructive: true, onPress: () => remove(member) }]
              : []),
          ];
          return (
            <View key={member.user.id}>
              {index > 0 ? <View style={{ height: 1, marginLeft: 60, backgroundColor: theme.dark ? theme.hairline : '#E6E4EE' }} /> : null}
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 14, paddingRight: actions.length ? 6 : 16 }}>
                <Avatar appearance={profileAppearance(member.user)} size={44} />
                <View style={{ flex: 1, gap: 2 }}>
                  <Text numberOfLines={1} style={[typo.body, { fontSize: 18, fontWeight: me ? '700' : '600', color: theme.textPrimary }]}>
                    {memberDisplayName(state, member)}
                  </Text>
                  <Text numberOfLines={2} style={[typo.footnote, { fontSize: 15, color: theme.textSecondary }]}>
                    {memberSinceText(member.joinedAt, Date.now(), calendar)}
                  </Text>
                </View>
                {busy.has(member.user.id) ? <ActivityIndicator color={theme.accent} accessibilityLabel="Mise à jour" /> : <RoleChip role={member.role} />}
                {actions.length > 0 ? (
                  <MenuButton accessibilityLabel={`Actions pour ${member.user.displayName}`} sections={[actions]} disabled={busy.has(member.user.id)}>
                    <View style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center' }}>
                      <Ionicons name="ellipsis-horizontal-circle-outline" size={28} color={theme.accent} />
                    </View>
                  </MenuButton>
                ) : null}
              </View>
            </View>
          );
        })}
      </InsetCard>

      <InsetCard style={{ marginTop: 22 }}>
        <InsetRow
          first
          icon="log-out-outline"
          soft={blocked ? extra.neutral : theme.danger}
          title="Quitter le groupe"
          titleColor={blocked ? theme.textSecondary : theme.danger.text}
          disabled={blocked || leaving}
          onPress={leave}
          trailing={leaving ? <ActivityIndicator color={theme.accent} /> : null}
        />
      </InsetCard>
      {footer ? <CardFooter>{footer}</CardFooter> : null}
    </Screen>
  );
}
