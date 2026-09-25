import { Ionicons } from '@expo/vector-icons';
import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { errorMessage } from '@/core/appError';
import { normalizedEmail } from '@/core/inputValidation';
import { RESET_CODE_LENGTH, RESET_RESENT_MESSAGE, resetCodeSentMessage, sanitizedResetCode } from '@/core/forms';
import { auth } from '@/data/api';
import { useSession } from '@/data/session';
import { CapsuleButton, ErrorText, Field, PrimaryButton, SecondaryButton } from '@/ui/components';
import { AuthHeader } from '@/ui/AuthHeader';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

/** « Mot de passe oublié » : e-mail, then the 6-digit code received by e-mail (then `new-password`). */
export default function ResetScreen() {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const { setRecovering } = useSession();
  const params = useLocalSearchParams<{ email?: string }>();
  const [email, setEmail] = useState(params.email ?? '');
  const [code, setCode] = useState('');
  const [step, setStep] = useState<'email' | 'code'>('email');
  const [info, setInfo] = useState<string | null>(null);
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
      setInfo(resetCodeSentMessage(normalizedEmail(email)));
      setCode('');
      setStep('code');
    });

  const resend = () =>
    run(async () => {
      await auth.sendPasswordReset(email);
      setInfo(RESET_RESENT_MESSAGE);
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

  const cancel = () => (router.canGoBack() ? router.back() : router.replace('/'));

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
        <CapsuleButton title="Annuler" onPress={cancel} disabled={loading} />
        <Text style={[typo.headline, { color: theme.textPrimary }]}>Mot de passe oublié</Text>
        <View style={{ width: 96 }} />
      </View>
      <Screen topInset={false} contentStyle={{ gap: 24, paddingTop: 24, paddingHorizontal: 24, maxWidth: 480, width: '100%', alignSelf: 'center' }}>
        <AuthHeader
          icon={step === 'email' ? 'key' : 'mail-open'}
          subtitle={
            step === 'email'
              ? 'Saisis l’adresse e-mail de ton compte\u{a0}: nous t’enverrons un code à 6 chiffres pour choisir un nouveau mot de passe.'
              : 'Saisis le code à 6 chiffres reçu par e-mail. Pense à vérifier tes courriers indésirables.'
          }
        />
        {info && step === 'code' ? (
          <View style={{ flexDirection: 'row', gap: 10, backgroundColor: theme.accentSoft.bg, borderRadius: 16, padding: 14 }}>
            <Ionicons name="information-circle" size={20} color={theme.accentSoft.text} />
            <Text style={[typo.subheadline, { color: theme.textPrimary, flex: 1 }]}>{info}</Text>
          </View>
        ) : null}
        {step === 'email' ? (
          <View style={{ gap: 20 }}>
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
              returnKeyType="send"
              autoFocus={email === ''}
              onSubmitEditing={() => {
                if (email.trim() !== '' && !loading) void sendCode();
              }}
            />
            <ErrorText message={error} />
            <PrimaryButton title="Envoyer le code" onPress={sendCode} loading={loading} disabled={email.trim() === ''} />
          </View>
        ) : (
          <View style={{ gap: 20 }}>
            <Field
              icon="keypad"
              accessibilityLabel="Code reçu par e-mail"
              value={code}
              onChangeText={(text) => setCode(sanitizedResetCode(text))}
              placeholder="Code à 6 chiffres"
              keyboardType="number-pad"
              textContentType="oneTimeCode"
              autoComplete="one-time-code"
              autoFocus
              maxLength={RESET_CODE_LENGTH}
              style={{ fontSize: 24, letterSpacing: code === '' ? 0 : 6, textAlign: 'center', fontFamily: 'Nunito_800ExtraBold' }}
              onSubmitEditing={() => {
                if (code.length === RESET_CODE_LENGTH && !loading) void verify();
              }}
            />
            <ErrorText message={error} />
            <PrimaryButton title="Valider le code" onPress={verify} loading={loading} disabled={code.length < RESET_CODE_LENGTH} />
            <View style={{ gap: 4 }}>
              <SecondaryButton title="Renvoyer le code" onPress={resend} disabled={loading} />
              <SecondaryButton
                title="Modifier l’adresse e-mail"
                color={theme.textSecondary}
                disabled={loading}
                onPress={() => {
                  setStep('email');
                  setInfo(null);
                  setError(null);
                }}
              />
            </View>
          </View>
        )}
      </Screen>
    </View>
  );
}
