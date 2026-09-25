import { router } from 'expo-router';
import { useState } from 'react';
import { Text, View } from 'react-native';

import { errorMessage } from '@/core/appError';
import { auth } from '@/data/api';
import { ErrorText, Field, PrimaryButton, SecondaryButton } from '@/ui/components';
import { AuthHeader } from '@/ui/AuthHeader';
import { Screen } from '@/ui/Screen';
import { useTheme } from '@/ui/theme';

/** « Connexion » (screenshot 01-connexion). */
export default function LoginScreen() {
  const theme = useTheme();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const canSubmit = email.trim() !== '' && password !== '' && !loading;

  const submit = async () => {
    if (!canSubmit) return;
    setLoading(true);
    setError(null);
    try {
      await auth.signIn(email, password);
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setLoading(false);
    }
  };

  return (
    <Screen contentStyle={{ gap: 28, paddingTop: 56, paddingHorizontal: 24, maxWidth: 480, width: '100%', alignSelf: 'center' }}>
      <AuthHeader title="Équipe" subtitle="Les tâches de ton groupe, partagées et à jour." />
      <View style={{ gap: 12 }}>
        <Field
          icon="mail"
          value={email}
          onChangeText={setEmail}
          placeholder="Adresse e-mail"
          autoCapitalize="none"
          autoCorrect={false}
          autoComplete="email"
          keyboardType="email-address"
          textContentType="username"
          returnKeyType="next"
        />
        <Field
          icon="lock-closed"
          value={password}
          onChangeText={setPassword}
          placeholder="Mot de passe"
          secureTextEntry
          autoCapitalize="none"
          autoCorrect={false}
          autoComplete="current-password"
          textContentType="password"
          returnKeyType="go"
          onSubmitEditing={submit}
        />
        <View style={{ alignItems: 'flex-end' }}>
          <SecondaryButton
            title={'Mot de passe oublié\u{a0}?'}
            fontSize={15}
            disabled={loading}
            style={{ paddingHorizontal: 4 }}
            onPress={() => router.push({ pathname: '/reset', params: { email } })}
          />
        </View>
      </View>
      <ErrorText message={error} />
      <PrimaryButton title="Se connecter" onPress={submit} loading={loading} disabled={!canSubmit} />
      <View style={{ alignItems: 'center', gap: 2 }}>
        <Text style={{ fontSize: 16, color: theme.textSecondary }}>{'Pas encore de compte\u{a0}?'}</Text>
        <SecondaryButton title="Créer un compte" fontSize={17} disabled={loading} onPress={() => router.push('/signup')} />
      </View>
    </Screen>
  );
}
