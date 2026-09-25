import { router } from 'expo-router';
import { useState } from 'react';
import { Text } from 'react-native';

import { errorMessage } from '@/core/appError';
import { auth } from '@/data/api';
import { Card, ErrorText, Field, PrimaryButton, SecondaryButton } from '@/ui/components';
import { AuthHeader } from '@/ui/AuthHeader';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

/** « Créer un compte ». */
export default function SignUpScreen() {
  const theme = useTheme();
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmationSent, setConfirmationSent] = useState(false);

  const submit = async () => {
    setLoading(true);
    setError(null);
    try {
      const outcome = await auth.signUp(email, password, name);
      if (outcome === 'confirmationRequired') setConfirmationSent(true);
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setLoading(false);
    }
  };

  if (confirmationSent) {
    return (
      <Screen contentStyle={{ paddingTop: 80 }}>
        <AuthHeader title="Vérifie tes e-mails" subtitle={`Un lien de confirmation a été envoyé à ${email.trim()}.`} />
        <Card>
          <Text style={[typo.body, { color: theme.textSecondary }]}>
            Ouvre-le, puis reviens ici pour te connecter.
          </Text>
        </Card>
        <PrimaryButton title="Retour à la connexion" onPress={() => router.back()} />
      </Screen>
    );
  }

  return (
    <Screen contentStyle={{ gap: 18, paddingTop: 60 }}>
      <AuthHeader title="Créer un compte" subtitle="Rejoins ton équipe en quelques secondes." />
      <Field label="Ton prénom" value={name} onChangeText={setName} autoComplete="name" textContentType="name" placeholder="Camille" />
      <Field
        label="E-mail"
        value={email}
        onChangeText={setEmail}
        autoCapitalize="none"
        autoComplete="email"
        keyboardType="email-address"
        textContentType="emailAddress"
      />
      <Field
        label="Mot de passe (8 caractères minimum)"
        value={password}
        onChangeText={setPassword}
        secureTextEntry
        autoComplete="new-password"
        textContentType="newPassword"
        onSubmitEditing={submit}
      />
      <ErrorText message={error} />
      <PrimaryButton title="Créer mon compte" onPress={submit} loading={loading} disabled={!name || !email || !password} />
      <SecondaryButton title="J’ai déjà un compte" onPress={() => router.back()} />
    </Screen>
  );
}
