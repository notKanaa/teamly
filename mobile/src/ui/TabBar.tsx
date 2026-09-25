import { Ionicons } from '@expo/vector-icons';
import type { ComponentProps } from 'react';
import { Pressable, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import type { Tabs } from 'expo-router';

import { tap, type IconName } from './components';
import { useTheme } from './theme';

export type TabBarProps = Parameters<NonNullable<ComponentProps<typeof Tabs>['tabBar']>>[0];

/** Height of the capsule; screens keep this much (plus the safe area and a margin) free at their bottom. */
export const TAB_BAR_HEIGHT = 68;

/** Space a tab screen leaves at its bottom so that its last row scrolls above the floating tab bar. */
export function tabBarClearance(bottomInset: number): number {
  return TAB_BAR_HEIGHT + Math.max(bottomInset, 12) + 24;
}

export interface TabItem {
  icon: IconName;
  title: string;
  /** A red count badge (hidden at 0). */
  badge?: number;
}

/**
 * The floating capsule tab bar (screenshots 02, 07): a card capsule with a shadow, centered above the home
 * indicator; the selected tab sits in a grey pill with its icon and label in the accent; a red badge counts the
 * « Nouveau » tasks on « Mes tâches ».
 */
export function FloatingTabBar({ state, navigation, items }: TabBarProps & { items: Record<string, TabItem> }) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  return (
    <View
      pointerEvents="box-none"
      style={{ position: 'absolute', left: 0, right: 0, bottom: Math.max(insets.bottom, 12), alignItems: 'center' }}
    >
      <View
        accessibilityRole="tablist"
        style={[
          {
            flexDirection: 'row',
            backgroundColor: theme.card,
            borderRadius: 999,
            padding: 5,
            gap: 4,
            height: TAB_BAR_HEIGHT,
            maxWidth: 440,
            width: '72%',
            minWidth: 300,
          },
          theme.raisedShadow,
        ]}
      >
        {state.routes.map((route, index) => {
          const item = items[route.name];
          if (!item) return null;
          const focused = state.index === index;
          const color = focused ? theme.accent : theme.textPrimary;
          const badge = item.badge ?? 0;
          return (
            <Pressable
              key={route.key}
              accessibilityRole="tab"
              accessibilityState={{ selected: focused }}
              accessibilityLabel={badge > 0 ? `${item.title}, ${badge}` : item.title}
              onPress={() => {
                const event = navigation.emit({ type: 'tabPress', target: route.key, canPreventDefault: true });
                if (!focused && !event.defaultPrevented) {
                  tap();
                  navigation.navigate(route.name, route.params);
                }
              }}
              onLongPress={() => navigation.emit({ type: 'tabLongPress', target: route.key })}
              style={{
                flex: 1,
                borderRadius: 999,
                alignItems: 'center',
                justifyContent: 'center',
                gap: 2,
                backgroundColor: focused ? theme.track : 'transparent',
              }}
            >
              <View>
                <Ionicons name={item.icon} size={26} color={color} />
                {badge > 0 ? (
                  <View
                    style={{
                      position: 'absolute',
                      top: -6,
                      right: -12,
                      minWidth: 20,
                      height: 20,
                      borderRadius: 10,
                      paddingHorizontal: 5,
                      backgroundColor: theme.badge,
                      alignItems: 'center',
                      justifyContent: 'center',
                    }}
                  >
                    <Text style={{ color: '#FFF', fontSize: 12, fontWeight: '700' }}>{badge > 99 ? '99+' : badge}</Text>
                  </View>
                ) : null}
              </View>
              <Text numberOfLines={1} style={{ fontSize: 12, fontWeight: focused ? '600' : '500', color }}>
                {item.title}
              </Text>
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}
