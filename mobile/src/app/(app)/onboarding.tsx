import { Ionicons } from '@expo/vector-icons';
import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useState, type ReactNode } from 'react';
import { Alert, KeyboardAvoidingView, Platform, ScrollView, Text, TextInput, View } from 'react-native';
import Animated, { FadeInLeft, FadeInRight } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { AppError, errorMessage } from '@/core/appError';
import { COLOR_KEYS, type ColorKey } from '@/core/colorKey';
import {
  GROUP_NAME_PLACEHOLDER,
  groupNameMessage,
  groupPreview,
  isInviteCodeComplete,
  JOIN_INCOMPLETE_CODE_MESSAGE,
  JOIN_PLACEHOLDER,
  joinResultMessage,
} from '@/core/forms';
import { firstName, quoted } from '@/core/frenchText';
import { formatInviteCodeInput, normalizeInviteCode } from '@/core/inviteCode';
import type { JoinResult, UserProfile } from '@/core/models';
import { onboardingSteps, type NotificationAuthorization, type OnboardingStep } from '@/core/onboarding';
import { EMOJI_CHOICES } from '@/core/presentation';
import { groups } from '@/data/api';
import { useAvatarEditor } from '@/data/avatarEditor';
import { finishOnboarding } from '@/data/onboarding';
import { keys, useMyGroups, useProfile } from '@/data/queries';
import { useUserId } from '@/data/session';
import { getAuthorization, requestAuthorization } from '@/notifications/scheduler';
import { deferNotificationPrompt } from '@/notifications/useNotifications';
import { Card, GroupTile, SegmentedPill } from '@/ui/components';
import {
  AvatarEditorContent,
  BigButton,
  CircleIconButton,
  EmojiGrid,
  HighlightRow,
  IconTile,
  NotificationSamples,
  PickerSection,
  StepHeader,
  StepProgress,
  SwatchGrid,
  TaskCardsIllustration,
  TextButton,
} from '@/ui/onboardingKit';
import { fonts, type as typo, useTheme } from '@/ui/theme';

// The onboarding of a new account (docs/DESIGN-V2.md §7.1, docs/CONTRACTS-V2.md §9; Swift `OnboardingView`,
// `OnboardingViewModel`). The steps are fixed when it opens: « Premier groupe » without a group, « Notifications »
// while the permission was never asked. Finishing, or « Passer » from any step, ends it (`finishOnboarding`): the
// (app) layout then shows the tabs.

const WELCOME_MESSAGE = 'Équipe, c’est la liste de tâches de ton groupe. Trois choses à savoir avant de commencer.';
const AVATAR_TITLE = 'Choisis ton avatar';
const AVATAR_MESSAGE = 'C’est lui que le groupe verra à côté de tes tâches.';
const FIRST_GROUP_TITLE = 'Ton premier groupe';
const FIRST_GROUP_MESSAGE = 'Crée celui de ta coloc, de ta famille ou de ton asso. Ou rejoins un groupe avec son code.';
const GROUP_NAME_LABEL = 'Nom du groupe';
const INVITE_CODE_LABEL = 'Code d’invitation';
const JOIN_HINT = 'Demande-le à un admin du groupe\u{a0}: il le trouve dans Membres.';
const NOTIFICATIONS_TITLE = 'Ne rate plus ton tour';
const NOTIFICATIONS_MESSAGE =
  'Active les notifications pour savoir quand on te confie une tâche, quand c’est ton tour et quand une échéance approche.';
const LATER = 'Plus tard';

type Mode = 'create' | 'join';
type FirstGroupOutcome = { kind: 'created'; name: string } | { kind: 'joined'; result: JoinResult };

export default function OnboardingScreen() {
  const theme = useTheme();
  const profile = useProfile();
  const myGroups = useMyGroups();
  const [permission, setPermission] = useState<NotificationAuthorization | null>(null);
  const [steps, setSteps] = useState<OnboardingStep[] | null>(null);

  useEffect(() => {
    void getAuthorization().then(setPermission);
  }, []);

  // Fixed once known: creating the first group must not remove its step.
  const groupsKnown = myGroups.data !== undefined || myGroups.isError;
  useEffect(() => {
    if (steps === null && permission !== null && groupsKnown) {
      setSteps(onboardingSteps((myGroups.data ?? []).length > 0, permission));
    }
  }, [steps, permission, groupsKnown, myGroups.data]);

  if (!profile.data || steps === null) return <View style={{ flex: 1, backgroundColor: theme.background }} />;
  return <OnboardingFlow profile={profile.data} steps={steps} />;
}

