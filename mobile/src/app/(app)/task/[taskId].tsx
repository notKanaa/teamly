import { Ionicons } from '@expo/vector-icons';
import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState, type ReactNode } from 'react';
import { Alert, Platform, Pressable, Text, TextInput, View } from 'react-native';

import { AppError, errorMessage } from '@/core/appError';
import { FrenchCalendar } from '@/core/calendar';
import { resolvedColor } from '@/core/colorKey';
import { relativeDateText } from '@/core/frenchDate';
import { validateChecklistItemTitle } from '@/core/inputValidation';
import { isOverdue, TASK_STATUSES, type ChecklistItem, type TaskItem, type TaskStatus } from '@/core/models';
import { canChangeTaskStatus, canDeleteTask, canEditTask, canManageChecklist } from '@/core/permissions';
import {
  checklistProgress,
  MemberDirectory,
  priorityLabel,
  progressFraction,
  progressText,
  statusLabel,
  UNASSIGNED_TEXT,
} from '@/core/presentation';
import {
  ADD_CHECKLIST_ITEM_TITLE,
  CHECKLIST_TITLE,
  completedText,
  createdText,
  deleteTaskConfirmationMessage,
  rotationEntries,
  rotationText,
  TASK_GONE_MESSAGE,
  taskRecurrenceText,
  taskUpcomingDueTexts,
  UPCOMING_TITLE,
} from '@/core/taskDetail';
import { tasks } from '@/data/api';
import { keys, useMembers, useMyGroups, useTask, useTaskMutation } from '@/data/queries';
import { useUserId } from '@/data/session';
import {
  Avatar,
  CapsuleButton,
  Card,
  Chip,
  ErrorText,
  IconTile,
  Loading,
  ProgressBar,
  SegmentedPill,
  tap,
  type IconName,
} from '@/ui/components';
import { Screen } from '@/ui/Screen';
import { colorAccent, prioritySoft, statusSoft, type Soft, type as typo, useTheme } from '@/ui/theme';

