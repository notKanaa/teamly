import { useQueryClient } from '@tanstack/react-query';
import Constants from 'expo-constants';
import { useState } from 'react';
import { Alert, Text, View } from 'react-native';

import { errorMessage } from '@/core/appError';
import { profileAppearance } from '@/core/presentation';
import { auth, profiles } from '@/data/api';
import { keys, useProfile } from '@/data/queries';
import { useSession } from '@/data/session';
import { Avatar, Card, ErrorText, Field, ListRow, PrimaryButton, SectionTitle } from '@/ui/components';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

/** A minimal « Réglages »: the profile, the name, the account. */
export default function SettingsScreen() {
  const theme = useTheme();
  const client = useQueryClient();
  const { state } = useSession();
  const profile = useProfile();
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const saveName = async () => {
    setSaving(true);
    setError(null);
    try {
      const updated = await profiles.updateDisplayName(name);
      client.setQueryData(keys.profile, updated);
      void client.invalidateQueries({ queryKey: ['group'] });
      setEditing(false);
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setSaving(false);
    }
  };

  const signOut = () =>
    Alert.alert('Se déconnecter', 'Tu pourras te reconnecter avec ton e-mail et ton mot de passe.', [
      { text: 'Annuler', style: 'cancel' },
      { text: 'Se déconnecter', style: 'destructive', onPress: () => void auth.signOut() },
    ]);

  const deleteAccount = () =>
    Alert.alert(
      'Supprimer mon compte',
      'Ton compte et tes données seront supprimés définitivement. Les groupes dont tu es le seul admin seront supprimés.',
      [
        { text: 'Annuler', style: 'cancel' },
        {
          text: 'Supprimer',
          style: 'destructive',
          onPress: () => auth.deleteAccount().catch((caught: unknown) => Alert.alert('Supprimer mon compte', errorMessage(caught) ?? '')),
        },
      ],
    );

  const me = profile.data;
  return (
    <Screen refreshing={profile.isRefetching} onRefresh={() => void profile.refetch()}>
      <Text style={[typo.largeTitle, { color: theme.textPrimary }]}>Réglages</Text>
      {profile.error ? <ErrorText message={errorMessage(profile.error)} /> : null}

      {me ? (
        <Card style={{ alignItems: 'center', gap: 10, paddingVertical: 24 }}>
          <Avatar appearance={profileAppearance(me)} size={88} />
          <Text style={[typo.title, { color: theme.textPrimary, textAlign: 'center' }]}>{me.displayName}</Text>
          {state.kind === 'signedIn' && state.user.email ? (
            <Text style={[typo.subheadline, { color: theme.textSecondary }]}>{state.user.email}</Text>
          ) : null}
        </Card>
      ) : null}

      <SectionTitle>Profil</SectionTitle>
      {editing ? (
        <Card style={{ gap: 12 }}>
          <Field label="Ton prénom" value={name} onChangeText={setName} autoFocus maxLength={50} onSubmitEditing={saveName} />
          <ErrorText message={error} />
          <View style={{ flexDirection: 'row', gap: 10 }}>
            <PrimaryButton title="Enregistrer" onPress={saveName} loading={saving} style={{ flex: 1 }} />
          </View>
          <Text onPress={() => setEditing(false)} style={[typo.body, { color: theme.accent, textAlign: 'center', paddingVertical: 8 }]}>
            Annuler
          </Text>
        </Card>
      ) : (
        <Card padded={false}>
          <ListRow
            icon="person"
            label="Nom affiché"
            value={me?.displayName}
            last
            onPress={() => {
              setName(me?.displayName ?? '');
              setEditing(true);
            }}
          />
        </Card>
      )}

      <SectionTitle>Compte</SectionTitle>
      <Card padded={false}>
        <ListRow icon="log-out" iconColor={theme.fill.blue} label="Se déconnecter" onPress={signOut} />
        <ListRow icon="trash" iconColor={theme.fill.coral} label="Supprimer mon compte" destructive last onPress={deleteAccount} />
      </Card>

      <Text style={[typo.footnote, { color: theme.textSecondary, textAlign: 'center' }]}>
        Équipe {Constants.expoConfig?.version ?? ''}
      </Text>
    </Screen>
  );
}
