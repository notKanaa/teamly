import { Ionicons } from '@expo/vector-icons';
import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams, useNavigation } from 'expo-router';
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Alert, KeyboardAvoidingView, Platform, Pressable, ScrollView, Switch, Text, TextInput, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { AppError, errorMessage } from '@/core/appError';
import { FrenchCalendar } from '@/core/calendar';
import { recurrenceSummaryOf } from '@/core/recurrenceText';
import { Limits } from '@/core/limits';
import type { Membership, TaskItem, TaskPriority } from '@/core/models';
import { canCreateTask, canEditTask } from '@/core/permissions';
import { PRIORITY_PICKER_ORDER, priorityLabel, profileAppearance } from '@/core/presentation';
import {
  addChecklistItem,
  assigneeOptions,
  canSave,
  canUseRotation,
  editorDraft,
  editorErrorField,
  editorRecurrenceSummary,
  editorTitle,
  editorUpcomingTexts,
  hasChanges,
  hasEditorErrors,
  isRecurring,
  keepingMembers,
  makeEditorState,
  moveRotationMember,
  NO_EDITOR_ERRORS,
  REPEAT_FREQUENCIES,
  removeChecklistItem,
  repeatFrequencyLabel,
  rotationEditorEntries,
  saveButtonTitle,
  setFrequency,
  setInterval,
  setRotationEnabled,
  showsChecklist,
  showsRotation,
  TASK_EDITOR_TEXTS,
  toggleAssignee,
  toggleRotationMember,
  toggleWeekday,
  validateEditor,
  weekdayOptions,
  type EditorErrors,
  type TaskEditorState,
} from '@/core/taskEditor';
import { tasks } from '@/data/api';
import { applyTaskUpdate, keys, useMembers, useMyGroups, useTask } from '@/data/queries';
import { useUserId } from '@/data/session';
import { Avatar, CapsuleButton, Card, ErrorText, IconTile, Loading, SegmentedPill, tap } from '@/ui/components';
import { DueDatePicker } from '@/ui/DueDatePicker';
import { radius, type as typo, useTheme } from '@/ui/theme';

/**
 * « Nouvelle tâche » (params `groupId`) / « Modifier la tâche » (params `taskId`), a sheet (docs/DESIGN-V2.md §7.7):
 * Titre + Description, Quand (échéance, répétition), Qui s’en occupe ? (assignees or « À tour de rôle »), Checklist
 * (creation only), Priorité.
 */
export default function TaskEditorSheet() {
  const params = useLocalSearchParams<{ groupId?: string; taskId?: string }>();
  if (params.taskId) return <EditLoader taskId={params.taskId} />;
  return <Editor task={null} groupId={params.groupId ?? ''} />;
}

/** Edit mode: the task (from the cache while it is read again), then the editor. */
function EditLoader({ taskId }: { taskId: string }) {
  const task = useTask(taskId);
  if (!task.data) {
    return (
      <SheetFrame title={TASK_EDITOR_TEXTS.editTitle}>
        {task.error ? <ErrorText message={errorMessage(task.error)} /> : <Loading />}
      </SheetFrame>
    );
  }
  return <Editor key={task.data.id} task={task.data} groupId={task.data.groupId} />;
}

function SheetFrame({ title, children }: { title: string; children: ReactNode }) {
  const theme = useTheme();
  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      <SheetHeader title={title} left={<CapsuleButton title="Annuler" onPress={() => router.back()} />} right={<View style={{ width: 90 }} />} />
      <View style={{ padding: 20 }}>{children}</View>
    </View>
  );
}

function SheetHeader({ title, left, right }: { title: string; left: ReactNode; right: ReactNode }) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  // A modal sheet on iOS starts below the status bar.
  const top = Platform.OS === 'ios' ? 14 : insets.top + 8;
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, paddingTop: top, paddingBottom: 8, paddingHorizontal: 16 }}>
      <View style={{ flex: 1, alignItems: 'flex-start' }}>{left}</View>
      <Text accessibilityRole="header" numberOfLines={1} style={[typo.headline, { color: theme.textPrimary, flexShrink: 1, textAlign: 'center' }]}>
        {title}
      </Text>
      <View style={{ flex: 1, alignItems: 'flex-end' }}>{right}</View>
    </View>
  );
}