/** A task (docs/DESIGN-V2.md §7.6): status, info card, checklist, description, edit and delete. */
export default function TaskScreen() {
  const { taskId = '' } = useLocalSearchParams<{ taskId: string }>();
  const theme = useTheme();
  const userId = useUserId();
  const client = useQueryClient();
  const task = useTask(taskId);
  const groupId = task.data?.groupId ?? null;
  const members = useMembers(groupId);
  const myGroups = useMyGroups();
  const summary = myGroups.data?.find((item) => item.group.id === groupId) ?? null;
  const calendar = useMemo(() => FrenchCalendar.device(), []);
  const statusMutation = useTaskMutation((status: TaskStatus) => tasks.setStatus(taskId, status));
  const [error, setError] = useState<string | null>(null);

  if (task.error && !task.data) {
    const gone = AppError.isAppError(task.error) && task.error.kind === 'notFound';
    return (
      <Screen>
        <BackButton />
        <ErrorText message={gone ? TASK_GONE_MESSAGE : errorMessage(task.error)} />
      </Screen>
    );
  }
  if (!task.data) {
    return (
      <Screen>
        <BackButton />
        <Loading />
      </Screen>
    );
  }

  const item = task.data;
  const role = summary?.myRole ?? null;
  const now = Date.now();
  const group = summary?.group ?? null;
  const color = resolvedColor(group?.color ?? item.groupColor, item.groupId);
  const groupName = group?.name ?? item.groupName;
  const groupEmoji = group?.emoji ?? item.groupEmoji;
  const memberList = members.data ?? [];
  const directory = new MemberDirectory(memberList, userId);
  const recurrence = taskRecurrenceText(item);
  const upcoming = taskUpcomingDueTexts(item, now, calendar);
  const rotation = rotationEntries(item, memberList, userId);
  const canStatus = canChangeTaskStatus(item, userId, role);
  const canChecklist = canManageChecklist(item, userId, role);
  const canEdit = canEditTask(item, userId, role);
  const overdue = isOverdue(item, now);
  const shownStatus = statusMutation.isPending && statusMutation.variables ? statusMutation.variables : item.status;

  const updateChecklist = (update: (items: ChecklistItem[]) => ChecklistItem[]) => {
    client.setQueryData<TaskItem>(keys.task(taskId), (previous) => (previous ? { ...previous, checklist: update(previous.checklist) } : previous));
  };

  const runChecklist = async (action: () => Promise<void>) => {
    setError(null);
    try {
      await action();
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      void client.invalidateQueries({ queryKey: keys.task(taskId) });
      void client.invalidateQueries({ queryKey: keys.group(item.groupId) });
      void client.invalidateQueries({ queryKey: keys.myTasks });
    }
  };

  const deleteTask = () => {
    tasks
      .delete(taskId)
      .then(() => {
        void client.invalidateQueries({ queryKey: keys.group(item.groupId) });
        void client.invalidateQueries({ queryKey: keys.myTasks });
        void client.invalidateQueries({ queryKey: ['overviews'] });
        client.removeQueries({ queryKey: keys.task(taskId) });
        router.back();
      })
      .catch((caught: unknown) => setError(errorMessage(caught)));
  };

  const remove = () => {
    if (Platform.OS === 'web') return deleteTask();
    Alert.alert('Supprimer la tâche\u{a0}?', deleteTaskConfirmationMessage(item.title), [
      { text: 'Annuler', style: 'cancel' },
      { text: 'Supprimer', style: 'destructive', onPress: deleteTask },
    ]);
  };

  const edit = () => router.push({ pathname: '/new-task', params: { taskId } });
  const created = members.data ? createdText(item, memberList, userId, now, calendar) : null;
  const completed = completedText(item, now, calendar);

  return (
    <Screen refreshing={task.isRefetching} onRefresh={() => void task.refetch()} contentStyle={{ gap: 16 }}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
        <BackButton />
        {canEdit ? <CapsuleButton title="Modifier" bold onPress={edit} /> : null}
      </View>

      <View style={{ gap: 10 }}>
        {groupName ? <Chip soft={theme.soft[color]} label={`${groupEmoji ? `${groupEmoji} ` : ''}${groupName}`} /> : null}
        <Text accessibilityRole="header" style={{ fontFamily: 'Nunito_900Black', fontSize: 30, lineHeight: 36, color: theme.textPrimary }}>
          {item.title}
        </Text>
      </View>

      {canStatus ? (
        <SegmentedPill
          options={TASK_STATUSES.map((status) => ({ key: status, label: statusLabel(status) }))}
          value={shownStatus}
          tone={(status) => statusSoft(theme, status)}
          onChange={(status) => {
            if (status !== item.status) statusMutation.mutate(status);
          }}
        />
      ) : (
        <Chip soft={statusSoft(theme, item.status)} label={statusLabel(item.status)} />
      )}
      {statusMutation.error ? <ErrorText message={errorMessage(statusMutation.error)} /> : null}

      <Card padded={false}>
        <InfoRow icon="calendar" soft={overdue ? theme.danger : theme.accentSoft} label="Échéance" first>
          <Text style={[typo.body, { color: overdue ? theme.danger.text : theme.textPrimary, fontWeight: overdue ? '700' : '400' }]}>
            {item.dueAt === null ? 'Aucune échéance' : relativeDateText(item.dueAt, now, calendar)}
          </Text>
        </InfoRow>
        {recurrence ? (
          <InfoRow icon="sync" soft={theme.soft.violet} label="Se répète">
            <Text style={[typo.body, { color: theme.textPrimary }]}>{recurrence}</Text>
            {upcoming.length > 0 ? (
              <Text style={[typo.footnote, { color: theme.textSecondary }]}>{`${UPCOMING_TITLE}\u{a0}: ${upcoming.join(' · ')}`}</Text>
            ) : null}
          </InfoRow>
        ) : null}
        {rotation.length > 0 ? (
          <InfoRow icon="people" soft={theme.soft.teal} label="À tour de rôle">
            <View style={{ flexDirection: 'row', alignItems: 'center', flexWrap: 'wrap', gap: 4, paddingVertical: 2 }}>
              {rotation.map((entry, index) => (
                <View key={entry.person.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
                  {index > 0 ? <Ionicons name="chevron-forward" size={14} color={theme.textTertiary} /> : null}
                  <Avatar
                    appearance={entry.person.appearance}
                    size={30}
                    ring={entry.isCurrentTurn ? theme.card : undefined}
                    highlight={entry.isCurrentTurn ? theme.accent : undefined}
                  />
                </View>
              ))}
            </View>
            <Text style={[typo.footnote, { color: theme.textSecondary }]}>{rotationText(rotation)}</Text>
          </InfoRow>
        ) : null}
        <InfoRow icon="flag" soft={theme.soft.orange} label="Priorité">
          <Chip soft={prioritySoft(theme, item.priority)} icon="flag" label={priorityLabel(item.priority)} />
        </InfoRow>
        <InfoRow icon="person" soft={theme.soft.indigo} label="Assignées">
          {item.assigneeIds.length === 0 ? (
            <Text style={[typo.body, { color: theme.textSecondary }]}>{UNASSIGNED_TEXT}</Text>
          ) : (
            directory.badges(item.assigneeIds).map((badge) => (
              <View key={badge.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 32 }}>
                <Avatar appearance={badge.appearance} size={26} />
                <Text style={[typo.body, { color: theme.textPrimary }]}>{badge.isMe ? 'Toi' : badge.name}</Text>
              </View>
            ))
          )}
        </InfoRow>
      </Card>

      <Checklist
        items={item.checklist}
        editable={canChecklist}
        onToggle={(checklistItem) =>
          runChecklist(async () => {
            tap();
            updateChecklist((items) => items.map((entry) => (entry.id === checklistItem.id ? { ...entry, isDone: !entry.isDone } : entry)));
            await tasks.setChecklistItemDone(checklistItem.id, !checklistItem.isDone);
          })
        }
        onAdd={(title) =>
          runChecklist(async () => {
            const added = await tasks.addChecklistItem(taskId, title);
            updateChecklist((items) => [...items, added]);
          })
        }
        onRename={(checklistItem, title) =>
          runChecklist(async () => {
            updateChecklist((items) => items.map((entry) => (entry.id === checklistItem.id ? { ...entry, title } : entry)));
            await tasks.renameChecklistItem(checklistItem.id, title);
          })
        }
        onDelete={(checklistItem) =>
          runChecklist(async () => {
            updateChecklist((items) => items.filter((entry) => entry.id !== checklistItem.id));
            await tasks.deleteChecklistItem(checklistItem.id);
          })
        }
        onError={setError}
      />
      <ErrorText message={error} />

      {item.details ? (
        <Card style={{ gap: 8 }}>
          <Text style={[typo.title3, { color: theme.textPrimary }]}>Description</Text>
          <Text style={[typo.body, { color: theme.textPrimary }]}>{item.details}</Text>
        </Card>
      ) : null}

      {created || completed ? (
        <View style={{ gap: 4, paddingHorizontal: 4 }}>
          {created ? <Text style={[typo.footnote, { color: theme.textSecondary }]}>{created}</Text> : null}
          {completed ? (
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
              <Ionicons name="checkmark-circle" size={15} color={colorAccent(theme, 'green')} />
              <Text style={[typo.footnote, { color: theme.textSecondary }]}>{completed}</Text>
            </View>
          ) : null}
        </View>
      ) : null}

      {canDeleteTask(item, userId, role) ? (
        <Pressable
          accessibilityRole="button"
          onPress={remove}
          style={({ pressed }) => ({
            minHeight: 48,
            flexDirection: 'row',
            gap: 8,
            alignItems: 'center',
            justifyContent: 'center',
            opacity: pressed ? 0.6 : 1,
          })}
        >
          <Ionicons name="trash-outline" size={18} color={theme.danger.text} />
          <Text style={{ fontSize: 16, fontWeight: '700', color: theme.danger.text }}>Supprimer la tâche</Text>
        </Pressable>
      ) : null}
    </Screen>
  );
}