function OnboardingFlow({ profile, steps }: { profile: UserProfile; steps: OnboardingStep[] }) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const client = useQueryClient();
  const userId = useUserId();
  const avatar = useAvatarEditor(profile);

  const [index, setIndex] = useState(0);
  const [forward, setForward] = useState(true);
  const [busy, setBusy] = useState(false);
  const [finished, setFinished] = useState(false);

  const [mode, setMode] = useState<Mode>('create');
  const [outcome, setOutcome] = useState<FirstGroupOutcome | null>(null);
  const [name, setName] = useState('');
  const [nameError, setNameError] = useState<string | null>(null);
  const [color, setColor] = useState<ColorKey>(() => COLOR_KEYS[Math.floor(Math.random() * COLOR_KEYS.length)] ?? 'indigo');
  const [emoji, setEmoji] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [codeError, setCodeError] = useState<string | null>(null);

  const step = steps[index] ?? 'welcome';
  const isLast = index === steps.length - 1;

  const finish = () => {
    if (finished) return;
    setFinished(true);
    void finishOnboarding(client, userId);
  };

  const moveForward = () => {
    setForward(true);
    if (isLast) finish();
    else setIndex(index + 1);
  };

  const showError = (error: unknown) => {
    const message = errorMessage(error);
    if (message) Alert.alert('Erreur', message);
  };

  const submitFirstGroup = async (): Promise<boolean> => {
    if (outcome) return true;
    if (mode === 'create') {
      const message = groupNameMessage(name);
      setNameError(message);
      if (message) return false;
      try {
        const created = await groups.create(name, color, emoji);
        setOutcome({ kind: 'created', name: created.group.name });
      } catch (error) {
        if (AppError.isAppError(error) && error.kind === 'invalidName') setNameError(error.messageFR);
        else showError(error);
        return false;
      }
    } else {
      if (!isInviteCodeComplete(code)) {
        setCodeError(JOIN_INCOMPLETE_CODE_MESSAGE);
        return false;
      }
      setCodeError(null);
      try {
        setOutcome({ kind: 'joined', result: await groups.join(normalizeInviteCode(code)) });
      } catch (error) {
        showError(error);
        return false;
      }
    }
    void client.invalidateQueries({ queryKey: keys.groups });
    return true;
  };

  /** The primary button: saves the avatar, creates or joins the group, asks for the permission; then moves on. */
  const advance = async () => {
    if (busy || finished) return;
    setBusy(true);
    try {
      switch (step) {
        case 'welcome':
          break;
        case 'avatar':
          try {
            await avatar.save();
          } catch (error) {
            showError(error);
            return;
          }
          break;
        case 'firstGroup':
          if (!(await submitFirstGroup())) return;
          break;
        case 'notifications':
          await requestAuthorization();
          break;
      }
      moveForward();
    } finally {
      setBusy(false);
    }
  };

  /** « Plus tard »: the next step without doing this one. */
  const skipStep = () => {
    if (busy || finished) return;
    if (step === 'avatar') avatar.reset();
    if (step === 'notifications') deferNotificationPrompt();
    moveForward();
  };

  const goBack = () => {
    if (index === 0 || busy) return;
    setForward(false);
    setIndex(index - 1);
  };

  let primaryTitle: string;
  switch (step) {
    case 'welcome':
      primaryTitle = 'C’est parti';
      break;
    case 'avatar':
      primaryTitle = isLast ? 'Terminer' : 'Continuer';
      break;
    case 'firstGroup':
      primaryTitle = outcome ? (isLast ? 'Terminer' : 'Continuer') : mode === 'create' ? 'Créer le groupe' : 'Rejoindre le groupe';
      break;
    case 'notifications':
      primaryTitle = 'Activer les notifications';
      break;
  }
  const secondaryTitle = (step === 'firstGroup' && !outcome) || step === 'notifications' ? LATER : null;
  const canAdvance =
    !finished &&
    (step !== 'firstGroup' || outcome !== null || (mode === 'create' ? name.trim() !== '' : normalizeInviteCode(code) !== ''));

  let content: ReactNode;
  switch (step) {
    case 'welcome': {
      const first = firstName(profile.displayName);
      content = (
        <StepColumn gap={26}>
          <View style={{ paddingTop: 4 }}>
            <TaskCardsIllustration />
          </View>
          <StepHeader title={first === '' ? 'Bienvenue\u{a0}!' : `Bienvenue, ${first}\u{a0}!`} message={WELCOME_MESSAGE} large />
          <View style={{ gap: 14 }}>
            <HighlightRow
              icon="sync"
              soft={theme.soft.coral}
              title="À tour de rôle"
              message="Les corvées passent toutes seules à la personne suivante."
            />
            <HighlightRow
              icon="list"
              soft={theme.soft.teal}
              title="Des checklists"
              message="Découpe une tâche en étapes et vois où ça en est."
            />
            <HighlightRow
              icon="trophy-outline"
              soft={theme.soft.amber}
              title="Le récap de la semaine"
              message="Qui a fait quoi, avec le podium du groupe."
            />
          </View>
        </StepColumn>
      );
      break;
    }
    case 'avatar':
      content = (
        <StepColumn gap={24}>
          <StepHeader title={AVATAR_TITLE} message={AVATAR_MESSAGE} />
          <AvatarEditorContent
            appearance={avatar.appearance}
            choices={EMOJI_CHOICES.avatars}
            onColor={avatar.selectColor}
            onEmoji={avatar.selectEmoji}
          />
        </StepColumn>
      );
      break;
    case 'firstGroup':
      content = (
        <StepColumn gap={22}>
          <StepHeader title={FIRST_GROUP_TITLE} message={FIRST_GROUP_MESSAGE} />
          {outcome ? (
            <Card style={{ borderRadius: 24, flexDirection: 'row', alignItems: 'center', gap: 14 }}>
              <IconTile icon="checkmark" soft={theme.soft.green} size={44} />
              <Text style={[typo.body, { flex: 1, fontWeight: '600', color: theme.textPrimary }]}>
                {outcome.kind === 'created' ? `Le groupe ${quoted(outcome.name)} est créé.` : joinResultMessage(outcome.result)}
              </Text>
            </Card>
          ) : (
            <>
              <SegmentedPill
                options={[
                  { key: 'create', label: 'Créer' },
                  { key: 'join', label: 'Rejoindre' },
                ]}
                value={mode}
                onChange={(next) => {
                  if (!busy) setMode(next);
                }}
              />
              {mode === 'create' ? (
                <Card style={{ borderRadius: 24, padding: 18, gap: 16 }}>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
                    <GroupTile appearance={groupPreview(name, color, emoji)} size={60} />
                    <View style={{ flex: 1, gap: 4 }}>
                      <Text style={[typo.footnote, { fontWeight: '700', color: theme.textSecondary }]}>{GROUP_NAME_LABEL}</Text>
                      <TextInput
                        accessibilityLabel={GROUP_NAME_LABEL}
                        value={name}
                        onChangeText={(text) => {
                          setName(text);
                          if (nameError) setNameError(null);
                        }}
                        placeholder={GROUP_NAME_PLACEHOLDER}
                        placeholderTextColor={theme.textSecondary}
                        autoCapitalize="sentences"
                        autoCorrect={false}
                        returnKeyType="done"
                        maxLength={120}
                        style={{ fontFamily: fonts.bold, fontSize: 22, paddingVertical: 4, color: theme.textPrimary }}
                      />
                      <View style={{ height: 2, borderRadius: 1, backgroundColor: nameError ? theme.danger.text : theme.track }} />
                    </View>
                  </View>
                  {nameError ? <FieldError message={nameError} /> : null}
                  <PickerSection title="Emoji">
                    <EmojiGrid
                      choices={EMOJI_CHOICES.groups}
                      value={emoji}
                      onChange={(picked) => setEmoji(picked === emoji ? null : picked)}
                    />
                  </PickerSection>
                  <PickerSection title="Couleur">
                    <SwatchGrid value={color} onChange={setColor} />
                  </PickerSection>
                </Card>
              ) : (
                <Card style={{ borderRadius: 24, padding: 18, gap: 12 }}>
                  <Text style={[typo.footnote, { fontWeight: '700', color: theme.textSecondary }]}>{INVITE_CODE_LABEL}</Text>
                  <TextInput
                    accessibilityLabel={INVITE_CODE_LABEL}
                    value={code}
                    onChangeText={(text) => {
                      setCode(formatInviteCodeInput(text));
                      if (codeError) setCodeError(null);
                    }}
                    placeholder={JOIN_PLACEHOLDER}
                    placeholderTextColor={theme.textSecondary}
                    autoCapitalize="characters"
                    autoCorrect={false}
                    keyboardType={Platform.OS === 'ios' ? 'ascii-capable' : 'visible-password'}
                    returnKeyType="done"
                    onSubmitEditing={() => void advance()}
                    style={{
                      minHeight: 64,
                      paddingHorizontal: 12,
                      borderRadius: 16,
                      borderWidth: 2,
                      borderColor: theme.accent,
                      backgroundColor: theme.background,
                      textAlign: 'center',
                      fontSize: 28,
                      fontWeight: '700',
                      fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace', default: 'monospace' }),
                      color: theme.textPrimary,
                    }}
                  />
                  {codeError ? <FieldError message={codeError} /> : null}
                  <Text style={[typo.subheadline, { color: theme.textSecondary }]}>{JOIN_HINT}</Text>
                </Card>
              )}
            </>
          )}
        </StepColumn>
      );
      break;
    case 'notifications':
      content = (
        <StepColumn gap={26}>
          <View style={{ paddingTop: 4 }}>
            <NotificationSamples />
          </View>
          <StepHeader title={NOTIFICATIONS_TITLE} message={NOTIFICATIONS_MESSAGE} />
        </StepColumn>
      );
      break;
  }

  return (
    <KeyboardAvoidingView
      style={{ flex: 1, backgroundColor: theme.background }}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12, paddingHorizontal: 24, paddingTop: insets.top + 12, paddingBottom: 8 }}>
        {index > 0 ? <CircleIconButton icon="chevron-back" label="Retour" onPress={goBack} disabled={busy || finished} /> : null}
        <StepProgress current={index + 1} total={steps.length} />
        <TextButton title="Passer" onPress={finish} fullWidth={false} disabled={finished} />
      </View>
      <Animated.View
        key={index}
        entering={(forward ? FadeInRight : FadeInLeft).duration(280)}
        style={{ flex: 1 }}
      >
        <ScrollView keyboardShouldPersistTaps="handled" keyboardDismissMode="interactive" contentContainerStyle={{ paddingHorizontal: 24, paddingTop: 8, paddingBottom: 24 }}>
          {content}
        </ScrollView>
      </Animated.View>
      <View style={{ paddingHorizontal: 24, paddingTop: 12, paddingBottom: insets.bottom + 8, gap: 4, backgroundColor: theme.background }}>
        <BigButton
          title={primaryTitle}
          icon={step === 'welcome' ? 'arrow-forward' : step === 'notifications' ? 'notifications' : undefined}
          iconAfter={step === 'welcome'}
          loading={busy || avatar.saving}
          disabled={!canAdvance}
          onPress={() => void advance()}
        />
        {secondaryTitle ? <TextButton title={secondaryTitle} onPress={skipStep} disabled={busy || finished} /> : null}
      </View>
    </KeyboardAvoidingView>
  );
}

function StepColumn({ gap, children }: { gap: number; children: ReactNode }) {
  return <View style={{ gap }}>{children}</View>;
}

function FieldError({ message }: { message: string }) {
  const theme = useTheme();
  return (
    <View style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 6 }}>
      <Ionicons name="alert-circle" size={16} color={theme.danger.text} />
      <Text style={[typo.footnote, { flex: 1, color: theme.danger.text }]}>{message}</Text>
    </View>
  );
}