function Editor({ task, groupId }: { task: TaskItem | null; groupId: string }) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const client = useQueryClient();
  const navigation = useNavigation();
  const userId = useUserId();
  const calendar = useMemo(() => FrenchCalendar.device(), []);
  const members = useMembers(groupId || null);
  const myGroups = useMyGroups();
  const role = myGroups.data?.find((summary) => summary.group.id === groupId)?.myRole ?? null;
  const memberList = useMemo(() => members.data ?? [], [members.data]);

  const [state, setState] = useState<TaskEditorState>(() =>
    makeEditorState(task ? { kind: 'edit', task } : { kind: 'create', groupId }, Date.now(), calendar),
  );
  const [errors, setErrors] = useState<EditorErrors>(NO_EDITOR_ERRORS);
  const [error, setError] = useState<string | null>(null);
  const [checklistDraft, setChecklistDraft] = useState('');
  const [saving, setSaving] = useState(false);
  const saved = useRef(false);

  // The people who left can be neither assigned nor unselected: drop them once the members are known.
  useEffect(() => {
    if (members.data) {
      setState((current) => {
        const kept = keepingMembers(current, members.data);
        return kept.rotationEnabled && kept.rotation.length === 0 ? setRotationEnabled(kept, true, members.data) : kept;
      });
    }
  }, [members.data]);

  const allowed = members.data === undefined && myGroups.data === undefined ? true : task ? canEditTask(task, userId, role) : canCreateTask(role);
  const changed = hasChanges(state);
  const hasChangesRef = useRef(changed);
  hasChangesRef.current = changed;

  // A sheet with changes cannot be swiped away: « Annuler » asks first.
  useEffect(() => {
    navigation.setOptions({ gestureEnabled: !changed && !saving });
  }, [navigation, changed, saving]);

  // Ask before discarding changes (swipe down, back button).
  useEffect(() => {
    return navigation.addListener('beforeRemove', (event) => {
      if (saved.current || !hasChangesRef.current) return;
      event.preventDefault();
      confirmDiscard(() => navigation.dispatch(event.data.action));
    });
  }, [navigation]);

  const update = (next: TaskEditorState) => setState(next);

  const save = async () => {
    if (saving || !allowed) return;
    const checked = validateEditor(state);
    setErrors(checked);
    setError(null);
    if (hasEditorErrors(checked)) return;
    setSaving(true);
    try {
      const draft = editorDraft(state);
      const result = task ? await tasks.update(task.id, draft) : await tasks.create(groupId, draft);
      applyTaskUpdate(client, result);
      void client.invalidateQueries({ queryKey: keys.group(groupId) });
      saved.current = true;
      router.back();
    } catch (caught) {
      const field = editorErrorField(caught);
      if (field) {
        setErrors({ ...NO_EDITOR_ERRORS, [field]: errorMessage(caught) });
        if (AppError.isAppError(caught) && (caught.kind === 'assigneeNotMember' || caught.kind === 'invalidRotation')) {
          const fresh = await members.refetch();
          if (fresh.data) {
            const memberIds = new Set(fresh.data.map((member) => member.user.id));
            setState((current) => ({
              ...keepingMembers(current, fresh.data),
              rotation: current.rotation.filter((id) => memberIds.has(id)),
            }));
          }
        }
      } else if (AppError.isAppError(caught) && caught.kind === 'notFound' && task) {
        setError(TASK_EDITOR_TEXTS.gone);
      } else {
        setError(errorMessage(caught));
      }
    } finally {
      setSaving(false);
    }
  };

  const recurring = isRecurring(state);
  const summary = editorRecurrenceSummary(state);
  const upcoming = recurring ? editorUpcomingTexts(state, Date.now(), calendar) : [];
  const rotationOn = showsRotation(state);
  const dueMissing = recurring && !state.hasDueDate ? new AppError('recurrenceNeedsDueDate').messageFR : null;

  return (
    <KeyboardAvoidingView style={{ flex: 1, backgroundColor: theme.background }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
      <SheetHeader
        title={editorTitle(state)}
        left={<CapsuleButton title="Annuler" disabled={saving} onPress={() => router.back()} />}
        right={
          <CapsuleButton
            title={saveButtonTitle(state)}
            bold
            loading={saving}
            disabled={!canSave(state) || !allowed}
            onPress={() => void save()}
          />
        }
      />
      <ScrollView
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="interactive"
        contentContainerStyle={{ paddingHorizontal: 20, paddingTop: 8, paddingBottom: insets.bottom + 40, gap: 10 }}
      >
        {!allowed ? (
          <View style={{ flexDirection: 'row', gap: 8, alignItems: 'center', padding: 12 }}>
            <Ionicons name="lock-closed" size={16} color={theme.textSecondary} />
            <Text style={[typo.subheadline, { color: theme.textSecondary }]}>Tu ne peux pas modifier cette tâche.</Text>
          </View>
        ) : null}
        <ErrorText message={error} />

        <Label>Titre</Label>
        <TextInput
          value={state.title}
          onChangeText={(title) => {
            update({ ...state, title });
            if (errors.title) setErrors({ ...errors, title: null });
          }}
          placeholder="Titre de la tâche"
          placeholderTextColor={theme.textTertiary}
          maxLength={Limits.taskTitle.max + 20}
          autoFocus={!task}
          returnKeyType="next"
          style={[typo.body, inputStyle(theme.card, theme.textPrimary)]}
        />
        <FieldError message={errors.title} />

        <Label>Description</Label>
        <TextInput
          value={state.details}
          onChangeText={(details) => {
            update({ ...state, details });
            if (errors.details) setErrors({ ...errors, details: null });
          }}
          placeholder="Ajoute des précisions (facultatif)"
          placeholderTextColor={theme.textTertiary}
          multiline
          textAlignVertical="top"
          style={[typo.body, inputStyle(theme.card, theme.textPrimary), { minHeight: 120, paddingTop: 16 }]}
        />
        <FieldError message={errors.details} />

        <Label>Quand</Label>
        <Card style={{ gap: 14 }}>
          <ToggleRow
            icon="calendar"
            title="Échéance"
            subtitle={recurring ? TASK_EDITOR_TEXTS.dueDateRequired : null}
            value={state.hasDueDate}
            onChange={(hasDueDate) => update({ ...state, hasDueDate })}
          />
          {state.hasDueDate ? <DueDatePicker value={state.dueDate} calendar={calendar} onChange={(dueDate) => update({ ...state, dueDate })} /> : null}
          <FieldError message={errors.dueDate ?? dueMissing} />

          <View style={{ height: 1, backgroundColor: theme.hairline }} />
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
            <IconTile icon="sync" />
            <Text style={[typo.body, { color: theme.textPrimary, fontWeight: '600' }]}>Répéter</Text>
          </View>
          <SegmentedPill
            options={REPEAT_FREQUENCIES.map((key) => ({ key, label: repeatFrequencyLabel(key) }))}
            value={state.frequency}
            onChange={(frequency) => update(setFrequency(state, frequency))}
            tone={() => ({ bg: theme.accentFill, text: '#FFF' })}
            track={theme.hairline}
          />
          {state.frequency !== 'never' ? (
            <>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
                <Text style={[typo.body, { color: theme.textPrimary, flex: 1 }]}>
                  {recurrenceSummaryOf(state.frequency, state.interval)}
                </Text>
                <Stepper
                  value={state.interval}
                  min={1}
                  max={Limits.repeatIntervalMax}
                  onChange={(interval) => update(setInterval(state, interval))}
                />
              </View>
              {state.frequency === 'weekly' ? (
                <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
                  {weekdayOptions(state).map((option) => (
                    <Pressable
                      key={option.id}
                      accessibilityRole="button"
                      accessibilityLabel={option.name}
                      accessibilityState={{ selected: option.isSelected }}
                      onPress={() => {
                        tap();
                        update(toggleWeekday(state, option.id));
                      }}
                      style={{
                        width: 44,
                        height: 44,
                        borderRadius: 22,
                        alignItems: 'center',
                        justifyContent: 'center',
                        backgroundColor: option.isSelected ? theme.accentFill : theme.track,
                      }}
                    >
                      <Text style={{ fontSize: 16, fontWeight: '800', color: option.isSelected ? '#FFF' : theme.textSecondary }}>{option.letter}</Text>
                    </Pressable>
                  ))}
                </View>
              ) : null}
              <View style={{ gap: 4, backgroundColor: theme.accentSoft.bg, borderRadius: 14, padding: 12 }}>
                {summary ? <Text style={[typo.subheadline, { color: theme.accentSoft.text, fontWeight: '700' }]}>{summary}</Text> : null}
                {upcoming.length > 0 ? (
                  <Text style={[typo.footnote, { color: theme.textPrimary }]}>
                    {`${TASK_EDITOR_TEXTS.upcomingTitle}\u{a0}: ${upcoming.join(' · ')}`}
                  </Text>
                ) : null}
                <Text style={[typo.footnote, { color: theme.textSecondary }]}>{TASK_EDITOR_TEXTS.recurrenceHint}</Text>
              </View>
            </>
          ) : null}
          <FieldError message={errors.recurrence} />
        </Card>

        <Label>{'Qui s’en occupe\u{a0}?'}</Label>
        <Card style={{ gap: 12 }}>
          {canUseRotation(state) ? (
            <>
              <ToggleRow
                icon="people"
                title={TASK_EDITOR_TEXTS.rotationTitle}
                subtitle={TASK_EDITOR_TEXTS.rotationSubtitle}
                value={state.rotationEnabled}
                onChange={(enabled) => update(setRotationEnabled(state, enabled, memberList))}
              />
              <View style={{ height: 1, backgroundColor: theme.hairline }} />
            </>
          ) : null}
          {members.isPending ? <Loading /> : null}
          {members.error && !members.data ? <ErrorText message={errorMessage(members.error)} /> : null}
          {rotationOn ? (
            <RotationList state={state} onChange={update} onError={(message) => setErrors({ ...errors, rotation: message })} />
          ) : (
            assigneeOptions(state, memberList, userId).map((option) => (
              <Pressable
                key={option.id}
                accessibilityRole="checkbox"
                accessibilityState={{ checked: option.isSelected }}
                onPress={() => {
                  tap();
                  const result = toggleAssignee(state, option.id);
                  update(result.state);
                  setErrors({ ...errors, assignees: result.error });
                }}
                style={{ flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 48 }}
              >
                <AvatarFor id={option.id} members={memberList} />
                <View style={{ flex: 1 }}>
                  <Text style={[typo.body, { color: theme.textPrimary }]}>{option.name}</Text>
                  {option.isAdmin ? <Text style={[typo.footnote, { color: theme.textSecondary }]}>Admin</Text> : null}
                </View>
                <Ionicons
                  name={option.isSelected ? 'checkmark-circle' : 'ellipse-outline'}
                  size={26}
                  color={option.isSelected ? theme.accent : theme.textTertiary}
                />
              </Pressable>
            ))
          )}
          <FieldError message={errors.rotation ?? errors.assignees} />
        </Card>

        {showsChecklist(state) ? (
          <>
            <Label>{TASK_EDITOR_TEXTS.checklistTitle}</Label>
            <Card style={{ gap: 6 }}>
              {state.checklist.map((item) => (
                <View key={item.key} style={{ flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 44 }}>
                  <View style={{ width: 22, height: 22, borderRadius: 7, borderWidth: 2, borderColor: theme.trackStrong }} />
                  <Text style={[typo.body, { flex: 1, color: theme.textPrimary }]}>{item.title}</Text>
                  <Pressable
                    accessibilityRole="button"
                    accessibilityLabel={`Retirer «\u{a0}${item.title}\u{a0}»`}
                    hitSlop={10}
                    onPress={() => update(removeChecklistItem(state, item.key))}
                  >
                    <Ionicons name="remove-circle" size={22} color={theme.danger.text} />
                  </Pressable>
                </View>
              ))}
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
                <Ionicons name="add-circle" size={24} color={theme.accent} />
                <TextInput
                  value={checklistDraft}
                  onChangeText={(text) => {
                    setChecklistDraft(text);
                    if (errors.checklist) setErrors({ ...errors, checklist: null });
                  }}
                  placeholder={TASK_EDITOR_TEXTS.addChecklistItem}
                  placeholderTextColor={theme.textTertiary}
                  returnKeyType="done"
                  blurOnSubmit={false}
                  onSubmitEditing={() => {
                    if (checklistDraft.trim() === '') return;
                    const result = addChecklistItem(state, checklistDraft);
                    update(result.state);
                    setErrors({ ...errors, checklist: result.error });
                    if (!result.error) setChecklistDraft('');
                  }}
                  style={[typo.body, { flex: 1, color: theme.textPrimary, minHeight: 44 }]}
                />
              </View>
              <FieldError message={errors.checklist} />
            </Card>
          </>
        ) : null}

        <Label>Priorité</Label>
        <Card>
          <SegmentedPill
            options={PRIORITY_PICKER_ORDER.map((key) => ({ key, label: priorityLabel(key) }))}
            value={state.priority}
            onChange={(priority: TaskPriority) => update({ ...state, priority })}
          />
        </Card>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

function confirmDiscard(discard: () => void) {
  if (Platform.OS === 'web') return discard();
  Alert.alert(TASK_EDITOR_TEXTS.discardTitle, TASK_EDITOR_TEXTS.discardMessage, [
    { text: 'Continuer la saisie', style: 'cancel' },
    { text: 'Abandonner', style: 'destructive', onPress: discard },
  ]);
}

function inputStyle(background: string, color: string) {
  return {
    backgroundColor: background,
    color,
    borderRadius: radius.card,
    paddingHorizontal: 18,
    minHeight: 60,
  } as const;
}

function Label({ children }: { children: ReactNode }) {
  const theme = useTheme();
  return <Text style={{ fontSize: 17, fontWeight: '600', color: theme.textSecondary, marginTop: 12, marginLeft: 18 }}>{children}</Text>;
}

function FieldError({ message }: { message: string | null | undefined }) {
  const theme = useTheme();
  if (!message) return null;
  return (
    <View style={{ flexDirection: 'row', gap: 6, paddingHorizontal: 4 }}>
      <Ionicons name="alert-circle" size={16} color={theme.danger.text} style={{ marginTop: 1 }} />
      <Text style={[typo.footnote, { color: theme.danger.text, flex: 1 }]}>{message}</Text>
    </View>
  );
}

function ToggleRow({
  icon,
  title,
  subtitle,
  value,
  onChange,
}: {
  icon: 'calendar' | 'people';
  title: string;
  subtitle?: string | null;
  value: boolean;
  onChange: (value: boolean) => void;
}) {
  const theme = useTheme();
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 44 }}>
      <IconTile icon={icon} />
      <View style={{ flex: 1 }}>
        <Text style={[typo.body, { color: theme.textPrimary, fontWeight: '600' }]}>{title}</Text>
        {subtitle ? <Text style={[typo.footnote, { color: theme.textSecondary }]}>{subtitle}</Text> : null}
      </View>
      <Switch
        accessibilityLabel={title}
        value={value}
        onValueChange={onChange}
        trackColor={{ true: theme.accentFill, false: theme.trackStrong }}
        thumbColor="#FFFFFF"
        ios_backgroundColor={theme.trackStrong}
      />
    </View>
  );
}

