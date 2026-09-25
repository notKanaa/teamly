import * as Haptics from 'expo-haptics';
import { useEffect, useRef, useState, type ComponentProps, type ReactNode } from 'react';
import {
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
  type GestureResponderEvent,
  type PressableProps,
  type StyleProp,
  type TextStyle,
  type ViewStyle,
} from 'react-native';
import Animated, {
  FadeIn,
  FadeInDown,
  FadeInLeft,
  FadeInRight,
  FadeOut,
  LinearTransition,
  ReduceMotion,
  useAnimatedProps,
  useAnimatedStyle,
  useReducedMotion,
  useSharedValue,
  withSequence,
  withSpring,
  withTiming,
  ZoomIn,
  type AnimatedStyle,
  type SharedValue,
} from 'react-native-reanimated';
import Svg, { Circle } from 'react-native-svg';

import { countUpValue, progressFill, STAGGER_CAP, staggerDelay } from './motionMath';

export { countUpValue, progressFill, STAGGER_CAP, staggerDelay } from './motionMath';

// Shared motion primitives (docs/DESIGN-V2.md §4: spring animations for selection changes, checklist checks and
// progress, `.snappy`; Reduce Motion respected). Only transforms and opacity move, except `LinearTransition` for rows
// changing places and the few measured bars. With Reduce Motion on, springs jump to their end and entrances are plain
// short fades.

// MARK: - Tokens

/** SwiftUI's `.snappy`: quick, with a little overshoot (selection indicators, press feedback, rows moving). */
export const SNAPPY = { damping: 18, stiffness: 220, mass: 1 } as const;
/** Slower and softer (heroes, bars growing). */
export const GENTLE = { damping: 20, stiffness: 120, mass: 1 } as const;
/** A small overshoot (a check popping in, an icon bouncing). */
export const BOUNCY = { damping: 11, stiffness: 260, mass: 0.8 } as const;

export const DURATION = { fast: 160, base: 240 } as const;

type SpringConfig = { damping: number; stiffness: number; mass: number };

/** A spring to `to`, or the value itself with Reduce Motion (usable from JS and from worklets). */
export function springTo(to: number, reduced: boolean, config: SpringConfig = SNAPPY) {
  'worklet';
  return reduced ? to : withSpring(to, config);
}

/** A timing to `to` (colors or numbers); instant with Reduce Motion. */
export function timingTo<T extends number | string>(to: T, reduced: boolean, duration: number = DURATION.base): T {
  'worklet';
  return reduced ? to : withTiming(to, { duration });
}

/** Squash then spring back past 1 (the status control, a tab icon, a badge). */
export function bounce(reduced: boolean, from = 0.8, peak = 1.1) {
  'worklet';
  if (reduced) return 1;
  return withSequence(withTiming(from, { duration: 90 }), withTiming(peak, { duration: 120 }), withSpring(1, SNAPPY));
}

// MARK: - Hooks

export interface Motion {
  /** The system's Reduce Motion. */
  reduced: boolean;
  spring: (to: number, config?: SpringConfig) => number;
  timing: <T extends number | string>(to: T, duration?: number) => T;
}

/** The motion helpers bound to the system's Reduce Motion. */
export function useMotion(): Motion {
  const reduced = useReducedMotion();
  return {
    reduced,
    spring: (to, config) => springTo(to, reduced, config),
    timing: (to, duration) => timingTo(to, reduced, duration),
  };
}

/** A shared value that springs to `target` whenever it changes; from `initial` on mount (0: progress grows in). */
export function useSpringValue(
  target: number,
  { initial = 0, config = SNAPPY, delay = 0 }: { initial?: number; config?: SpringConfig; delay?: number } = {},
): SharedValue<number> {
  const reduced = useReducedMotion();
  const value = useSharedValue(reduced ? target : initial);
  useEffect(() => {
    if (reduced || delay === 0) {
      value.value = springTo(target, reduced, config);
      return;
    }
    const timer = setTimeout(() => {
      value.value = withSpring(target, config);
    }, delay);
    return () => clearTimeout(timer);
    // `config` is left out on purpose: callers pass the constants of this file, often as fresh objects.
  }, [target, reduced, delay, value]);
  return value;
}

/** A shared value (a color or a number) that eases to `target` whenever it changes; instant with Reduce Motion. */
export function useTimingValue<T extends number | string>(target: T, duration: number = DURATION.fast): SharedValue<T> {
  const reduced = useReducedMotion();
  const value = useSharedValue<T>(target);
  useEffect(() => {
    value.value = timingTo(target, reduced, duration);
  }, [target, reduced, duration, value]);
  return value;
}

/** False on the first render, true after: entrances that should only play on later changes. */
export function useHasMounted(): boolean {
  const mounted = useRef(false);
  useEffect(() => {
    mounted.current = true;
  }, []);
  return mounted.current;
}

