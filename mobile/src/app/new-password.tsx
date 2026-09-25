import { useState } from 'react';
import { Alert, Platform, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { errorMessage } from '@/core/appError';
import { passwordMessage, RESET_MISMATCH_MESSAGE } from '@/core/forms';
import { auth } from '@/data/api';
import { useSession } from '@/data/session';
import { CapsuleButton, ErrorText, Field, PrimaryButton } from '@/ui/components';
import { AuthHeader } from '@/ui/AuthHeader';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

/** After a valid recovery code: the new password, twice (« Nouveau mot de passe »). */
export default function NewPasswordScreen() {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const { setRecovering } = useSession();
  const [password, setPassword] = useState('');
  const [confirmation, setConfirmation] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const canSubmit = password !== '' && confirmation !== '' && !loading;

  const submit = async () => {
    if (!canSubmit) return;
    const invalid = passwordMessage(password);
    if (invalid) return setError(invalid);
    if (password !== confirmation) return setError(RESET_MISMATCH_MESSAGE);
    setLoading(true);
    setError(null);
    try {
      await auth.updatePassword(password);
      setRecovering(false);
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setLoading(false);
    }
  };

  const abandon = () => void auth.signOut();
  const confirmAbandon = () => {
    if (Platform.OS === 'web') return abandon();
    Alert.alert(
      'Abandonner le changement de mot de passe\u{a0}?',
      'Ton mot de passe ne sera pas modifié et tu reviendras à l’écran de connexion.',
      [
        { text: 'Continuer', style: 'cancel' },
        { text: 'Abandonner', style: 'destructive', onPress: abandon },
      ],
    );
  };

  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      <View
        style={{
          flexDirection: 'row',
          alignItems: 'center',
          justifyContent: 'space-between',
          paddingTop: insets.top + 8,
          paddingHorizontal: 16,
          paddingBottom: 4,
        }}
      >
        <CapsuleButton title="Annuler" onPress={confirmAbandon} disabled={loading} />
        <Text style={[typo.headline, { color: theme.textPrimary }]}>Nouveau mot de passe</Text>
        <View style={{ width: 96 }} />
      </View>
      <Screen topInset={false} contentStyle={{ gap: 24, paddingTop: 24, paddingHorizontal: 24, maxWidth: 480, width: '100%', alignSelf: 'center' }}>
        <AuthHeader icon="lock-open" subtitle="Choisis un nouveau mot de passe (8 caractères minimum)." />
        <View style={{ gap: 12 }}>
          <Field
            icon="lock-closed"
            value={password}
            onChangeText={setPassword}
            placeholder="Nouveau mot de passe"
            secureTextEntry
            autoCapitalize="none"
            autoCorrect={false}
            autoComplete="new-password"
            textContentType="newPassword"
            returnKeyType="next"
          />
          <Field
            icon="lock-closed"
            value={confirmation}
            onChangeText={setConfirmation}
            placeholder="Confirme le mot de passe"
            secureTextEntry
            autoCapitalize="none"
            autoCorrect={false}
            autoComplete="new-password"
            textContentType="newPassword"
            returnKeyType="done"
            onSubmitEditing={submit}
          />
        </View>
        <ErrorText message={error} />
        <PrimaryButton title="Enregistrer le mot de passe" onPress={submit} loading={loading} disabled={!canSubmit} />
      </Screen>
    </View>
  );
}
