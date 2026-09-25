import { Ionicons } from '@expo/vector-icons';
import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState, type ReactNode } from 'react';
import { Alert, Pressable, Text, TextInput, View } from 'react-native';

import { errorMessage } from '@/core/appError';
import { FrenchCalendar } from '@/core/calendar';
import { resolvedColor } from '@/core/colorKey';
import { relativeDateText } from '@/core/frenchDate';
import type { ChecklistItem, TaskItem, TaskStatus } from '@/core/models';
import { isOverdue } from '@/core/models';
import { canChangeTaskStatus, canDeleteTask, canManageChecklist } from '@/core/permissions';
import {
  checklistProgress,
  MemberDirectory,
  priorityLabel,
  progressFraction,
  progressText,
  statusLabel,
} from '@/core/presentation';
import {
  ADD_CHECKLIST_ITEM_TITLE,
  CHECKLIST_TITLE,
  completedText,
  createdText,
  deleteTaskConfirmationMessage,
  rotationEntries,
  rotationText,
  taskRecurrenceText,
  taskUpcomingDueTexts,
} from '@/core/taskDetail';
import { tasks } from '@/data/api';
import { keys, useMembers, useMyGroups, useTask, useTaskMutation } from '@/data/queries';
import { useUserId } from '@/data/session';
import { Avatar, Card, Chip, ErrorText, Loading, ProgressBar, SegmentedPill, type IconName } from '@/ui/components';
import { Screen } from '@/ui/Screen';
import { prioritySoft, type as typo, useTheme } from '@/ui/theme';

const STATUSES: readonly TaskStatus[] = ['todo', 'in_progress', 'done'];

