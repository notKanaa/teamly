import { Ionicons } from '@expo/vector-icons';
import { useEffect, useRef, useState, type ComponentProps } from 'react';
import { Pressable, Text, View } from 'react-native';
import Animated, { useAnimatedStyle, useReducedMotion, useSharedValue } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import type { Tabs } from 'expo-router';

import { tap, type IconName } from './components';
import { bounce, springTo, useTimingValue } from './motion';
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

const BAR_PADDING = 5;
const ITEM_GAP = 4;

/**
 * The floating capsule tab bar (screenshots 02, 07): a card capsule with a shadow, centered above the home
 * indicator; the selected tab sits in a grey pill (sliding between tabs with a spring) with its icon and label in the
 * accent; a red badge counts the « Nouveau » tasks on « Mes tâches ».
 */
export function FloatingTabBar({ state, navigation, items }: TabBarProps & { items: Record<string, TabItem> }) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const reduced = useReducedMotion();
  const routes = state.routes.filter((route) => items[route.name] !== undefined);
  const selected = Math.max(0, routes.findIndex((route) => route.key === state.routes[state.index]?.key));
  // The pill: the items share the capsule's width equally (measured).
  const [width, setWidth] = useState(0);
  const itemWidth = width > 0 ? (width - BAR_PADDING * 2 - ITEM_GAP * (routes.length - 1)) / Math.max(routes.length, 1) : 0;
  const x = useSharedValue(0);
  const placed = useRef(false);
  useEffect(() => {
    if (itemWidth <= 0) return;
    const target = selected * (itemWidth + ITEM_GAP);
    x.value = placed.current ? springTo(target, reduced) : target;
    placed.current = true;
  }, [selected, itemWidth, reduced, x]);
  // Clamped to the capsule, so that the spring's overshoot never pokes out at the ends.
  const maxX = (itemWidth + ITEM_GAP) * (routes.length - 1);
  const pillStyle = useAnimatedStyle(() => ({ transform: [{ translateX: Math.min(Math.max(x.value, 0), maxX) }] }));
  const measured = itemWidth > 0;
  return (
    <View
      pointerEvents="box-none"
      style={{ position: 'absolute', left: 0, right: 0, bottom: Math.max(insets.bottom, 12), alignItems: 'center' }}
    >
      <View
        accessibilityRole="tablist"
        onLayout={(event) => setWidth(event.nativeEvent.layout.width)}
        style={[
          {
            flexDirection: 'row',
            backgroundColor: theme.card,
            borderRadius: 999,
            padding: BAR_PADDING,
            gap: ITEM_GAP,
            height: TAB_BAR_HEIGHT,
            maxWidth: 440,
            width: '72%',
            minWidth: 300,
          },
          theme.raisedShadow,
        ]}
      >
        {measured ? (
          <Animated.View
            pointerEvents="none"
            style={[
              { position: 'absolute', top: BAR_PADDING, bottom: BAR_PADDING, left: BAR_PADDING, width: itemWidth, borderRadius: 999, backgroundColor: theme.track },
              pillStyle,
            ]}
          />
        ) : null}
        {routes.map((route) => {
          const item = items[route.name];
          if (!item) return null;
          const focused = state.routes[state.index]?.key === route.key;
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
                // Until measured, the selected item draws its own pill.
                backgroundColor: focused && !measured ? theme.track : 'transparent',
              }}
            >
              <TabIcon icon={item.icon} focused={focused} badge={badge} />
              <TabLabel title={item.title} focused={focused} />
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

/** A tab's icon: it bounces when its tab gets selected; its badge pops when the count changes. */
function TabIcon({ icon, focused, badge }: { icon: IconName; focused: boolean; badge: number }) {
  const theme = useTheme();
  const reduced = useReducedMotion();
  const scale = useSharedValue(1);
  const wasFocused = useRef(focused);
  useEffect(() => {
    if (focused && !wasFocused.current) scale.value = bounce(reduced, 0.85, 1.12);
    wasFocused.current = focused;
  }, [focused, reduced, scale]);
  const iconStyle = useAnimatedStyle(() => ({ transform: [{ scale: scale.value }] }));

  const badgeScale = useSharedValue(1);
  const lastBadge = useRef(badge);
  useEffect(() => {
    if (badge !== lastBadge.current && badge > 0) badgeScale.value = bounce(reduced, 0.6, 1.2);
    lastBadge.current = badge;
  }, [badge, reduced, badgeScale]);
  const badgeStyle = useAnimatedStyle(() => ({ transform: [{ scale: badgeScale.value }] }));

  return (
    <View>
      <Animated.View style={iconStyle}>
        <Ionicons name={icon} size={26} color={focused ? theme.accent : theme.textPrimary} />
      </Animated.View>
      {badge > 0 ? (
        <Animated.View
          style={[
            {
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
            },
            badgeStyle,
          ]}
        >
          <Text style={{ color: '#FFF', fontSize: 12, fontWeight: '700' }}>{badge > 99 ? '99+' : badge}</Text>
        </Animated.View>
      ) : null}
    </View>
  );
}

/** A tab's label, its color easing with the selection. */
function TabLabel({ title, focused }: { title: string; focused: boolean }) {
  const theme = useTheme();
  const color = useTimingValue(focused ? theme.accent : theme.textPrimary);
  const colorStyle = useAnimatedStyle(() => ({ color: color.value }));
  return (
    <Animated.Text numberOfLines={1} style={[{ fontSize: 12, fontWeight: focused ? '600' : '500' }, colorStyle]}>
      {title}
    </Animated.Text>
  );
}