function Stepper({ value, min, max, onChange }: { value: number; min: number; max: number; onChange: (value: number) => void }) {
  const theme = useTheme();
  const button = (icon: 'remove' | 'add', next: number, disabled: boolean, label: string) => (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      disabled={disabled}
      onPress={() => {
        tap();
        onChange(next);
      }}
      style={{ width: 44, height: 36, alignItems: 'center', justifyContent: 'center', opacity: disabled ? 0.35 : 1 }}
    >
      <Ionicons name={icon} size={20} color={theme.textPrimary} />
    </Pressable>
  );
  return (
    <View
      accessibilityRole="adjustable"
      accessibilityValue={{ min, max, now: value }}
      style={{ flexDirection: 'row', alignItems: 'center', backgroundColor: theme.track, borderRadius: 10 }}
    >
      {button('remove', value - 1, value <= min, 'Moins')}
      <View style={{ width: 1, height: 18, backgroundColor: theme.trackStrong }} />
      {button('add', value + 1, value >= max, 'Plus')}
    </View>
  );
}

function AvatarFor({ id, members }: { id: string; members: readonly Membership[] }) {
  const member = members.find((item) => item.user.id === id);
  if (!member) return null;
  return <Avatar appearance={profileAppearance(member.user)} size={36} />;
}

