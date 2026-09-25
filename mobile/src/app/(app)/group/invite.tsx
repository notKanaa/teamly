import { Ionicons } from '@expo/vector-icons';
import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { ActivityIndicator, Alert, Platform, Pressable, ScrollView, Share, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { errorMessage } from '@/core/appError';
import { GROUP_GONE_MESSAGE } from '@/core/groups';
import {
  INVITE_ADMINS_ONLY_MESSAGE,
  INVITE_ADMINS_ONLY_TITLE,
  INVITE_VALIDITY_TEXT,
  inviteExplanation,
  inviteShareText,
  REGENERATE_MESSAGE,
  REGENERATE_TITLE,
} from '@/core/groupScreens';
import { formatInviteCode } from '@/core/inviteCode';
import { GroupPermissions } from '@/core/permissions';
import { groupAppearance } from '@/core/presentation';
import { groups } from '@/data/api';
import { groupKeys, useInviteCode } from '@/data/groupQueries';
import { useMyGroups } from '@/data/queries';
import { EmptyState, ErrorText, GroupTile, Loading, PrimaryButton } from '@/ui/components';
import { CapsuleButton, SheetHeader } from '@/ui/sheet';
import { radius, type as typo, useTheme } from '@/ui/theme';

const MONOSPACE = Platform.select({ ios: 'Menlo', android: 'monospace', default: 'monospace' });

/** « Code d’invitation » (screenshot 04-code-invitation): the code, « Partager le code », « Générer un nouveau code ». */
export default function InviteSheet() {
  const { groupId = '' } = useLocalSearchParams<{ groupId: string }>();
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const client = useQueryClient();
  const myGroups = useMyGroups();
  const summary = myGroups.data?.find((item) => item.group.id === groupId) ?? null;
  const canSee = GroupPermissions.canSeeInviteCode(summary?.myRole ?? null);
  const code = useInviteCode(groupId, canSee);
  const [regenerating, setRegenerating] = useState(false);

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

  let content;
  if (myGroups.isSuccess && summary === null) {
    content = <EmptyState icon="people-outline" title="Groupe indisponible" message={GROUP_GONE_MESSAGE} />;
  } else if (summary && !canSee) {
    content = <EmptyState icon="lock-closed" title={INVITE_ADMINS_ONLY_TITLE} message={INVITE_ADMINS_ONLY_MESSAGE} />;
  } else if (code.error) {
    content = <ErrorText message={errorMessage(code.error)} />;
  } else if (!summary || !code.data) {
    content = <Loading />;
  } else {
    const name = summary.group.name;
    const raw = code.data;
    content = (
      <View style={{ alignItems: 'center', gap: 18 }}>
        <GroupTile appearance={groupAppearance(summary.group)} size={56} />
        <Text style={[typo.subheadline, { fontSize: 17, lineHeight: 23, color: theme.textSecondary, textAlign: 'center' }]}>
          {inviteExplanation(name)}
        </Text>
        <View
          style={{
            alignSelf: 'stretch',
            paddingVertical: 18,
            paddingHorizontal: 12,
            borderRadius: radius.card,
            backgroundColor: theme.accentSoft.bg,
            alignItems: 'center',
          }}
        >
          <Text
            selectable
            numberOfLines={1}
            adjustsFontSizeToFit
            accessibilityLabel={formatInviteCode(raw).split('').join(' ')}
            accessibilityHint="Code d’invitation du groupe"
            style={{ fontFamily: MONOSPACE, fontWeight: '900', fontSize: 40, color: theme.accentSoft.text }}
          >
            {formatInviteCode(raw)}
          </Text>
        </View>
        <View style={{ alignSelf: 'stretch' }}>
          <PrimaryButton
            title="Partager le code"
            icon="share-outline"
            onPress={() => void Share.share({ message: inviteShareText(name, raw), title: 'Invitation dans Équipe' })}
          />
        </View>
        <Pressable
          accessibilityRole="button"
          disabled={regenerating}
          onPress={regenerate}
          style={({ pressed }) => ({ minHeight: 44, flexDirection: 'row', alignItems: 'center', gap: 8, opacity: pressed ? 0.6 : 1 })}
        >
          {regenerating ? (
            <ActivityIndicator color={theme.accent} accessibilityLabel="Génération d’un nouveau code" />
          ) : (
            <>
              <Ionicons name="sync" size={20} color={theme.accent} />
              <Text style={{ fontSize: 17, fontWeight: '700', color: theme.accent }}>Générer un nouveau code</Text>
            </>
          )}
        </Pressable>
        <Text style={[typo.footnote, { color: theme.textSecondary, textAlign: 'center' }]}>{INVITE_VALIDITY_TEXT}</Text>
      </View>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: theme.background, paddingTop: Platform.OS === 'ios' ? 0 : insets.top }}>
      <SheetHeader title="Code d’invitation" trailing={<CapsuleButton title="Fermer" onPress={() => router.back()} />} />
      <ScrollView contentContainerStyle={{ paddingHorizontal: 20, paddingTop: 16, paddingBottom: insets.bottom + 24 }}>{content}</ScrollView>
    </View>
  );
}
