import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { Alert, Platform, ScrollView, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { AppError, errorMessage } from '@/core/appError';
import { colorLabel, type ColorKey } from '@/core/colorKey';
import { GROUP_GONE_MESSAGE } from '@/core/groups';
import { APPEARANCE_TITLE, appearanceColorChoice, appearanceHasChanges, appearancePreview } from '@/core/groupScreens';
import type { GroupSummary, TeamGroup } from '@/core/models';
import { EMOJI_CHOICES } from '@/core/presentation';
import { groups } from '@/data/api';
import { keys, useMyGroups } from '@/data/queries';
import { EmptyState, Loading } from '@/ui/components';
import { EmojiGrid, HeroTile, PickerSection, SwatchGrid } from '@/ui/groupKit';
import { CapsuleButton, SheetHeader } from '@/ui/sheet';
import { fonts, radius, useTheme } from '@/ui/theme';

/** « Apparence » of a group (admins; screenshot 17-groupe-apparence): a live preview, the emoji, the color. */
export default function AppearanceSheet() {
  const { groupId = '' } = useLocalSearchParams<{ groupId: string }>();
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const myGroups = useMyGroups();
  const summary = myGroups.data?.find((item) => item.group.id === groupId) ?? null;

  return (
    <View style={{ flex: 1, backgroundColor: theme.background, paddingTop: Platform.OS === 'ios' ? 0 : insets.top }}>
      {summary ? (
        <Editor group={summary.group} />
      ) : (
        <>
          <SheetHeader title={APPEARANCE_TITLE} leading={<CapsuleButton title="Annuler" onPress={() => router.back()} />} />
          {myGroups.isSuccess ? <EmptyState icon="people-outline" title="Groupe indisponible" message={GROUP_GONE_MESSAGE} /> : <Loading />}
        </>
      )}
    </View>
  );
}

function Editor({ group }: { group: TeamGroup }) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const client = useQueryClient();
  const [color, setColor] = useState<ColorKey | null>(group.color);
  const [emoji, setEmoji] = useState<string | null>(group.emoji);
  const [saving, setSaving] = useState(false);
  const preview = appearancePreview(group, color, emoji);

  const save = async () => {
    setSaving(true);
    try {
      const saved = await groups.setAppearance(group.id, color, emoji);
      client.setQueryData<GroupSummary[]>(keys.groups, (list) =>
        list?.map((item) => (item.group.id === saved.id ? { ...item, group: saved } : item)),
      );
      void client.invalidateQueries({ queryKey: keys.groups });
      void client.invalidateQueries({ queryKey: keys.myTasks });
      void client.invalidateQueries({ queryKey: ['overviews'] });
      router.back();
    } catch (caught) {
      const gone = AppError.isAppError(caught) && caught.kind === 'notFound';
      Alert.alert(APPEARANCE_TITLE, gone ? GROUP_GONE_MESSAGE : (errorMessage(caught) ?? ''), gone ? [{ text: 'OK', onPress: () => router.back() }] : undefined);
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      <SheetHeader
        title={APPEARANCE_TITLE}
        leading={<CapsuleButton title="Annuler" onPress={() => router.back()} disabled={saving} />}
        trailing={
          <CapsuleButton title="Enregistrer" bold onPress={() => void save()} disabled={!appearanceHasChanges(group, color, emoji)} loading={saving} />
        }
      />
      <ScrollView contentContainerStyle={{ paddingHorizontal: 20, paddingTop: 16, paddingBottom: insets.bottom + 32, gap: 24 }}>
        <View
          accessible
          accessibilityLabel="Aperçu du groupe"
          accessibilityValue={{ text: `${preview.emoji ?? `initiales ${preview.initials}`}, ${colorLabel(preview.color).toLowerCase()}` }}
          style={{
            flexDirection: 'row',
            alignItems: 'center',
            gap: 14,
            padding: 18,
            borderRadius: radius.card + 6,
            backgroundColor: theme.fill[preview.color],
          }}
        >
          <HeroTile appearance={preview} size={64} />
          <View style={{ flex: 1, gap: 4 }}>
            <Text style={{ fontFamily: fonts.heavy, fontSize: 22, lineHeight: 27, color: '#FFF' }}>{group.name}</Text>
            <Text style={{ fontSize: 16, fontWeight: '600', color: '#FFF' }}>{colorLabel(preview.color)}</Text>
          </View>
        </View>
        <PickerSection title="Emoji">
          <EmojiGrid options={EMOJI_CHOICES.groups} selection={emoji} initials={preview.initials} onSelect={setEmoji} />
        </PickerSection>
        <PickerSection title="Couleur">
          <SwatchGrid isSelected={(key) => key === preview.color} onSelect={(key) => setColor(appearanceColorChoice(group, key))} />
        </PickerSection>
      </ScrollView>
    </>
  );
}
