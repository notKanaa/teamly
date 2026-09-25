import { Stack } from 'expo-router';

import { useLiveUpdates, useMyGroups } from '@/data/queries';
import { useUserId } from '@/data/session';
import { useTheme } from '@/ui/theme';

/** The signed-in app: the tabs, and the group and task screens pushed over them. */
export default function AppLayout() {
  const theme = useTheme();
  const userId = useUserId();
  const groups = useMyGroups();
  useLiveUpdates(userId || null, (groups.data ?? []).map((summary) => summary.group.id));

  return (
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: theme.background } }}>
      <Stack.Screen name="(tabs)" />
      <Stack.Screen name="group/[groupId]" />
      <Stack.Screen name="task/[taskId]" />
      <Stack.Screen name="new-group" options={{ presentation: 'modal' }} />
      <Stack.Screen name="new-task" options={{ presentation: 'modal' }} />
    </Stack>
  );
}
