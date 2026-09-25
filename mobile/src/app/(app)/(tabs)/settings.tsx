import { Ionicons } from '@expo/vector-icons';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import * as Clipboard from 'expo-clipboard';
import Constants from 'expo-constants';
import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, Alert, AppState, Linking, Platform, Pressable, Text, TextInput, View } from 'react-native';

import { errorMessage } from '@/core/appError';
import { displayNameMessage } from '@/core/forms';
import type { UserProfile } from '@/core/models';
import type { NotificationAuthorization } from '@/core/onboarding';
import { profileAppearance } from '@/core/presentation';
import { auth, profiles } from '@/data/api';
import { mergedProfile } from '@/data/onboarding';
import { keys, useProfile } from '@/data/queries';
import { useSession } from '@/data/session';
import { leadTimeLabel, REMINDER_LEAD_TIMES } from '@/notifications/planning';
import {
  disablePush,
  enablePush,
  NTFY_APP_STORE_URL,
  ntfyAppUrl,
  PUSH_DISABLED_EXPLANATION,
  PUSH_INSTRUCTION_STEPS,
  PUSH_PRIVACY_NOTE,
  pushTopic,
} from '@/notifications/push';
import { cancelAllNotifications, getAuthorization, requestAuthorization } from '@/notifications/scheduler';
import { updateSettings, useNotificationSettings } from '@/notifications/settings';
import { Avatar, ErrorText } from '@/ui/components';
import { extraTokens } from '@/ui/onboardingKit';
import { Screen } from '@/ui/Screen';
import {
  SettingsFooter,
  SettingsPickerRow,
  SettingsRow,
  SettingsSection,
  SettingsTextRow,
  SettingsToggleRow,
} from '@/ui/settingsKit';
import { fonts, type as typo, useTheme } from '@/ui/theme';

// « Réglages » (docs/DESIGN-V2.md §7.8, Swift `SettingsView`): the avatar card (it opens « Ton avatar ») and the
// display name, the notifications (permission, « Récap du lundi »), the reminder lead time, the optional ntfy push,
// sign-out and account deletion. The sections that do not need the profile stay usable when it cannot be loaded.

const WEEKLY_RECAP_TITLE = 'Récap du lundi';
const WEEKLY_RECAP_FOOTER = 'Une notification chaque lundi à 09:00 pour découvrir le podium de la semaine de chaque groupe.';
const DELETE_ACCOUNT_WARNING =
  'Ton compte, ton profil et tes assignations seront supprimés définitivement. Les groupes où il ne reste que toi seront supprimés avec leurs tâches\u{a0}; dans les autres, le membre le plus ancien deviendra admin si tu étais l’unique admin.';

const PUSH_TOPIC_KEY = ['pushTopic'] as const;

function statusText(status: NotificationAuthorization | null): string {
  switch (status) {
    case 'authorized':
      return 'Activées';
    case 'denied':
      return 'Refusées';
    case 'notDetermined':
      return 'Pas encore demandées';
    case null:
      return '…';
  }
}

function statusHint(status: NotificationAuthorization | null): string | null {
  switch (status) {
    case 'denied':
      return 'Pour recevoir les rappels et les nouvelles tâches, autorise les notifications d’Équipe dans l’app Réglages de l’iPhone.';
    case 'notDetermined':
      return 'Autorise les notifications pour recevoir les rappels d’échéance et les nouvelles tâches.';
    default:
      return null;
  }
}

function appVersion(): string {
  const config = Constants.expoConfig;
  const build = config?.ios?.buildNumber ?? (config?.android?.versionCode === undefined ? '1' : String(config.android.versionCode));
  return `${config?.version ?? '—'} (${build})`;
}

