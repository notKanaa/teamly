import { Stack } from 'expo-router';
import { View } from 'react-native';

import { useOnboardingGate } from '@/data/onboarding';
import { useLiveUpdates, useMyGroups, useProfile } from '@/data/queries';
import { useUserId } from '@/data/session';
import { useNotifications } from '@/notifications/useNotifications';
import { useTheme } from '@/ui/theme';

/**
 * The signed-in app: the tabs, and the group and task screens pushed over them; before them, the onboarding of a new
 * account (docs/CONTRACTS-V2.md §9). Also runs the local notifications (docs/NOTIFICATIONS.md).
 */
export default function AppLayout() {
  const theme = useTheme();
  const userId = useUserId();
  const groups = useMyGroups();
  const profile = useProfile();
  useLiveUpdates(userId || null, (groups.data ?? []).map((summary) => summary.group.id));
  const onboarding = useOnboardingGate(userId, profile.data);
  // The onboarding asks for the permission itself.
  useNotifications(userId || null, onboarding === false);

  // Wait for the profile before choosing between the onboarding and the tabs (not when it cannot be read).
  if (onboarding === null && (profile.data !== undefined || profile.fetchStatus === 'fetching')) {
    return <View style={{ flex: 1, backgroundColor: theme.background }} />;
  }
  const showOnboarding = onboarding === true;
  return (
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: theme.background } }}>
      <Stack.Protected guard={!showOnboarding}>
        <Stack.Screen name="(tabs)" />
        <Stack.Screen name="group/[groupId]" />
        <Stack.Screen name="task/[taskId]" />
        <Stack.Screen name="new-group" options={{ presentation: 'modal' }} />
        <Stack.Screen name="new-task" options={{ presentation: 'modal' }} />
        <Stack.Screen name="avatar" options={{ presentation: 'modal' }} />
        <Stack.Screen name="group/members" />
        <Stack.Screen name="group/invite" options={{ presentation: 'modal' }} />
        <Stack.Screen name="group/appearance" options={{ presentation: 'modal' }} />
      </Stack.Protected>
      <Stack.Protected guard={showOnboarding}>
        <Stack.Screen name="onboarding" options={{ gestureEnabled: false, animation: 'fade' }} />
      </Stack.Protected>
    </Stack>
  );
}