/** A task (screenshot 07-tache): status, info card, checklist, description. */
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
    return (
      <Screen>
        <BackButton />
        <ErrorText message={errorMessage(task.error)} />
      </Screen>
    );
  }
  if (!task.data) return <Loading />;

  const item = task.data;
  const role = summary?.myRole ?? null;
  const now = Date.now();
  const group = summary?.group ?? null;
  const color = resolvedColor(group?.color ?? item.groupColor, item.groupId);
  const memberList = members.data ?? [];
  const directory = new MemberDirectory(memberList, userId);
  const recurrence = taskRecurrenceText(item);
  const upcoming = taskUpcomingDueTexts(item, now, calendar);
  const rotation = rotationEntries(item, memberList, userId);
  const canStatus = canChangeTaskStatus(item, userId, role);
  const canChecklist = canManageChecklist(item, userId, role);

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

  const remove = () =>
    Alert.alert('Supprimer la tâche', deleteTaskConfirmationMessage(item.title), [
      { text: 'Annuler', style: 'cancel' },
      {
        text: 'Supprimer',
        style: 'destructive',
        onPress: () => {
          tasks
            .delete(taskId)
            .then(() => {
              void client.invalidateQueries({ queryKey: keys.group(item.groupId) });
              void client.invalidateQueries({ queryKey: keys.myTasks });
              router.back();
            })
            .catch((caught: unknown) => setError(errorMessage(caught)));
        },
      },
    ]);

  return (
    <Screen refreshing={task.isRefetching} onRefresh={() => void task.refetch()}>
      <BackButton />
      {group ? (
        <Chip soft={theme.soft[color]} label={`${group.emoji ? `${group.emoji} ` : ''}${group.name}`} />
      ) : item.groupName ? (
        <Chip soft={theme.soft[color]} label={item.groupName} />
      ) : null}
      <Text style={{ fontFamily: 'Nunito_900Black', fontSize: 30, lineHeight: 36, color: theme.textPrimary }}>{item.title}</Text>

      {canStatus ? (
        <SegmentedPill
          options={STATUSES.map((status) => ({ key: status, label: statusLabel(status) }))}
          value={statusMutation.isPending && statusMutation.variables ? statusMutation.variables : item.status}
          onChange={(status) => {
            if (status !== item.status) statusMutation.mutate(status);
          }}
        />
      ) : (
        <Chip soft={theme.accentSoft} label={statusLabel(item.status)} />
      )}
      {statusMutation.error ? <ErrorText message={errorMessage(statusMutation.error)} /> : null}

      <Card padded={false}>
        <InfoRow icon="calendar" color={theme.fill.blue} label="Échéance" first>
          <Text style={[typo.body, { color: isOverdue(item, now) ? theme.danger.text : theme.textPrimary }]}>
            {item.dueAt === null ? 'Aucune' : relativeDateText(item.dueAt, now, calendar)}
          </Text>
        </InfoRow>
        {recurrence ? (
          <InfoRow icon="repeat" color={theme.fill.violet} label="Se répète">
            <Text style={[typo.body, { color: theme.textPrimary }]}>{recurrence}</Text>
            {upcoming.length > 0 ? (
              <Text style={[typo.footnote, { color: theme.textSecondary }]}>Prochaines fois : {upcoming.join(' · ')}</Text>
            ) : null}
          </InfoRow>
        ) : null}
        {rotation.length > 0 ? (
          <InfoRow icon="sync" color={theme.fill.teal} label="À tour de rôle">
            <View style={{ flexDirection: 'row', gap: 6, flexWrap: 'wrap' }}>
              {rotation.map((entry) => (
                <Avatar
                  key={entry.person.id}
                  appearance={entry.person.appearance}
                  size={30}
                  ring={entry.isCurrentTurn ? theme.accent : undefined}
                />
              ))}
            </View>
            <Text style={[typo.footnote, { color: theme.textSecondary }]}>{rotationText(rotation)}</Text>
          </InfoRow>
        ) : null}
        <InfoRow icon="flag" color={theme.fill.orange} label="Priorité">
          <Chip soft={prioritySoft(theme, item.priority)} label={priorityLabel(item.priority)} />
        </InfoRow>
        <InfoRow icon="people" color={theme.fill.indigo} label="Assignées">
          {item.assigneeIds.length === 0 ? (
            <Text style={[typo.body, { color: theme.textSecondary }]}>Personne</Text>
          ) : (
            directory.badges(item.assigneeIds).map((badge) => (
              <View key={badge.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
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
        onDelete={(checklistItem) =>
          runChecklist(async () => {
            updateChecklist((items) => items.filter((entry) => entry.id !== checklistItem.id));
            await tasks.deleteChecklistItem(checklistItem.id);
          })
        }
      />
      <ErrorText message={error} />

      {item.details ? (
        <Card style={{ gap: 6 }}>
          <Text style={[typo.headline, { color: theme.textPrimary }]}>Description</Text>
          <Text style={[typo.body, { color: theme.textPrimary }]}>{item.details}</Text>
        </Card>
      ) : null}

      {members.data ? (
        <Text style={[typo.footnote, { color: theme.textSecondary }]}>
          {createdText(item, memberList, userId, now, calendar)}
          {completedText(item, now, calendar) ? `\n${completedText(item, now, calendar)}` : ''}
        </Text>
      ) : null}

      {canDeleteTask(item, userId, role) ? (
        <Pressable onPress={remove} style={{ minHeight: 48, alignItems: 'center', justifyContent: 'center' }}>
          <Text style={{ fontFamily: 'Nunito_800ExtraBold', fontSize: 16, color: theme.danger.text }}>Supprimer la tâche</Text>
        </Pressable>
      ) : null}
    </Screen>
  );
}

function BackButton() {
  const theme = useTheme();
  return (
    <Pressable
      onPress={() => router.back()}
      style={{
        alignSelf: 'flex-start',
        flexDirection: 'row',
        alignItems: 'center',
        gap: 4,
        backgroundColor: theme.card,
        borderRadius: 999,
        paddingLeft: 8,
        paddingRight: 14,
        height: 38,
        ...theme.cardShadow,
      }}
    >
      <Ionicons name="chevron-back" size={20} color={theme.accent} />
      <Text style={{ fontFamily: 'Nunito_800ExtraBold', fontSize: 15, color: theme.accent }}>Retour</Text>
    </Pressable>
  );
}

function InfoRow({ icon, color, label, children, first }: { icon: IconName; color: string; label: string; children: ReactNode; first?: boolean }) {
  const theme = useTheme();
  return (
    <View style={{ flexDirection: 'row', gap: 12, padding: 14, borderTopWidth: first ? 0 : 1, borderTopColor: theme.hairline }}>
      <View style={{ width: 34, height: 34, borderRadius: 11, backgroundColor: color, alignItems: 'center', justifyContent: 'center' }}>
        <Ionicons name={icon} size={18} color="#FFF" />
      </View>
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
  onDelete,
}: {
  items: readonly ChecklistItem[];
  editable: boolean;
  onToggle: (item: ChecklistItem) => void;
  onAdd: (title: string) => void;
  onDelete: (item: ChecklistItem) => void;
}) {
  const theme = useTheme();
  const [draft, setDraft] = useState('');
  const progress = checklistProgress(items);
  if (!editable && items.length === 0) return null;
  return (
    <Card style={{ gap: 12 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
        <Text style={[typo.title3, { color: theme.textPrimary }]}>{CHECKLIST_TITLE}</Text>
        {progress ? <Text style={[typo.footnote, { color: theme.textSecondary }]}>{progressText(progress)}</Text> : null}
      </View>
      {progress ? <ProgressBar fraction={progressFraction(progress)} color={theme.fill.teal} /> : null}
      {items.map((item) => (
        <View key={item.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 40 }}>
          <Pressable
            accessibilityRole="checkbox"
            accessibilityState={{ checked: item.isDone }}
            disabled={!editable}
            onPress={() => onToggle(item)}
            hitSlop={10}
            style={{
              width: 24,
              height: 24,
              borderRadius: 7,
              borderWidth: item.isDone ? 0 : 2,
              borderColor: theme.textSecondary,
              backgroundColor: item.isDone ? theme.fill.teal : 'transparent',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            {item.isDone ? <Ionicons name="checkmark" size={16} color="#FFF" /> : null}
          </Pressable>
          <Text
            style={[
              typo.body,
              { flex: 1, color: item.isDone ? theme.textSecondary : theme.textPrimary },
              item.isDone && { textDecorationLine: 'line-through' },
            ]}
          >
            {item.title}
          </Text>
          {editable ? (
            <Pressable accessibilityLabel="Supprimer l’élément" hitSlop={10} onPress={() => onDelete(item)}>
              <Ionicons name="close" size={18} color={theme.textSecondary} />
            </Pressable>
          ) : null}
        </View>
      ))}
      {editable ? (
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
          <Ionicons name="add-circle" size={24} color={theme.accent} />
          <TextInput
            value={draft}
            onChangeText={setDraft}
            placeholder={ADD_CHECKLIST_ITEM_TITLE}
            placeholderTextColor={theme.textSecondary}
            returnKeyType="done"
            onSubmitEditing={() => {
              if (draft.trim() === '') return;
              onAdd(draft);
              setDraft('');
            }}
            style={[typo.body, { flex: 1, color: theme.textPrimary, minHeight: 40 }]}
          />
        </View>
      ) : null}
    </Card>
  );
}
