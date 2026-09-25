import { Ionicons } from '@expo/vector-icons';
import { Pressable, Text, View } from 'react-native';

import { COLOR_KEYS, colorLabel, type ColorKey } from '@/core/colorKey';

import { tap } from './components';
import { PopIn } from './motion';
import { useTheme } from './theme';

/** SwatchGrid: the 9 colors, a check on the selected one. */
export function SwatchGrid({ value, onChange }: { value: ColorKey; onChange: (key: ColorKey) => void }) {
  const theme = useTheme();
  return (
    <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 12, justifyContent: 'center' }}>
      {COLOR_KEYS.map((key) => (
        <Pressable
          key={key}
          accessibilityRole="button"
          accessibilityLabel={colorLabel(key)}
          accessibilityState={{ selected: key === value }}
          onPress={() => {
            tap();
            onChange(key);
          }}
          style={{
            width: 48,
            height: 48,
            borderRadius: 16,
            backgroundColor: theme.fill[key],
            alignItems: 'center',
            justifyContent: 'center',
            borderWidth: key === value ? 3 : 0,
            borderColor: theme.textPrimary,
          }}
        >
          {key === value ? (
            <PopIn>
              <Ionicons name="checkmark" size={24} color="#FFF" />
            </PopIn>
          ) : null}
        </Pressable>
      ))}
    </View>
  );
}

/** EmojiGrid: a curated grid; the selected emoji has an accent ring. Tapping it again clears it. */
export function EmojiGrid({
  choices,
  value,
  onChange,
}: {
  choices: readonly string[];
  value: string | null;
  onChange: (emoji: string | null) => void;
}) {
  const theme = useTheme();
  return (
    <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8, justifyContent: 'center' }}>
      {choices.map((emoji) => {
        const selected = emoji === value;
        return (
          <Pressable
            key={emoji}
            accessibilityRole="button"
            accessibilityState={{ selected }}
            onPress={() => {
              tap();
              onChange(selected ? null : emoji);
            }}
            style={{
              width: 48,
              height: 48,
              borderRadius: 14,
              backgroundColor: selected ? theme.accentSoft.bg : theme.track,
              borderWidth: selected ? 2.5 : 0,
              borderColor: theme.accent,
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <Text style={{ fontSize: 24 }}>{emoji}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}