// MARK: - Entrances (layout animations)

/** A short fade (empty states, error banners, badges); the same with Reduce Motion. */
export const fadeIn = FadeIn.duration(DURATION.base).reduceMotion(ReduceMotion.Never);
export const fadeOut = FadeOut.duration(DURATION.fast).reduceMotion(ReduceMotion.Never);

/** Rows changing places (a filter, a task moving to « Terminées »). Skipped with Reduce Motion. */
export const listLayout = LinearTransition.springify().damping(SNAPPY.damping).stiffness(SNAPPY.stiffness);

/** The entrance of the `index`-th row: a staggered fade and rise for the first rows, a plain fade after. */
export function rowEntering(index: number, reduced: boolean, stagger = true) {
  if (reduced) return fadeIn;
  if (!stagger || index >= STAGGER_CAP) return FadeInDown.duration(DURATION.base);
  return FadeInDown.delay(staggerDelay(index)).springify().damping(SNAPPY.damping).stiffness(SNAPPY.stiffness);
}

/**
 * The entrances of a list: staggered while the list first shows up (the first 600 ms after `ready`), then quick fades
 * for rows that appear later (a filter change). Pass `exiting={fadeOut}` and `layout={listLayout}` alongside.
 */
export function useListEntering(ready: boolean) {
  const reduced = useReducedMotion();
  const readyAt = useRef<number | null>(null);
  if (ready && readyAt.current === null) readyAt.current = Date.now();
  return (index: number) => {
    const first = readyAt.current !== null && Date.now() - readyAt.current < 600;
    return rowEntering(index, reduced, first);
  };
}

/** Content sliding in from the side it comes from (`direction` 1: from the right, -1: from the left). */
export function slideIn(direction: 1 | -1, reduced: boolean) {
  if (reduced) return fadeIn;
  return (direction === 1 ? FadeInRight : FadeInLeft).springify().damping(GENTLE.damping + 6).stiffness(GENTLE.stiffness + 60);
}

/** A glyph popping in (a check, a filled status, a badge). */
export function popIn(reduced: boolean, delay = 0) {
  if (reduced) return fadeIn;
  return ZoomIn.delay(delay).springify().damping(BOUNCY.damping).stiffness(BOUNCY.stiffness).mass(BOUNCY.mass);
}

// MARK: - Components

/**
 * A keyed content transition: when `id` changes, the new content slides in from `direction` (a fade with Reduce
 * Motion). The first content shows without motion.
 */
export function FadeSwitch({
  id,
  direction = 1,
  children,
  style,
}: {
  id: string;
  direction?: 1 | -1;
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
}) {
  const reduced = useReducedMotion();
  const mounted = useHasMounted();
  return (
    <Animated.View key={id} entering={mounted ? slideIn(direction, reduced) : undefined} style={style}>
      {children}
    </Animated.View>
  );
}

/** Content that pops in on mount (the check of a selected swatch). */
export function PopIn({ children, delay = 0 }: { children: ReactNode; delay?: number }) {
  const reduced = useReducedMotion();
  return <Animated.View entering={popIn(reduced, delay)}>{children}</Animated.View>;
}

/** Content that fades in on mount (empty states, error banners). */
export function FadeInView({ children, style, delay = 0 }: { children: ReactNode; style?: StyleProp<ViewStyle>; delay?: number }) {
  return (
    <Animated.View entering={delay > 0 ? FadeIn.delay(delay).duration(DURATION.base).reduceMotion(ReduceMotion.Never) : fadeIn} style={style}>
      {children}
    </Animated.View>
  );
}

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

type AnimatedPressableProps = ComponentProps<typeof AnimatedPressable>;

export type PressableScaleProps = Omit<PressableProps, 'style'> & {
  /** Static styles, and animated ones (`useAnimatedStyle`). */
  style?: StyleProp<AnimatedStyle<ViewStyle>>;
  /** Layout animations of the pressable itself (a chip in a row that reflows, a row entering). */
  entering?: AnimatedPressableProps['entering'];
  exiting?: AnimatedPressableProps['exiting'];
  layout?: AnimatedPressableProps['layout'];
  /** The scale while pressed (1: opacity only). */
  scaleTo?: number;
  /** The opacity while pressed. */
  pressedOpacity?: number;
  /** The resting opacity (a disabled look); the press dims from it. Use this rather than `opacity` in `style`. */
  opacity?: number;
  /** A selection tick on press-in (native only). */
  haptic?: boolean;
  children?: ReactNode;
};

/**
 * A Pressable that shrinks slightly and dims while pressed, then springs back. With Reduce Motion, only the opacity
 * changes. The style is static (no `({ pressed })` function).
 */
