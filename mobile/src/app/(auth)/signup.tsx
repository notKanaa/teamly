import { router } from 'expo-router';
import { useState } from 'react';
import { Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { errorMessage } from '@/core/appError';
import { CONFIRMATION_REQUIRED_MESSAGE, displayNameMessage, emailMessage, passwordMessage } from '@/core/forms';
import { auth } from '@/data/api';
import { CircleIconButton, ErrorText, Field, PrimaryButton, SecondaryButton } from '@/ui/components';
import { AuthHeader } from '@/ui/AuthHeader';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

/** « Créer un compte ». Each field shows its own message; with e-mail confirmation, a message invites to confirm. */
export default function SignUpScreen() {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [errors, setErrors] = useState<{ name: string | null; email: string | null; password: string | null }>({
    name: null,
    email: null,
    password: null,
  });
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmationSent, setConfirmationSent] = useState(false);
  const canSubmit = name.trim() !== '' && email.trim() !== '' && password !== '' && !loading;

  const submit = async () => {
    if (!canSubmit) return;
    const checked = { name: displayNameMessage(name), email: emailMessage(email), password: passwordMessage(password) };
    setErrors(checked);
    if (checked.name || checked.email || checked.password) return;
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

  const back = () => (router.canGoBack() ? router.back() : router.replace('/'));

  const backButton = (
    <View style={{ position: 'absolute', top: insets.top + 8, left: 16 }}>
      <CircleIconButton icon="chevron-back" label="Retour à la connexion" onPress={back} />
    </View>
  );

  if (confirmationSent) {
    return (
      <View style={{ flex: 1, backgroundColor: theme.background }}>
        <Screen contentStyle={{ gap: 20, paddingTop: 110, paddingHorizontal: 24, maxWidth: 480, width: '100%', alignSelf: 'center' }}>
          <AuthHeader icon="mail-unread" iconSize={72} />
          <Text accessibilityRole="header" style={[typo.title, { color: theme.textPrimary, textAlign: 'center' }]}>
            Vérifie tes e-mails
          </Text>
          <Text style={[typo.body, { fontSize: 16, color: theme.textSecondary, textAlign: 'center' }]}>{CONFIRMATION_REQUIRED_MESSAGE}</Text>
          <PrimaryButton title="Retour à la connexion" onPress={back} />
        </Screen>
      </View>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      <Screen contentStyle={{ gap: 24, paddingTop: 64, paddingHorizontal: 24, maxWidth: 480, width: '100%', alignSelf: 'center' }}>
        <AuthHeader title="Créer un compte" subtitle="Rejoins tes groupes et suis les tâches qui te sont confiées." brandSize={64} />
        <View style={{ gap: 12 }}>
          <Field
            icon="person"
            value={name}
            onChangeText={(text) => {
              setName(text);
              if (errors.name) setErrors({ ...errors, name: displayNameMessage(text) });
            }}
            error={errors.name}
            placeholder="Ton nom"
            autoCapitalize="words"
            autoComplete="name"
            textContentType="name"
            returnKeyType="next"
          />
          <Field
            icon="mail"
            value={email}
            onChangeText={(text) => {
              setEmail(text);
              if (errors.email) setErrors({ ...errors, email: emailMessage(text) });
            }}
            error={errors.email}
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
            onChangeText={(text) => {
              setPassword(text);
              if (errors.password) setErrors({ ...errors, password: passwordMessage(text) });
            }}
            error={errors.password}
            placeholder="Mot de passe"
            secureTextEntry
            autoCapitalize="none"
            autoCorrect={false}
            autoComplete="new-password"
            textContentType="newPassword"
            returnKeyType="join"
            onSubmitEditing={submit}
          />
          {errors.password ? null : (
            <Text style={[typo.footnote, { color: theme.textSecondary, paddingLeft: 4 }]}>8 caractères minimum.</Text>
          )}
        </View>
        <ErrorText message={error} />
        <PrimaryButton title="Créer mon compte" onPress={submit} loading={loading} disabled={!canSubmit} />
        <View style={{ alignItems: 'center', gap: 2 }}>
          <Text style={{ fontSize: 16, color: theme.textSecondary }}>{'Déjà un compte\u{a0}?'}</Text>
          <SecondaryButton title="Se connecter" fontSize={17} disabled={loading} onPress={back} />
        </View>
      </Screen>
      {backButton}
    </View>
  );
}
