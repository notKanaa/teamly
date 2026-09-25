import AsyncStorage from '@react-native-async-storage/async-storage';
import { Ionicons } from '@expo/vector-icons';
import { router, useFocusEffect } from 'expo-router';
import { useCallback, useMemo, useRef, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { errorMessage } from '@/core/appError';
import { FrenchCalendar } from '@/core/calendar';
import { resolvedColor } from '@/core/colorKey';
import {
  DAY_SUMMARY_TITLE,
  dayFraction,
  dayNewText,
  dayOverdueText,
  dayRingText,
  daySubtitle,
  daySummary,
  doneTodayRows,
  doneTodayText,
  lastSeenKey,
  MY_TASKS_EMPTY_MESSAGE,
  MY_TASKS_EMPTY_TITLE,
  myTaskSections,
  seenMark,
  todayText,
  type MyTasksContext,
} from '@/core/myTasks';
import { nextStatus, type TaskRow } from '@/core/presentation';
import { tasks } from '@/data/api';
import { useMyTasks, useTaskMutation } from '@/data/queries';
import { useUserId } from '@/data/session';
import { Card, Chip, EmptyState, ErrorText, Loading, ProgressRing, TaskRowCard } from '@/ui/components';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

/** « Mes tâches » with « Ta journée » (screenshot 04-mes-taches). */
export default function MyTasksScreen() {
  const theme = useTheme();
  const userId = useUserId();
  const myTasks = useMyTasks();
  const calendar = useMemo(() => FrenchCalendar.device(), []);
  const [lastSeenAt, setLastSeenAt] = useState<number | null>(null);
  const [showDone, setShowDone] = useState(false);
  const latest = useRef<readonly import('@/core/models').TaskItem[]>([]);
  latest.current = myTasks.data ?? [];

  // « Nouveau »: tasks assigned since the last visit; the mark moves when the user leaves the tab.
  useFocusEffect(
    useCallback(() => {
      if (!userId) return;
      AsyncStorage.getItem(lastSeenKey(userId))
        .then((value) => setLastSeenAt(value === null ? null : Number(value)))
        .catch(() => undefined);
      return () => {
        void AsyncStorage.setItem(lastSeenKey(userId), String(seenMark(latest.current, Date.now()))).catch(() => undefined);
      };
    }, [userId]),
  );

  const statusMutation = useTaskMutation((args: { id: string; status: 'todo' | 'in_progress' | 'done' }) =>
    tasks.setStatus(args.id, args.status),
  );

  const now = Date.now();
  const context: MyTasksContext | null = myTasks.data ? { tasks: myTasks.data, userId, lastSeenAt, now, calendar } : null;
  const summary = context ? daySummary(context) : null;
  const sections = context ? myTaskSections(context, false) : [];
  const doneRows = context ? doneTodayRows(context) : [];
  const doneText = doneTodayText(doneRows.length);

  const renderRow = (row: TaskRow) => (
    <TaskRowCard
      key={row.id}
      row={row}
      color={row.groupAppearance?.color ?? resolvedColor(null, row.task.groupId)}
      onPress={() => router.push(`/task/${row.id}`)}
      onToggleStatus={() => statusMutation.mutate({ id: row.id, status: nextStatus(row.status) })}
    />
  );

  return (
    <Screen refreshing={myTasks.isRefetching} onRefresh={() => void myTasks.refetch()}>
      <View>
        <Text style={[typo.subheadline, { color: theme.textSecondary, fontWeight: '600' }]}>{todayText(now, calendar)}</Text>
        <Text style={[typo.largeTitle, { color: theme.textPrimary }]}>Mes tâches</Text>
      </View>

      {summary ? (
        <Card style={{ flexDirection: 'row', alignItems: 'center', gap: 16 }}>
          <ProgressRing fraction={dayFraction(summary)} color={theme.accentFill}>
            <Text style={{ fontFamily: 'Nunito_900Black', fontSize: 18, color: theme.textPrimary }}>{dayRingText(summary)}</Text>
          </ProgressRing>
          <View style={{ flex: 1, gap: 6 }}>
            <Text style={[typo.title3, { color: theme.textPrimary }]}>{DAY_SUMMARY_TITLE}</Text>
            <Text style={[typo.subheadline, { color: theme.textSecondary }]}>{daySubtitle(summary)}</Text>
            <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
              {dayOverdueText(summary) ? <Chip soft={theme.danger} icon="alert-circle" label={dayOverdueText(summary) ?? ''} /> : null}
              {dayNewText(summary) ? <Chip soft={theme.accentSoft} icon="sparkles" label={dayNewText(summary) ?? ''} /> : null}
            </View>
          </View>
        </Card>
      ) : null}

      {myTasks.isPending ? <Loading /> : null}
      {myTasks.error ? <ErrorText message={errorMessage(myTasks.error)} /> : null}
      {statusMutation.error ? <ErrorText message={errorMessage(statusMutation.error)} /> : null}

      {context && sections.length === 0 && doneRows.length === 0 ? (
        <EmptyState icon="checkmark-circle" title={MY_TASKS_EMPTY_TITLE} message={MY_TASKS_EMPTY_MESSAGE} />
      ) : null}

      {sections.map((section) => (
        <View key={section.bucket} style={{ gap: 10 }}>
          <Text style={[typo.title3, { color: section.bucket === 'overdue' ? theme.danger.text : theme.textPrimary }]}>
            {section.title}
          </Text>
          {section.rows.map(renderRow)}
        </View>
      ))}

      {doneText ? (
        <View style={{ gap: 10 }}>
          <Pressable
            onPress={() => setShowDone((value) => !value)}
            style={{ flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 44 }}
          >
            <Ionicons name="checkmark-circle" size={20} color={theme.fill.green} />
            <Text style={[typo.headline, { color: theme.textSecondary, flex: 1 }]}>{doneText}</Text>
            <Ionicons name={showDone ? 'chevron-up' : 'chevron-down'} size={18} color={theme.textSecondary} />
          </Pressable>
          {showDone ? doneRows.map(renderRow) : null}
        </View>
      ) : null}
    </Screen>
  );
}