export function PressableScale({
  style,
  scaleTo = 0.97,
  pressedOpacity = 0.9,
  opacity = 1,
  haptic,
  onPressIn,
  onPressOut,
  children,
  ...props
}: PressableScaleProps) {
  const reduced = useReducedMotion();
  const pressed = useSharedValue(0);
  const animatedStyle = useAnimatedStyle(() => ({
    opacity: opacity * (1 - (1 - pressedOpacity) * pressed.value),
    transform: [{ scale: reduced ? 1 : 1 - (1 - scaleTo) * pressed.value }],
  }));
  return (
    <AnimatedPressable
      {...props}
      onPressIn={(event: GestureResponderEvent) => {
        pressed.value = reduced ? 1 : withTiming(1, { duration: 90 });
        if (haptic && Platform.OS !== 'web') void Haptics.selectionAsync().catch(() => undefined);
        onPressIn?.(event);
      }}
      onPressOut={(event: GestureResponderEvent) => {
        pressed.value = springTo(0, reduced, SNAPPY);
        onPressOut?.(event);
      }}
      style={[style, animatedStyle]}
    >
      {children}
    </AnimatedPressable>
  );
}

/**
 * A number that counts up to `value` (the week's total); the final value at once with Reduce Motion. Runs on the JS
 * thread for a short time (a handful of renders), so that it works everywhere.
 */
export function useCountUp(value: number, duration = 700): number {
  const reduced = useReducedMotion();
  const [shown, setShown] = useState(reduced ? value : 0);
  const from = useRef(shown);
  from.current = shown;
  useEffect(() => {
    if (reduced) {
      setShown(value);
      return;
    }
    const start = from.current;
    if (start === value) return;
    const began = Date.now();
    let frame = 0;
    const step = () => {
      const t = Math.min((Date.now() - began) / duration, 1);
      setShown(countUpValue(start, value, t));
      if (t < 1) frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [value, reduced, duration]);
  return shown;
}

/** A number that counts up (`useCountUp`); screen readers read the final value. */
export function CountUpText({ value, style }: { value: number; style?: StyleProp<TextStyle> }) {
  const shown = useCountUp(value);
  return (
    <Text accessibilityLabel={String(value)} style={style}>
      {shown}
    </Text>
  );
}

// MARK: - Progress

/**
 * A progress bar whose fill springs from 0 on mount and on every change. The fill is a full-width bar slid along the
 * track (a transform, not a width), measured once.
 */
export function AnimatedProgressBar({
  fraction,
  color,
  track,
  height = 8,
  delay = 0,
}: {
  fraction: number;
  color: string;
  track: string;
  height?: number;
  delay?: number;
}) {
  const [width, setWidth] = useState(0);
  const progress = useSpringValue(width > 0 ? progressFill(fraction, width, height) : 0, { config: GENTLE, delay });
  const fillStyle = useAnimatedStyle(() => ({
    opacity: progress.value > 0.001 ? 1 : 0,
    transform: [{ translateX: (Math.min(progress.value, 1) - 1) * width }],
  }));
  return (
    <View
      onLayout={(event) => setWidth(event.nativeEvent.layout.width)}
      style={{ height, borderRadius: height / 2, backgroundColor: track, overflow: 'hidden' }}
    >
      <Animated.View style={[{ width: '100%', height, borderRadius: height / 2, backgroundColor: color }, fillStyle]} />
    </View>
  );
}

const AnimatedCircle = Animated.createAnimatedComponent(Circle);

/** A progress ring whose arc springs from 0 on mount and on every change (the stroke's dash offset). */
export function AnimatedProgressRing({
  fraction,
  size,
  stroke,
  color,
  track,
  children,
}: {
  fraction: number;
  size: number;
  stroke: number;
  color: string;
  track: string;
  children?: ReactNode;
}) {
  const r = (size - stroke) / 2;
  const circumference = 2 * Math.PI * r;
  const progress = useSpringValue(Math.max(0, Math.min(1, fraction)), { config: GENTLE });
  const arcProps = useAnimatedProps(() => ({
    strokeDashoffset: circumference * (1 - Math.max(0, Math.min(1, progress.value))),
    strokeOpacity: progress.value > 0.002 ? 1 : 0,
  }));
  return (
    <View style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}>
      <Svg width={size} height={size} style={StyleSheet.absoluteFill}>
        <Circle cx={size / 2} cy={size / 2} r={r} stroke={track} strokeWidth={stroke} fill="none" />
        <AnimatedCircle
          cx={size / 2}
          cy={size / 2}
          r={r}
          stroke={color}
          strokeWidth={stroke}
          fill="none"
          strokeLinecap="round"
          strokeDasharray={`${circumference} ${circumference}`}
          transform={`rotate(-90 ${size / 2} ${size / 2})`}
          animatedProps={arcProps}
        />
      </Svg>
      {children}
    </View>
  );
}
