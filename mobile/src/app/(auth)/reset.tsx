import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { Text } from 'react-native';

import { errorMessage } from '@/core/appError';
import { auth } from '@/data/api';
import { useSession } from '@/data/session';
import { Card, ErrorText, Field, PrimaryButton, SecondaryButton } from '@/ui/components';
import { AuthHeader } from '@/ui/AuthHeader';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

/** « Mot de passe oublié » : e-mail, then the 6-digit code received by e-mail. */
export default function ResetScreen() {
  const theme = useTheme();
  const { setRecovering } = useSession();
  const params = useLocalSearchParams<{ email?: string }>();
  const [email, setEmail] = useState(params.email ?? '');
  const [code, setCode] = useState('');
  const [step, setStep] = useState<'email' | 'code'>('email');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const run = async (action: () => Promise<void>) => {
    setLoading(true);
    setError(null);
    try {
      await action();
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setLoading(false);
    }
  };

  const sendCode = () =>
    run(async () => {
      await auth.sendPasswordReset(email);
      setStep('code');
    });

  const verify = () =>
    run(async () => {
      setRecovering(true);
      try {
        await auth.verifyRecoveryCode(email, code);
      } catch (caught) {
        setRecovering(false);
        throw caught;
      }
    });

  return (
    <Screen contentStyle={{ gap: 18, paddingTop: 60 }}>
      <AuthHeader
        title="Mot de passe oublié"
        subtitle={step === 'email' ? 'On t’envoie un code à 6 chiffres par e-mail.' : `Saisis le code reçu à ${email.trim()}.`}
      />
      {step === 'email' ? (
        <Field
          label="E-mail"
          value={email}
          onChangeText={setEmail}
          autoCapitalize="none"
          autoComplete="email"
          keyboardType="email-address"
          textContentType="emailAddress"
          onSubmitEditing={sendCode}
        />
      ) : (
        <>
          <Field
            label="Code"
            value={code}
            onChangeText={(text) => setCode(text.replace(/\D/g, '').slice(0, 6))}
            keyboardType="number-pad"
            textContentType="oneTimeCode"
            autoComplete="one-time-code"
            placeholder="123456"
            style={{ fontSize: 28, letterSpacing: 8, textAlign: 'center', fontFamily: 'Nunito_900Black' }}
            onSubmitEditing={verify}
          />
          <Card>
            <Text style={[typo.footnote, { color: theme.textSecondary }]}>
              Pas reçu ? Vérifie tes spams, ou renvoie un code dans une minute.
            </Text>
          </Card>
        </>
      )}
      <ErrorText message={error} />
      {step === 'email' ? (
        <PrimaryButton title="Envoyer le code" onPress={sendCode} loading={loading} disabled={email === ''} />
      ) : (
        <>
          <PrimaryButton title="Valider" onPress={verify} loading={loading} disabled={code.length < 6} />
          <SecondaryButton title="Renvoyer le code" onPress={sendCode} disabled={loading} />
        </>
      )}
      <SecondaryButton title="Retour à la connexion" onPress={() => router.back()} />
    </Screen>
  );
}
