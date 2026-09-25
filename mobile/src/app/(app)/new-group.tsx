import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useState, type ReactNode } from 'react';
import { KeyboardAvoidingView, Platform, ScrollView, Text, TextInput, View } from 'react-native';
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
import {
  ALREADY_MEMBER_TITLE,
  CREATE_GROUP_FOOTER,
  groupNameCounterText,
  isGroupNameTooLong,
  JOIN_HINT,
  JOIN_TITLE,
  JOINED_TITLE,
  toggledEmoji,
} from '@/core/groupScreens';
import { formatInviteCodeInput, normalizeInviteCode } from '@/core/inviteCode';
import type { GroupSummary, JoinResult } from '@/core/models';
import { EMOJI_CHOICES } from '@/core/presentation';
import { groups } from '@/data/api';
import { keys } from '@/data/queries';
import { ErrorText, PrimaryButton } from '@/ui/components';
import { EmojiGrid, IconTile, PickerSection, PreviewTile, SwatchGrid } from '@/ui/groupKit';
import { CapsuleButton, SheetHeader } from '@/ui/sheet';
import { fonts, type as typo, useTheme } from '@/ui/theme';

const MONOSPACE = Platform.select({ ios: 'Menlo', android: 'monospace', default: 'monospace' });

/** « Nouveau groupe » (screenshot 03-creer-groupe), or « Rejoindre un groupe » with `mode=join`. */
export default function NewGroupSheet() {
  const params = useLocalSearchParams<{ mode?: string }>();
  return params.mode === 'join' ? <JoinGroupSheet /> : <CreateGroupSheet />;
}

function useOpenGroup() {
  const client = useQueryClient();
  return (groupId: string) => {
    void client.invalidateQueries({ queryKey: keys.groups });
    void client.invalidateQueries({ queryKey: ['overviews'] });
    void client.invalidateQueries({ queryKey: keys.myTasks });
    router.dismiss();
    router.push(`/group/${groupId}`);
  };
}