export default function SettingsScreen() {
  const theme = useTheme();
  const extra = extraTokens(theme);
  const client = useQueryClient();
  const { state } = useSession();
  const profile = useProfile();
  const settings = useNotificationSettings();
  const topic = useQuery({ queryKey: PUSH_TOPIC_KEY, queryFn: pushTopic });

  const [status, setStatus] = useState<NotificationAuthorization | null>(null);
  const [signingOut, setSigningOut] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [updatingPush, setUpdatingPush] = useState(false);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    void getAuthorization().then(setStatus);
    // The permission may have been changed in the system settings.
    const subscription = AppState.addEventListener('change', (next) => {
      if (next === 'active') void getAuthorization().then(setStatus);
    });
    return () => subscription.remove();
  }, []);

  const me = profile.data;
  const nameEditor = useNameEditor(me);
  const email = state.kind === 'signedIn' ? state.user.email : null;

  const signOut = () =>
    Alert.alert('Se déconnecter\u{a0}?', 'Les rappels programmés sur cet iPhone seront supprimés. Tu pourras te reconnecter à tout moment.', [
      { text: 'Annuler', style: 'cancel' },
      {
        text: 'Se déconnecter',
        style: 'destructive',
        onPress: () => {
          setSigningOut(true);
          void cancelAllNotifications()
            .then(() => auth.signOut())
            .finally(() => setSigningOut(false));
        },
      },
    ]);

  const deleteAccount = () =>
    Alert.alert('Supprimer mon compte\u{a0}?', DELETE_ACCOUNT_WARNING, [
      { text: 'Annuler', style: 'cancel' },
      {
        text: 'Supprimer',
        style: 'destructive',
        onPress: () => {
          setDeleting(true);
          auth
            .deleteAccount()
            .then(() => cancelAllNotifications())
            .catch((caught: unknown) => Alert.alert('Erreur', errorMessage(caught) ?? ''))
            .finally(() => setDeleting(false));
        },
      },
    ]);

  const turnPushOn = async () => {
    setUpdatingPush(true);
    try {
      client.setQueryData(PUSH_TOPIC_KEY, await enablePush());
    } catch (caught) {
      Alert.alert('Erreur', errorMessage(caught) ?? '');
    } finally {
      setUpdatingPush(false);
    }
  };

  const turnPushOff = () =>
    Alert.alert(
      'Désactiver les notifications push\u{a0}?',
      'Ton sujet ntfy sera supprimé. Si tu les réactives, il faudra t’abonner au nouveau sujet dans ntfy.',
      [
        { text: 'Annuler', style: 'cancel' },
        {
          text: 'Désactiver',
          style: 'destructive',
          onPress: () => {
            setUpdatingPush(true);
            disablePush()
              .then(() => client.setQueryData(PUSH_TOPIC_KEY, null))
              .catch((caught: unknown) => Alert.alert('Erreur', errorMessage(caught) ?? ''))
              .finally(() => setUpdatingPush(false));
          },
        },
      ],
    );

  const copyTopic = (value: string) => {
    void Clipboard.setStringAsync(value);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  /** The topic in the ntfy app, or its App Store page when the app is not installed. */
  const openNtfy = (value: string) => {
    Linking.openURL(ntfyAppUrl(value)).catch(() => Linking.openURL(NTFY_APP_STORE_URL).catch(() => undefined));
  };

  const busyAccount = signingOut || deleting;
  const reminderFooter =
    settings.leadTime === 'off'
      ? 'Aucun rappel d’échéance ne sera programmé sur cet iPhone.'
      : `Pour chaque tâche qui t’est assignée et qui a une échéance, un rappel est programmé sur cet iPhone.${
          status === 'denied' ? ' Les notifications étant refusées, les rappels ne s’afficheront pas.' : ''
        }`;
  const hint = statusHint(status);

  return (
    <Screen
      refreshing={profile.isRefetching}
      onRefresh={() => {
        void profile.refetch();
        void topic.refetch();
      }}
      contentStyle={{ paddingHorizontal: 16, gap: 12 }}
    >
      <Text accessibilityRole="header" style={[typo.largeTitle, { color: theme.textPrimary, marginTop: 40, marginLeft: 4 }]}>
        Réglages
      </Text>

      {profile.error ? (
        <View style={{ gap: 8 }}>
          <ErrorText message={`Profil indisponible. ${errorMessage(profile.error) ?? ''}`} />
          <SettingsSection>
            <SettingsRow icon="refresh" soft={theme.accentSoft} title="Réessayer" titleColor={theme.accent} onPress={() => void profile.refetch()} />
          </SettingsSection>
        </View>
      ) : null}

      <Pressable
        accessibilityRole="button"
        accessibilityLabel={`Avatar de ${me?.displayName ?? 'ton profil'}`}
        accessibilityHint="Modifier ta couleur et ton symbole"
        disabled={!me}
        onPress={() => router.push('/avatar')}
        style={({ pressed }) => [
          { flexDirection: 'row', alignItems: 'center', gap: 14, padding: 16, paddingVertical: 22, borderRadius: 26, backgroundColor: theme.card, opacity: pressed ? 0.8 : 1 },
          theme.dark && { borderWidth: 1, borderColor: theme.hairline },
        ]}
      >
        {me ? (
          <Avatar appearance={profileAppearance(me)} size={56} />
        ) : (
          <View style={{ width: 56, height: 56, borderRadius: 28, backgroundColor: theme.track, alignItems: 'center', justifyContent: 'center' }}>
            {profile.isPending ? <ActivityIndicator color={theme.textSecondary} /> : null}
          </View>
        )}
        <View style={{ flex: 1, gap: 2 }}>
          <Text style={{ fontFamily: fonts.heavy, fontSize: 21, lineHeight: 26, color: theme.textPrimary }}>{me?.displayName ?? 'Ton profil'}</Text>
          <Text style={[typo.subheadline, { fontSize: 16, fontWeight: '600', color: me ? theme.accent : theme.textSecondary }]}>
            Modifier l’avatar
          </Text>
        </View>
        <Ionicons name="chevron-forward" size={18} color={extra.textTertiary} />
      </Pressable>

      <SettingsSection
        title="Profil"
        footer={
          nameEditor.error ? (
            <SettingsFooter color={theme.danger.text}>{nameEditor.error}</SettingsFooter>
          ) : (
            <SettingsFooter>Ton nom est visible par les membres de tes groupes.</SettingsFooter>
          )
        }
      >
        <SettingsRow icon="mail" soft={theme.soft.blue} title="E-mail" value={email ?? '—'} />
        {me ? (
          <SettingsRow
            icon="person"
            soft={theme.accentSoft}
            title="Nom affiché"
            trailing={
              <TextInput
                accessibilityLabel="Nom affiché"
                value={nameEditor.name}
                onChangeText={nameEditor.setName}
                placeholder="Ton nom"
                placeholderTextColor={theme.textSecondary}
                textContentType="name"
                autoCapitalize="words"
                returnKeyType="done"
                onSubmitEditing={() => void nameEditor.save()}
                maxLength={80}
                style={[typo.body, { flex: 1, textAlign: 'right', color: theme.textPrimary, paddingVertical: 4 }]}
              />
            }
          />
        ) : (
          <SettingsRow icon="person" soft={theme.accentSoft} title="Nom affiché" value={profile.isPending ? null : '—'} busy={profile.isPending} />
        )}
        {me && (nameEditor.changed || nameEditor.saving) ? (
          <SettingsRow title="Enregistrer le nom" titleColor={theme.accent} busy={nameEditor.saving} onPress={() => void nameEditor.save()} />
        ) : null}
      </SettingsSection>

      <SettingsSection
        title="Notifications"
        footer={
          <>
            {hint ? <SettingsFooter>{hint}</SettingsFooter> : null}
            <SettingsFooter>{WEEKLY_RECAP_FOOTER}</SettingsFooter>
          </>
        }
      >
        <SettingsRow icon="notifications" soft={theme.soft.coral} title="Autorisation" value={statusText(status)} />
        {status === 'notDetermined' ? (
          <SettingsRow
            title="Autoriser les notifications"
            titleColor={theme.accent}
            onPress={() => void requestAuthorization().then(setStatus)}
          />
        ) : null}
        {status === 'denied' && Platform.OS !== 'web' ? (
          <SettingsRow title="Ouvrir les Réglages de l’iPhone" titleColor={theme.accent} onPress={() => void Linking.openSettings()} />
        ) : null}
        <SettingsToggleRow
          icon="trophy"
          soft={theme.soft.amber}
          title={WEEKLY_RECAP_TITLE}
          value={settings.weeklyRecap}
          onChange={(value) => void updateSettings({ weeklyRecap: value })}
        />
      </SettingsSection>

      <SettingsSection title="Rappels d’échéance" footer={<SettingsFooter>{reminderFooter}</SettingsFooter>}>
        <SettingsPickerRow
          icon="alarm"
          soft={theme.soft.orange}
          title="Rappel"
          options={REMINDER_LEAD_TIMES.map((key) => ({ key, label: leadTimeLabel(key) }))}
          value={settings.leadTime}
          onChange={(leadTime) => void updateSettings({ leadTime })}
        />
      </SettingsSection>

      <SettingsSection
        title="Notifications push (ntfy)"
        footer={<SettingsFooter>{topic.data ? PUSH_PRIVACY_NOTE : PUSH_DISABLED_EXPLANATION}</SettingsFooter>}
      >
        {topic.data ? (
          [
            ...PUSH_INSTRUCTION_STEPS.map((text, index) => (
              <SettingsTextRow key={`step-${index}`} number={index + 1}>
                {text}
              </SettingsTextRow>
            )),
            <View key="topic" accessible accessibilityLabel="Ton sujet ntfy" accessibilityValue={{ text: topic.data }} style={{ paddingVertical: 10, paddingHorizontal: 16, gap: 4 }}>
              <Text style={{ fontSize: 12, color: theme.textSecondary }}>Ton sujet ntfy</Text>
              <Text selectable style={{ fontSize: 16, fontFamily: Platform.select({ ios: 'Menlo', default: 'monospace' }), color: theme.textPrimary }}>
                {topic.data}
              </Text>
            </View>,
            <SettingsRow
              key="copy"
              icon={copied ? 'checkmark' : 'copy'}
              soft={theme.accentSoft}
              title={copied ? 'Sujet copié' : 'Copier le sujet'}
              titleColor={theme.accent}
              onPress={() => copyTopic(topic.data ?? '')}
            />,
            <SettingsRow
              key="open"
              icon="open"
              soft={theme.accentSoft}
              title="Ouvrir dans ntfy"
              titleColor={theme.accent}
              onPress={() => openNtfy(topic.data ?? '')}
            />,
            <SettingsRow
              key="install"
              icon="download"
              soft={theme.accentSoft}
              title="Installer ntfy (App Store)"
              titleColor={theme.accent}
              onPress={() => void Linking.openURL(NTFY_APP_STORE_URL).catch(() => undefined)}
            />,
            <SettingsRow
              key="disable"
              icon="notifications-off"
              soft={theme.danger}
              title="Désactiver les notifications push"
              titleColor={theme.danger.text}
              busy={updatingPush}
              onPress={turnPushOff}
            />,
          ]
        ) : (
          <SettingsRow
            icon="radio"
            soft={theme.soft.teal}
            title="Activer les notifications push"
            titleColor={topic.isSuccess ? theme.accent : theme.textSecondary}
            busy={updatingPush}
            disabled={!topic.isSuccess}
            onPress={() => void turnPushOn()}
          />
        )}
      </SettingsSection>

      <SettingsSection
        title="Compte"
        footer={<SettingsFooter>La suppression du compte efface définitivement ton profil et tes assignations.</SettingsFooter>}
      >
        <SettingsRow icon="log-out-outline" soft={extra.neutral} title="Se déconnecter" busy={signingOut} disabled={busyAccount} onPress={signOut} />
        <SettingsRow
          icon="trash"
          soft={theme.danger}
          title="Supprimer mon compte"
          titleColor={theme.danger.text}
          busy={deleting}
          disabled={busyAccount}
          onPress={deleteAccount}
        />
      </SettingsSection>

      <SettingsSection footer={<SettingsFooter>Équipe — les tâches de ton groupe.</SettingsFooter>}>
        <SettingsRow icon="information-circle" soft={extra.neutral} title="Version" value={appVersion()} />
      </SettingsSection>
    </Screen>
  );
}

/** « Nom affiché », edited in place; « Enregistrer le nom » once it changed; the error in the section's footer. */
function useNameEditor(profile: UserProfile | undefined) {
  const client = useQueryClient();
  const saved = profile?.displayName ?? '';
  const [name, setName] = useState(saved);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // A name changed elsewhere (another device) replaces the field.
  useEffect(() => setName(saved), [saved]);

  const save = async () => {
    if (saving) return;
    const problem = displayNameMessage(name);
    setError(problem);
    if (problem) return;
    setSaving(true);
    try {
      const updated = await profiles.updateDisplayName(name);
      client.setQueryData<UserProfile>(keys.profile, (previous) => mergedProfile(updated, previous));
      void client.invalidateQueries({ queryKey: ['group'] });
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setSaving(false);
    }
  };

  return { name, setName, saving, error, changed: name.trim() !== saved, save };
}
