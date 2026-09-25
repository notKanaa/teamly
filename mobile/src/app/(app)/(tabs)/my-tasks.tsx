import { Ionicons } from '@expo/vector-icons';
import { useQuery } from '@tanstack/react-query';
import { router, useFocusEffect } from 'expo-router';
import { useCallback, useMemo, useRef, useState } from 'react';
import { Pressable, Text, View } from 'react-native';
import Animated from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { errorMessage } from '@/core/appError';
import { FrenchCalendar } from '@/core/calendar';
import type { TaskItem, TaskStatus } from '@/core/models';
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
  MY_TASKS_EMPTY_MESSAGE,
  MY_TASKS_EMPTY_TITLE,
  myTaskSections,
  seenMark,
  todayText,
  type MyTasksContext,
} from '@/core/myTasks';
import { nextStatus, type TaskRow } from '@/core/presentation';
import type { DueBucket } from '@/core/taskList';
import { tasks } from '@/data/api';
import { markSeen, useLastSeen } from '@/data/lastSeen';
import { keys, useMyTasks, useTaskMutation } from '@/data/queries';
import { useUserId } from '@/data/session';
import {
  Card,
  Chip,
  CircleIconButton,
  EmptyState,
  ErrorText,
  Loading,
  MyTaskRowCard,
  ProgressRing,
  SecondaryButton,
  SectionTitle,
  tap,
  type IconName,
} from '@/ui/components';
import { fadeIn, fadeOut, listLayout, PressableScale, useListEntering } from '@/ui/motion';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

const SECTION_ICONS: Record<DueBucket, IconName> = {
  overdue: 'alert-circle-outline',
  today: 'sunny-outline',
  thisWeek: 'calendar-outline',
  later: 'calendar-number-outline',
  noDueDate: 'file-tray-outline',
  done: 'checkmark-circle-outline',
};

const SHOW_DONE_LABEL = 'Afficher les terminées';

