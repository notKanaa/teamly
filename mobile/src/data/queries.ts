import {
  QueryClient,
  useMutation,
  useQuery,
  useQueryClient,
  type QueryKey,
} from '@tanstack/react-query';
import { useEffect } from 'react';
import { AppState } from 'react-native';

import { AppError } from '@/core/appError';
import { FrenchCalendar } from '@/core/calendar';
import type { Instant } from '@/core/calendar';
import type { GroupSummary, TaskItem } from '@/core/models';
import type { Uuid } from '@/core/uuid';
import { recapWeekStart } from '@/core/weeklyRecap';

import { groups, profiles, tasks } from './api';
import { requireSupabase } from './supabase';

// Server state with react-query. Every screen reads through these hooks; Realtime signals (docs/CONTRACTS.md §6)
// invalidate the matching queries, and returning to the foreground refetches.

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: (count, error) => count < 2 && AppError.isAppError(error) && ['network', 'unknown'].includes(error.kind),
    },
  },
});

export const keys = {
  profile: ['profile'] as const,
  groups: ['groups'] as const,
  overviews: (ids: readonly Uuid[]) => ['overviews', [...ids].sort().join(',')] as const,
  group: (groupId: Uuid) => ['group', groupId] as const,
  groupTasks: (groupId: Uuid) => ['group', groupId, 'tasks'] as const,
  members: (groupId: Uuid) => ['group', groupId, 'members'] as const,
  activity: (groupId: Uuid) => ['group', groupId, 'activity'] as const,
  completions: (groupId: Uuid) => ['group', groupId, 'completions'] as const,
  myTasks: ['myTasks'] as const,
  task: (taskId: Uuid) => ['task', taskId] as const,
};

/** Monday 00:00 of the current week, local time: « Cette semaine » of the overviews and « Ta journée ». */
export function weekStart(now: Instant = Date.now()): Instant {
  return recapWeekStart(now, FrenchCalendar.device());
}

export function useProfile(enabled = true) {
  return useQuery({ queryKey: keys.profile, queryFn: profiles.mine, enabled });
}

export function useMyGroups(enabled = true) {
  return useQuery({ queryKey: keys.groups, queryFn: groups.mine, enabled });
}

export function useOverviews(list: readonly GroupSummary[] | undefined) {
  const ids = (list ?? []).map((summary) => summary.group.id);
  return useQuery({
    queryKey: keys.overviews(ids),
    queryFn: async () => {
      const overviews = await groups.overviews(ids, weekStart());
      return new Map(overviews.map((overview) => [overview.groupId, overview]));
    },
    enabled: list !== undefined && ids.length > 0,
  });
}

export function useGroupTasks(groupId: Uuid) {
  return useQuery({ queryKey: keys.groupTasks(groupId), queryFn: () => tasks.ofGroup(groupId) });
}

export function useMembers(groupId: Uuid | null) {
  return useQuery({
    queryKey: keys.members(groupId ?? ''),
    queryFn: () => groups.members(groupId ?? ''),
    enabled: groupId !== null,
  });
}

export function useActivity(groupId: Uuid, enabled = true) {
  return useQuery({ queryKey: keys.activity(groupId), queryFn: () => groups.activity(groupId), enabled });
}

export function useMyTasks() {
  return useQuery({ queryKey: keys.myTasks, queryFn: () => tasks.mine(weekStart()) });
}

export function useTask(taskId: Uuid) {
  const client = useQueryClient();
  return useQuery({
    queryKey: keys.task(taskId),
    queryFn: () => tasks.get(taskId),
    // Show the row of a list right away while the task is read again.
    placeholderData: () => findCachedTask(client, taskId),
  });
}

function findCachedTask(client: QueryClient, taskId: Uuid): TaskItem | undefined {
  for (const [, data] of client.getQueriesData<TaskItem[]>({ predicate: (query) => isTaskList(query.queryKey) })) {
    const task = data?.find((item) => item.id === taskId);
    if (task) return task;
  }
  return undefined;
}

function isTaskList(key: QueryKey): boolean {
  return key[0] === 'myTasks' || (key[0] === 'group' && key[2] === 'tasks');
}

/** Stores a task written by an RPC in every cached list, then refetches the lists touched. */
export function applyTaskUpdate(client: QueryClient, task: TaskItem) {
  client.setQueryData(keys.task(task.id), (previous: TaskItem | undefined) =>
    previous ? { ...previous, ...task, groupName: previous.groupName, groupColor: previous.groupColor, groupEmoji: previous.groupEmoji } : task,
  );
  client.setQueryData<TaskItem[]>(keys.groupTasks(task.groupId), (list) =>
    list?.map((item) => (item.id === task.id ? { ...item, ...task } : item)),
  );
  client.setQueryData<TaskItem[]>(keys.myTasks, (list) =>
    list?.map((item) =>
      item.id === task.id
        ? { ...task, groupName: item.groupName, groupColor: item.groupColor, groupEmoji: item.groupEmoji, myAssignedAt: item.myAssignedAt, myAssignedBy: item.myAssignedBy }
        : item,
    ),
  );
  void client.invalidateQueries({ queryKey: keys.group(task.groupId) });
  void client.invalidateQueries({ queryKey: keys.myTasks });
  void client.invalidateQueries({ queryKey: ['overviews'] });
}

export function useTaskMutation<Args>(run: (args: Args) => Promise<TaskItem>) {
  const client = useQueryClient();
  return useMutation({ mutationFn: run, onSuccess: (task) => applyTaskUpdate(client, task) });
}

/** Realtime (docs/CONTRACTS.md §6) and foreground refresh, while signed in. */
export function useLiveUpdates(userId: Uuid | null, groupIds: readonly Uuid[]) {
  const client = useQueryClient();
  const idsKey = [...groupIds].slice(0, 60).sort().join(',');

  useEffect(() => {
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') void client.invalidateQueries();
    });
    return () => subscription.remove();
  }, [client]);

  useEffect(() => {
    if (userId === null) return;
    const supabase = requireSupabase();
    const channel = supabase
      .channel(`live-${userId}-${Date.now()}`)
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'groups', filter: `id=in.(${idsKey})` }, (payload) => {
        const groupId = String((payload.new as { id?: string }).id ?? '').toLowerCase();
        void client.invalidateQueries({ queryKey: keys.group(groupId) });
        void client.invalidateQueries({ queryKey: keys.groups });
        void client.invalidateQueries({ queryKey: ['overviews'] });
        void client.invalidateQueries({ queryKey: keys.myTasks });
        void client.invalidateQueries({ queryKey: ['task'] });
      })
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'profiles', filter: `id=eq.${userId}` }, () => {
        void client.invalidateQueries({ queryKey: keys.groups });
        void client.invalidateQueries({ queryKey: keys.profile });
      })
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'task_assignees', filter: `user_id=eq.${userId}` },
        () => void client.invalidateQueries({ queryKey: keys.myTasks }),
      )
      .subscribe((status) => {
        // On (re)connection, reload everything: changes may have been missed.
        if (status === 'SUBSCRIBED') void client.invalidateQueries();
      });
    return () => {
      void supabase.removeChannel(channel);
    };
  }, [client, userId, idsKey]);
}
