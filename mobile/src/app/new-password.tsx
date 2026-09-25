import { useState } from 'react';

import { errorMessage } from '@/core/appError';
import { auth } from '@/data/api';
import { useSession } from '@/data/session';
import { ErrorText, Field, PrimaryButton, SecondaryButton } from '@/ui/components';
import { AuthHeader } from '@/ui/AuthHeader';
import { Screen } from '@/ui/Screen';


/** After a valid recovery code: the new password. */
export default function NewPasswordScreen() {
  const { setRecovering } = useSession();
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
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

  return (
    <Screen contentStyle={{ gap: 18, paddingTop: 80 }}>
      <AuthHeader title="Nouveau mot de passe" subtitle="Choisis-en un d’au moins 8 caractères." />
      <Field
        label="Nouveau mot de passe"
        value={password}
        onChangeText={setPassword}
        secureTextEntry
        autoComplete="new-password"
        textContentType="newPassword"
        onSubmitEditing={submit}
      />
      <ErrorText message={error} />
      <PrimaryButton title="Enregistrer" onPress={submit} loading={loading} disabled={password === ''} />
      <SecondaryButton title="Annuler" onPress={() => void auth.signOut()} />
    </Screen>
  );
}
