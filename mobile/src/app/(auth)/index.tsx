import { Link, router } from 'expo-router';
import { useState } from 'react';
import { Text, View } from 'react-native';

import { AuthHeader } from '@/ui/AuthHeader';

import { errorMessage } from '@/core/appError';
import { auth } from '@/data/api';
import { Field, ErrorText, PrimaryButton, SecondaryButton } from '@/ui/components';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

/** « Connexion » (screenshot 01-connexion). */
export default function LoginScreen() {
  const theme = useTheme();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
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
    <Screen contentStyle={{ gap: 18, paddingTop: 80 }}>
      <AuthHeader title="Équipe" subtitle="Les tâches du groupe, sans prise de tête." />
      <Field
        label="E-mail"
        value={email}
        onChangeText={setEmail}
        autoCapitalize="none"
        autoComplete="email"
        keyboardType="email-address"
        textContentType="emailAddress"
        placeholder="toi@exemple.fr"
      />
      <Field
        label="Mot de passe"
        value={password}
        onChangeText={setPassword}
        secureTextEntry
        autoComplete="current-password"
        textContentType="password"
        onSubmitEditing={submit}
      />
      <ErrorText message={error} />
      <PrimaryButton title="Se connecter" onPress={submit} loading={loading} disabled={email === '' || password === ''} />
      <SecondaryButton title="Mot de passe oublié ?" onPress={() => router.push({ pathname: '/reset', params: { email } })} />
      <View style={{ flexDirection: 'row', justifyContent: 'center', alignItems: 'center', gap: 6 }}>
        <Text style={[typo.subheadline, { color: theme.textSecondary }]}>Pas encore de compte ?</Text>
        <Link href="/signup" style={[typo.subheadline, { color: theme.accent, fontWeight: '700', paddingVertical: 12 }]}>
          Créer un compte
        </Link>
      </View>
    </Screen>
  );
}