function BackButton() {
  return (
    <CapsuleButton
      title="Retour"
      icon="chevron-back"
      onPress={() => (router.canGoBack() ? router.back() : router.replace('/my-tasks'))}
    />
  );
}

function InfoRow({ icon, soft, label, children, first }: { icon: IconName; soft: Soft; label: string; children: ReactNode; first?: boolean }) {
  const theme = useTheme();
  return (
    <View style={{ flexDirection: 'row', gap: 12, padding: 14, borderTopWidth: first ? 0 : 1, borderTopColor: theme.hairline }}>
      <IconTile icon={icon} soft={soft} size={32} />
      <View style={{ flex: 1, gap: 4 }}>
        <Text style={[typo.footnote, { color: theme.textSecondary, fontWeight: '600' }]}>{label}</Text>
        {children}
      </View>
    </View>
  );
}

function Checklist({
  items,
  editable,
  onToggle,
  onAdd,
  onRename,
  onDelete,
  onError,
}: {
  items: readonly ChecklistItem[];
  editable: boolean;
  onToggle: (item: ChecklistItem) => void;
  onAdd: (title: string) => void;
  onRename: (item: ChecklistItem, title: string) => void;
  onDelete: (item: ChecklistItem) => void;
  onError: (message: string | null) => void;
}) {
  const theme = useTheme();
  const [draft, setDraft] = useState('');
  const [editing, setEditing] = useState<{ id: string; title: string } | null>(null);
  const progress = checklistProgress(items);
  if (!editable && items.length === 0) return null;
  const teal = colorAccent(theme, 'teal');

  const checkedTitle = (raw: string): string | null => {
    try {
      return validateChecklistItemTitle(raw);
    } catch (caught) {
      onError(errorMessage(caught));
      return null;
    }
  };

  const commitRename = (item: ChecklistItem) => {
    if (!editing) return;
    const title = checkedTitle(editing.title);
    setEditing(null);
    if (title !== null && title !== item.title) onRename(item, title);
  };

  return (
    <Card style={{ gap: 12 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
        <Text accessibilityRole="header" style={[typo.title3, { color: theme.textPrimary }]}>
          {CHECKLIST_TITLE}
        </Text>
        {progress ? <Text style={[typo.headline, { color: teal }]}>{progressText(progress)}</Text> : null}
      </View>
      {progress ? <ProgressBar fraction={progressFraction(progress)} color={theme.fill.teal} track={theme.soft.teal.bg} /> : null}
      {items.map((item) => (
        <View key={item.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 44 }}>
          <Pressable
            accessibilityRole="checkbox"
            accessibilityLabel={item.title}
            accessibilityState={{ checked: item.isDone, disabled: !editable }}
            disabled={!editable}
            onPress={() => onToggle(item)}
            hitSlop={10}
            style={{
              width: 24,
              height: 24,
              borderRadius: 7,
              borderWidth: item.isDone ? 0 : 2,
              borderColor: theme.trackStrong,
              backgroundColor: item.isDone ? theme.fill.teal : 'transparent',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            {item.isDone ? <Ionicons name="checkmark" size={17} color="#FFF" /> : null}
          </Pressable>
          {editing?.id === item.id ? (
            <TextInput
              value={editing.title}
              onChangeText={(title) => setEditing({ id: item.id, title })}
              autoFocus
              returnKeyType="done"
              onSubmitEditing={() => commitRename(item)}
              onBlur={() => commitRename(item)}
              style={[typo.body, { flex: 1, color: theme.textPrimary, minHeight: 40, borderBottomWidth: 1, borderBottomColor: theme.accent }]}
            />
          ) : (
            <Pressable
              style={{ flex: 1, minHeight: 40, justifyContent: 'center' }}
              disabled={!editable}
              onPress={() => onToggle(item)}
              onLongPress={() => {
                tap();
                setEditing({ id: item.id, title: item.title });
              }}
              accessibilityHint={editable ? 'Appui long pour renommer' : undefined}
            >
              <Text
                style={[
                  typo.body,
                  { color: item.isDone ? theme.textSecondary : theme.textPrimary },
                  item.isDone && { textDecorationLine: 'line-through' },
                ]}
              >
                {item.title}
              </Text>
            </Pressable>
          )}
          {editable ? (
            <Pressable accessibilityRole="button" accessibilityLabel={`Supprimer «\u{a0}${item.title}\u{a0}»`} hitSlop={10} onPress={() => onDelete(item)}>
              <Ionicons name="close" size={18} color={theme.textTertiary} />
            </Pressable>
          ) : null}
        </View>
      ))}
      {editable ? (
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
          <Ionicons name="add-circle" size={24} color={theme.accent} />
          <TextInput
            value={draft}
            onChangeText={(text) => {
              setDraft(text);
              onError(null);
            }}
            placeholder={ADD_CHECKLIST_ITEM_TITLE}
            placeholderTextColor={theme.textTertiary}
            returnKeyType="done"
            blurOnSubmit={false}
            onSubmitEditing={() => {
              if (draft.trim() === '') return;
              const title = checkedTitle(draft);
              if (title === null) return;
              onAdd(title);
              setDraft('');
            }}
            style={[typo.body, { flex: 1, color: theme.textPrimary, minHeight: 44 }]}
          />
        </View>
      ) : null}
    </Card>
  );
}
