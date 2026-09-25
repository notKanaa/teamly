import { router } from 'expo-router';
import { ActivityIndicator, Alert, Pressable, Text, View } from 'react-native';

import { errorMessage } from '@/core/appError';
import type { UserProfile } from '@/core/models';
import { EMOJI_CHOICES } from '@/core/presentation';
import { useAvatarEditor } from '@/data/avatarEditor';
import { useProfile } from '@/data/queries';
import { Loading } from '@/ui/components';
import { AvatarEditorContent } from '@/ui/onboardingKit';
import { Screen } from '@/ui/Screen';
import { fonts, type as typo, useTheme } from '@/ui/theme';

/**
 * « Ton avatar » (sheet of « Réglages »): the avatar picker, « Annuler » and « Enregistrer » (enabled once something
 * changed; a spinner while it saves). An error shows in an alert and keeps the choice.
 */
export default function AvatarSheet() {
  const profile = useProfile();
  if (!profile.data) return <Loading />;
  return <AvatarSheetContent profile={profile.data} />;
}

function AvatarSheetContent({ profile }: { profile: UserProfile }) {
  const theme = useTheme();
  const editor = useAvatarEditor(profile);

  const save = async () => {
    try {
      if (await editor.save()) router.back();
    } catch (caught) {
      const message = errorMessage(caught);
      if (message) Alert.alert('Erreur', message);
    }
  };

  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16, paddingTop: 14, paddingBottom: 6, minHeight: 56 }}>
        <View style={{ flex: 1, alignItems: 'flex-start' }}>
          <Pressable accessibilityRole="button" disabled={editor.saving} onPress={() => router.back()} hitSlop={8}>
            <Text style={[typo.body, { color: editor.saving ? theme.textSecondary : theme.accent }]}>Annuler</Text>
          </Pressable>
        </View>
        <Text accessibilityRole="header" style={{ fontFamily: fonts.extraBold, fontSize: 17, color: theme.textPrimary }}>
          Ton avatar
        </Text>
        <View style={{ flex: 1, alignItems: 'flex-end' }}>
          {editor.saving ? (
            <ActivityIndicator color={theme.accent} />
          ) : (
            <Pressable accessibilityRole="button" disabled={!editor.hasChanges} onPress={save} hitSlop={8}>
              <Text style={[typo.body, { fontWeight: '700', color: editor.hasChanges ? theme.accent : theme.textSecondary }]}>
                Enregistrer
              </Text>
            </Pressable>
          )}
        </View>
      </View>
      <Screen topInset={false} contentStyle={{ paddingTop: 16 }}>
        <AvatarEditorContent
          appearance={editor.appearance}
          choices={EMOJI_CHOICES.avatars}
          onColor={editor.selectColor}
          onEmoji={editor.selectEmoji}
        />
      </Screen>
    </View>
  );
}
