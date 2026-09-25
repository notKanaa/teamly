import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { Text, View } from 'react-native';

import { errorMessage } from '@/core/appError';
import type { ColorKey } from '@/core/colorKey';
import {
  GROUP_NAME_PLACEHOLDER,
  groupPreview,
  isInviteCodeComplete,
  JOIN_INCOMPLETE_CODE_MESSAGE,
  JOIN_PLACEHOLDER,
} from '@/core/forms';
import { formatInviteCodeInput, normalizeInviteCode } from '@/core/inviteCode';
import { EMOJI_CHOICES } from '@/core/presentation';
import { groups } from '@/data/api';
import { keys } from '@/data/queries';
import { Card, ErrorText, Field, GroupTile, PrimaryButton, SecondaryButton, SegmentedPill } from '@/ui/components';
import { EmojiGrid, SwatchGrid } from '@/ui/pickers';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

type Mode = 'create' | 'join';

/** The Créer / Rejoindre sheet. */
export default function NewGroupSheet() {
  const theme = useTheme();
  const client = useQueryClient();
  const params = useLocalSearchParams<{ mode?: string }>();
  const [mode, setMode] = useState<Mode>(params.mode === 'join' ? 'join' : 'create');
  const [name, setName] = useState('');
  const [color, setColor] = useState<ColorKey>('indigo');
  const [emoji, setEmoji] = useState<string | null>(EMOJI_CHOICES.groups[0] ?? null);
  const [code, setCode] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const open = (groupId: string) => {
    void client.invalidateQueries({ queryKey: keys.groups });
    router.dismiss();
    router.push(`/group/${groupId}`);
  };

  const submit = async () => {
    setLoading(true);
    setError(null);
    try {
      if (mode === 'create') {
        const created = await groups.create(name, color, emoji);
        client.setQueryData(keys.groups, (list: unknown[] | undefined) => (list ? [created, ...list] : [created]));
        open(created.group.id);
      } else {
        if (!isInviteCodeComplete(code)) {
          setError(JOIN_INCOMPLETE_CODE_MESSAGE);
          return;
        }
        const result = await groups.join(normalizeInviteCode(code));
        open(result.groupId);
      }
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setLoading(false);
    }
  };

  return (
    <Screen topInset={false} contentStyle={{ paddingTop: 20 }}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
        <Text style={[typo.title, { color: theme.textPrimary }]}>{mode === 'create' ? 'Nouveau groupe' : 'Rejoindre'}</Text>
        <SecondaryButton title="Fermer" onPress={() => router.back()} />
      </View>
      <SegmentedPill
        options={[
          { key: 'create', label: 'Créer' },
          { key: 'join', label: 'Rejoindre' },
        ]}
        value={mode}
        onChange={(next) => {
          setMode(next);
          setError(null);
        }}
      />
      {mode === 'create' ? (
        <>
          <View style={{ alignItems: 'center', paddingVertical: 8 }}>
            <GroupTile appearance={groupPreview(name, color, emoji)} size={88} />
          </View>
          <Field label="Nom du groupe" value={name} onChangeText={setName} placeholder={GROUP_NAME_PLACEHOLDER} maxLength={60} />
          <Card style={{ gap: 12 }}>
            <Text style={[typo.headline, { color: theme.textPrimary }]}>Emoji</Text>
            <EmojiGrid choices={EMOJI_CHOICES.groups} value={emoji} onChange={setEmoji} />
          </Card>
          <Card style={{ gap: 12 }}>
            <Text style={[typo.headline, { color: theme.textPrimary }]}>Couleur</Text>
            <SwatchGrid value={color} onChange={setColor} />
          </Card>
        </>
      ) : (
        <>
          <Field
            label="Code d’invitation"
            value={code}
            onChangeText={(text) => setCode(formatInviteCodeInput(text))}
            placeholder={JOIN_PLACEHOLDER}
            autoCapitalize="characters"
            autoCorrect={false}
            style={{ fontSize: 28, letterSpacing: 4, textAlign: 'center', fontFamily: 'Nunito_900Black', minHeight: 64 }}
            onSubmitEditing={submit}
          />
          <Text style={[typo.footnote, { color: theme.textSecondary, textAlign: 'center' }]}>
            Demande le code à un admin du groupe : il le trouve dans « Inviter ».
          </Text>
        </>
      )}
      <ErrorText message={error} />
      <PrimaryButton
        title={mode === 'create' ? 'Créer le groupe' : 'Rejoindre'}
        onPress={submit}
        loading={loading}
        disabled={mode === 'create' ? name.trim() === '' : code === ''}
      />
    </Screen>
  );
}