/** « À tour de rôle »: the ordered list (number, avatar, name, badge, up/down), then the members to add. */
function RotationList({
  state,
  onChange,
  onError,
}: {
  state: TaskEditorState;
  onChange: (state: TaskEditorState) => void;
  onError: (message: string | null) => void;
}) {
  const theme = useTheme();
  const userId = useUserId();
  const groupId = state.mode.kind === 'edit' ? state.mode.task.groupId : state.mode.groupId;
  const members = useMembers(groupId).data ?? [];
  const entries = rotationEditorEntries(state, members, userId);
  const included = entries.filter((entry) => entry.isIncluded);
  const others = entries.filter((entry) => !entry.isIncluded);
  const toggle = (id: string) => {
    tap();
    const result = toggleRotationMember(state, id, members);
    onChange(result.state);
    onError(result.error);
  };
  const move = (id: string, offset: number) => {
    tap();
    onChange(moveRotationMember(state, id, offset, members));
    onError(null);
  };
  return (
    <View style={{ gap: 4 }}>
      {included.map((entry, index) => (
        <View key={entry.person.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 52 }}>
          <Text style={{ width: 18, textAlign: 'center', fontFamily: 'Nunito_900Black', fontSize: 16, color: theme.textSecondary }}>{entry.position}</Text>
          <Avatar appearance={entry.person.appearance} size={36} highlight={entry.badge ? theme.accent : undefined} />
          <View style={{ flex: 1, gap: 2 }}>
            <Text style={[typo.body, { color: theme.textPrimary }]} numberOfLines={1}>
              {entry.person.isMe ? 'Toi' : entry.person.shortName}
            </Text>
            {entry.badge ? (
              <View style={{ alignSelf: 'flex-start', backgroundColor: theme.accentSoft.bg, borderRadius: 999, paddingHorizontal: 8, paddingVertical: 2 }}>
                <Text style={{ fontSize: 12, fontWeight: '700', color: theme.accentSoft.text }}>{entry.badge}</Text>
              </View>
            ) : null}
          </View>
          <IconButton icon="chevron-up" label={`Monter ${entry.person.shortName}`} disabled={index === 0} onPress={() => move(entry.person.id, -1)} />
          <IconButton
            icon="chevron-down"
            label={`Descendre ${entry.person.shortName}`}
            disabled={index === included.length - 1}
            onPress={() => move(entry.person.id, 1)}
          />
          <IconButton icon="remove-circle" color={theme.danger.text} label={`Retirer ${entry.person.shortName}`} onPress={() => toggle(entry.person.id)} />
        </View>
      ))}
      {others.length > 0 ? <View style={{ height: 1, backgroundColor: theme.hairline, marginVertical: 4 }} /> : null}
      {others.map((entry) => (
        <Pressable
          key={entry.person.id}
          accessibilityRole="button"
          accessibilityLabel={`Ajouter ${entry.person.shortName}`}
          onPress={() => toggle(entry.person.id)}
          style={{ flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 48, opacity: 0.8 }}
        >
          <View style={{ width: 18 }} />
          <Avatar appearance={entry.person.appearance} size={36} />
          <Text style={[typo.body, { flex: 1, color: theme.textSecondary }]}>{entry.person.isMe ? 'Toi' : entry.person.shortName}</Text>
          <Ionicons name="add-circle" size={24} color={theme.accent} />
        </Pressable>
      ))}
    </View>
  );
}

function IconButton({
  icon,
  label,
  onPress,
  disabled,
  color,
}: {
  icon: 'chevron-up' | 'chevron-down' | 'remove-circle';
  label: string;
  onPress: () => void;
  disabled?: boolean;
  color?: string;
}) {
  const theme = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      disabled={disabled}
      onPress={onPress}
      style={{ width: 36, height: 44, alignItems: 'center', justifyContent: 'center', opacity: disabled ? 0.3 : 1 }}
    >
      <Ionicons name={icon} size={22} color={color ?? theme.textSecondary} />
    </Pressable>
  );
}