function SheetFrame({ header, children }: { header: ReactNode; children: ReactNode }) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  return (
    <KeyboardAvoidingView
      style={{ flex: 1, backgroundColor: theme.background, paddingTop: Platform.OS === 'ios' ? 0 : insets.top }}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      {header}
      <ScrollView
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="interactive"
        contentContainerStyle={{ paddingHorizontal: 20, paddingTop: 12, paddingBottom: insets.bottom + 32, gap: 14 }}
      >
        {children}
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

function CreateGroupSheet() {
  const theme = useTheme();
  const client = useQueryClient();
  const openGroup = useOpenGroup();
  const [name, setName] = useState('');
  const [color, setColor] = useState<ColorKey>(() => COLOR_KEYS[Math.floor(Math.random() * COLOR_KEYS.length)] ?? 'indigo');
  const [emoji, setEmoji] = useState<string | null>(null);
  const [nameError, setNameError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const tooLong = isGroupNameTooLong(name);
  const canSubmit = name.trim() !== '' && !submitting;

  const submit = async () => {
    if (!canSubmit) return;
    const message = groupNameMessage(name);
    setNameError(message);
    setError(null);
    if (message) return;
    setSubmitting(true);
    try {
      const created = await groups.create(name, color, emoji);
      client.setQueryData<GroupSummary[]>(keys.groups, (list) => (list ? [created, ...list] : [created]));
      openGroup(created.group.id);
    } catch (caught) {
      if (AppError.isAppError(caught) && caught.kind === 'invalidName') setNameError(caught.messageFR);
      else setError(errorMessage(caught));
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <SheetFrame
      header={
        <SheetHeader
          title="Nouveau groupe"
          leading={<CapsuleButton title="Annuler" onPress={() => router.back()} disabled={submitting} />}
          trailing={<CapsuleButton title="Créer" bold onPress={() => void submit()} disabled={!canSubmit} loading={submitting} />}
        />
      }
    >
      <View style={[{ backgroundColor: theme.card, borderRadius: 24, padding: 18, gap: 18 }, theme.cardShadow]}>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
          <PreviewTile appearance={groupPreview(name, color, emoji)} size={60} />
          <View style={{ flex: 1, gap: 4 }}>
            <Text style={[typo.footnote, { fontWeight: '700', color: theme.textSecondary }]}>Nom du groupe</Text>
            <TextInput
              accessibilityLabel="Nom du groupe"
              value={name}
              onChangeText={(text) => {
                setName(text);
                if (nameError) setNameError(groupNameMessage(text));
              }}
              placeholder={GROUP_NAME_PLACEHOLDER}
              placeholderTextColor={theme.textSecondary}
              autoFocus
              autoCapitalize="sentences"
              autoCorrect={false}
              returnKeyType="done"
              style={{ fontFamily: fonts.extraBold, fontSize: 22, color: theme.textPrimary, paddingVertical: 4 }}
            />
            <View style={{ height: 2, borderRadius: 1, backgroundColor: nameError ? theme.danger.text : theme.track }} />
          </View>
        </View>
        <View style={{ flexDirection: 'row', alignItems: 'baseline', gap: 8, marginTop: -4 }}>
          <Text style={[typo.footnote, { flex: 1, color: theme.danger.text }]}>{nameError ?? ''}</Text>
          <Text
            accessibilityLabel={`${groupNameCounterText(name).replace('/', ' caractères sur ')}`}
            style={[typo.footnote, { fontWeight: '600', fontVariant: ['tabular-nums'], color: tooLong ? theme.danger.text : theme.textSecondary }]}
          >
            {groupNameCounterText(name)}
          </Text>
        </View>
        <PickerSection title="Emoji">
          <EmojiGrid options={EMOJI_CHOICES.groups} selection={emoji} onSelect={(option) => option && setEmoji(toggledEmoji(emoji, option))} />
        </PickerSection>
        <PickerSection title="Couleur">
          <SwatchGrid isSelected={(key) => key === color} onSelect={setColor} />
        </PickerSection>
      </View>
      <Text style={[typo.footnote, { fontSize: 15, lineHeight: 21, color: theme.textSecondary, paddingHorizontal: 4 }]}>{CREATE_GROUP_FOOTER}</Text>
      <ErrorText message={error} />
    </SheetFrame>
  );
}

function JoinGroupSheet() {
  const theme = useTheme();
  const openGroup = useOpenGroup();
  const [code, setCode] = useState('');
  const [result, setResult] = useState<JoinResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const canSubmit = normalizeInviteCode(code).length > 0 && !submitting;

  const submit = async () => {
    if (!canSubmit) return;
    setError(null);
    if (!isInviteCodeComplete(code)) {
      setError(JOIN_INCOMPLETE_CODE_MESSAGE);
      return;
    }
    setSubmitting(true);
    try {
      setResult(await groups.join(normalizeInviteCode(code)));
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <SheetFrame
      header={
        <SheetHeader
          title="Rejoindre un groupe"
          leading={<CapsuleButton title={result ? 'Fermer' : 'Annuler'} onPress={() => router.back()} disabled={submitting} />}
        />
      }
    >
      {result ? (
        <View style={{ alignItems: 'center', gap: 18, paddingTop: 12 }}>
          <IconTile icon="checkmark" soft={theme.soft.green} size={64} />
          <Text accessibilityRole="header" style={[typo.title, { color: theme.textPrimary, textAlign: 'center' }]}>
            {result.alreadyMember ? ALREADY_MEMBER_TITLE : JOINED_TITLE}
          </Text>
          <Text style={[typo.body, { color: theme.textSecondary, textAlign: 'center' }]}>{joinResultMessage(result)}</Text>
          <PrimaryButton title="Ouvrir le groupe" icon="arrow-forward" onPress={() => openGroup(result.groupId)} style={{ alignSelf: 'stretch', marginTop: 8 }} />
        </View>
      ) : (
        <View style={{ alignItems: 'center', gap: 18, paddingTop: 12 }}>
          <IconTile icon="key" soft={theme.accentSoft} size={64} />
          <View style={{ gap: 6 }}>
            <Text accessibilityRole="header" style={[typo.title, { color: theme.textPrimary, textAlign: 'center' }]}>
              {JOIN_TITLE}
            </Text>
            <Text style={[typo.subheadline, { color: theme.textSecondary, textAlign: 'center' }]}>{JOIN_HINT}</Text>
          </View>
          <TextInput
            accessibilityLabel="Code d’invitation"
            value={code}
            onChangeText={(text) => {
              setCode(formatInviteCodeInput(text));
              setError(null);
            }}
            placeholder={JOIN_PLACEHOLDER}
            placeholderTextColor={theme.textSecondary}
            autoFocus
            autoCapitalize="characters"
            autoCorrect={false}
            keyboardType={Platform.OS === 'ios' ? 'ascii-capable' : 'visible-password'}
            returnKeyType="join"
            onSubmitEditing={() => void submit()}
            editable={!submitting}
            style={{
              alignSelf: 'stretch',
              minHeight: 64,
              paddingHorizontal: 12,
              borderRadius: 16,
              borderWidth: 2,
              borderColor: theme.accent,
              backgroundColor: theme.card,
              color: theme.textPrimary,
              textAlign: 'center',
              fontFamily: MONOSPACE,
              fontWeight: '700',
              fontSize: 28,
              letterSpacing: 2,
            }}
          />
          <ErrorText message={error} />
          <View style={{ alignSelf: 'stretch', marginTop: 4 }}>
            <PrimaryButton title="Rejoindre" icon="arrow-forward" onPress={() => void submit()} loading={submitting} disabled={!canSubmit} />
          </View>
        </View>
      )}
    </SheetFrame>
  );
}
