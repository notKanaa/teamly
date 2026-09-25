import { Tabs } from 'expo-router';

import { newTaskCount } from '@/core/myTasks';
import { useLastSeen } from '@/data/lastSeen';
import { useMyTasks } from '@/data/queries';
import { useUserId } from '@/data/session';
import { FloatingTabBar } from '@/ui/TabBar';
import { useTheme } from '@/ui/theme';

export default function TabsLayout() {
  const theme = useTheme();
  const userId = useUserId();
  const myTasks = useMyTasks();
  const lastSeenAt = useLastSeen(userId);
  const badge =
    myTasks.data && lastSeenAt !== undefined ? newTaskCount({ tasks: myTasks.data, userId, lastSeenAt }) : 0;

  return (
    <Tabs
      tabBar={(props) => (
        <FloatingTabBar
          {...props}
          items={{
            index: { icon: 'people', title: 'Groupes' },
            'my-tasks': { icon: 'checkmark-circle', title: 'Mes tâches', badge },
            settings: { icon: 'settings', title: 'Réglages' },
          }}
        />
      )}
      screenOptions={{
        headerShown: false,
        sceneStyle: { backgroundColor: theme.background },
        // A short cross-fade between tabs.
        animation: 'fade',
      }}
    >
      <Tabs.Screen name="index" options={{ title: 'Groupes' }} />
      <Tabs.Screen name="my-tasks" options={{ title: 'Mes tâches' }} />
      <Tabs.Screen name="settings" options={{ title: 'Réglages' }} />
    </Tabs>
  );
}