/** « Mes tâches » with « Ta journée » (screenshot 07-mes-taches, docs/DESIGN-V2.md §7.3). */
export default function MyTasksScreen() {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const userId = useUserId();
  const myTasks = useMyTasks();
  const calendar = useMemo(() => FrenchCalendar.device(), []);
  const lastSeenAt = useLastSeen(userId);
  const [includeDone, setIncludeDone] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [showDoneToday, setShowDoneToday] = useState(false);
  // « Terminées »: every done task, read only while shown.
  const allTasks = useQuery({ queryKey: [...keys.myTasks, 'all'], queryFn: () => tasks.mine(0), enabled: includeDone });
  const source = includeDone ? allTasks : myTasks;
  const latest = useRef<readonly TaskItem[] | null>(null);
  latest.current = myTasks.data ?? null;

  // « Nouveau »: tasks assigned since the last visit; the mark moves when the user leaves the tab, once shown.
  useFocusEffect(
    useCallback(() => {
      return () => {
        if (userId && latest.current !== null) markSeen(userId, seenMark(latest.current, Date.now()));
      };
    }, [userId]),
  );

  const statusMutation = useTaskMutation((args: { id: string; status: TaskStatus }) => tasks.setStatus(args.id, args.status));
  const busyId = statusMutation.isPending ? statusMutation.variables?.id : undefined;

  const now = Date.now();
  const data = source.data ?? (includeDone ? myTasks.data : undefined);
  const context: MyTasksContext | null =
    data && lastSeenAt !== undefined ? { tasks: data, userId, lastSeenAt, now, calendar } : null;
  const summary = context ? daySummary(context) : null;
  const sections = context ? myTaskSections(context, includeDone) : [];
  const doneRows = context && !includeDone ? doneTodayRows(context) : [];
  const doneText = doneTodayText(doneRows.length);
  const overdueText = summary ? dayOverdueText(summary) : null;
  const newText = summary ? dayNewText(summary) : null;
  const entering = useListEntering(context !== null);

  // Rows rise in one after the other on first show; later ones fade in, leave with a fade, and the rest slide.
  let rowIndex = 0;
  const renderRow = (row: TaskRow) => (
    <Animated.View key={row.id} entering={entering(rowIndex++)} exiting={fadeOut} layout={listLayout}>
      <MyTaskRowCard
        row={row}
        busy={busyId === row.id}
        onPress={() => router.push(`/task/${row.id}`)}
        onToggleStatus={() => statusMutation.mutate({ id: row.id, status: nextStatus(row.status) })}
      />
    </Animated.View>
  );

  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      <Screen refreshing={source.isRefetching} onRefresh={() => void source.refetch()} contentStyle={{ gap: 16 }}>
        <View style={{ flexDirection: 'row', justifyContent: 'flex-end', minHeight: 52 }}>
          <CircleIconButton
            icon={includeDone ? 'options' : 'options-outline'}
            label="Options d’affichage"
            size={52}
            onPress={() => setMenuOpen((open) => !open)}
          />
        </View>
        <View style={{ gap: 2 }}>
          <Text style={[typo.subheadline, { color: theme.textSecondary, fontWeight: '600' }]}>{todayText(now, calendar)}</Text>
          <Text accessibilityRole="header" style={[typo.largeTitle, { color: theme.textPrimary, fontSize: 38, lineHeight: 46 }]}>
            Mes tâches
          </Text>
        </View>

        {summary ? (
          <Card style={{ flexDirection: 'row', alignItems: 'center', gap: 16 }}>
            <ProgressRing fraction={dayFraction(summary)} size={68} stroke={8} color={theme.accentFill}>
              <Text style={{ fontFamily: 'Nunito_900Black', fontSize: 18, color: theme.textPrimary }} adjustsFontSizeToFit numberOfLines={1}>
                {dayRingText(summary)}
              </Text>
            </ProgressRing>
            <View style={{ flex: 1, gap: 6 }}>
              <Text style={[typo.title3, { color: theme.textPrimary }]}>{DAY_SUMMARY_TITLE}</Text>
              <Text style={[typo.subheadline, { color: theme.textSecondary }]}>{daySubtitle(summary)}</Text>
              {overdueText || newText ? (
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
                  {overdueText ? <Chip soft={theme.danger} label={overdueText} /> : null}
                  {newText ? <Chip soft={theme.accentSoft} label={newText} /> : null}
                </View>
              ) : null}
            </View>
          </Card>
        ) : null}

        {source.isPending && !data ? <Loading /> : null}
        {source.error && !data ? (
          <View style={{ gap: 8 }}>
            <ErrorText message={errorMessage(source.error)} />
            <SecondaryButton title="Réessayer" onPress={() => void source.refetch()} />
          </View>
        ) : null}
        {statusMutation.error ? <ErrorText message={errorMessage(statusMutation.error)} /> : null}

        {context && sections.length === 0 && doneRows.length === 0 ? (
          <EmptyState icon="checkmark-circle" title={MY_TASKS_EMPTY_TITLE} message={MY_TASKS_EMPTY_MESSAGE}>
            {!includeDone ? <SecondaryButton title={SHOW_DONE_LABEL} onPress={() => setIncludeDone(true)} /> : null}
          </EmptyState>
        ) : null}

        {sections.map((section) => (
          <Animated.View key={section.bucket} entering={fadeIn} exiting={fadeOut} layout={listLayout} style={{ gap: 12 }}>
            <SectionTitle
              size="small"
              icon={SECTION_ICONS[section.bucket]}
              trailing={section.rows.length}
              color={section.bucket === 'overdue' ? theme.danger.text : undefined}
            >
              {section.title}
            </SectionTitle>
            {section.rows.map(renderRow)}
          </Animated.View>
        ))}

        {doneText ? (
          <Animated.View entering={fadeIn} layout={listLayout} style={{ gap: 12 }}>
            <PressableScale
              accessibilityRole="button"
              accessibilityState={{ expanded: showDoneToday }}
              scaleTo={0.98}
              onPress={() => {
                tap();
                setShowDoneToday((value) => !value);
              }}
              style={[
                { flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 52, paddingHorizontal: 16, borderRadius: 18, backgroundColor: theme.card },
                theme.cardShadow,
              ]}
            >
              <Ionicons name="checkmark-circle" size={22} color={theme.fill.green} />
              <Text style={[typo.headline, { color: theme.textPrimary, flex: 1 }]}>{doneText}</Text>
              <Ionicons name={showDoneToday ? 'chevron-up' : 'chevron-down'} size={18} color={theme.textSecondary} />
            </PressableScale>
            {showDoneToday ? doneRows.map(renderRow) : null}
          </Animated.View>
        ) : null}
      </Screen>

      {menuOpen ? (
        <Pressable style={{ position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 }} onPress={() => setMenuOpen(false)}>
          <Animated.View
            entering={fadeIn}
            style={[
              {
                position: 'absolute',
                right: 20,
                top: insets.top + 76,
                minWidth: 250,
                backgroundColor: theme.card,
                borderRadius: 18,
                paddingVertical: 6,
              },
              theme.raisedShadow,
            ]}
          >
            <Pressable
              accessibilityRole="switch"
              accessibilityState={{ checked: includeDone }}
              onPress={() => {
                tap();
                setIncludeDone((value) => !value);
                setMenuOpen(false);
              }}
              style={({ pressed }) => ({
                flexDirection: 'row',
                alignItems: 'center',
                gap: 12,
                minHeight: 48,
                paddingHorizontal: 16,
                opacity: pressed ? 0.6 : 1,
              })}
            >
              <Ionicons name={includeDone ? 'checkmark' : 'checkmark-circle-outline'} size={20} color={theme.accent} />
              <Text style={[typo.body, { color: theme.textPrimary, flex: 1 }]}>{SHOW_DONE_LABEL}</Text>
            </Pressable>
          </Animated.View>
        </Pressable>
      ) : null}
    </View>
  );
}
