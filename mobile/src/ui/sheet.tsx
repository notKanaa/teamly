import { Ionicons } from '@expo/vector-icons';
import { useRef, useState, type ReactNode } from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  Text,
  TextInput,
  useWindowDimensions,
  View,
  type StyleProp,
  type ViewStyle,
} from 'react-native';

import { tap, type IconName } from './components';
import { PressableScale } from './motion';
import { fonts, radius, type as typo, useTheme } from './theme';

// Sheet chrome and menus of the groups screens: the capsule buttons of a sheet's top bar (« Annuler » / « Créer »),
// the round icon buttons, an anchored pop-up menu (the « + » and « … » menus), and a text prompt (« Renommer »).

/** A capsule text button of a sheet's top bar: « Annuler », « Créer », « Fermer ». */
export function CapsuleButton({
  title,
  onPress,
  bold,
  disabled,
  loading,
  accessibilityLabel,
}: {
  title: string;
  onPress: () => void;
  bold?: boolean;
  disabled?: boolean;
  loading?: boolean;
  accessibilityLabel?: string;
}) {
  const theme = useTheme();
  return (
    <PressableScale
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel ?? title}
      accessibilityState={{ disabled: disabled || loading }}
      disabled={disabled || loading}
      onPress={onPress}
      hitSlop={4}
      scaleTo={0.95}
      pressedOpacity={0.75}
      style={[
        {
          minHeight: 44,
          minWidth: 44,
          paddingHorizontal: 18,
          borderRadius: 999,
          backgroundColor: theme.card,
          alignItems: 'center',
          justifyContent: 'center',
        },
        theme.cardShadow,
      ]}
    >
      {loading ? (
        <ActivityIndicator color={theme.accent} />
      ) : (
        <Text
          style={{
            fontSize: 17,
            fontWeight: bold ? '700' : '400',
            color: disabled ? theme.textSecondary : theme.accent,
          }}
        >
          {title}
        </Text>
      )}
    </PressableScale>
  );
}

/** The top bar of a sheet: a leading capsule, the centered title, a trailing capsule. */
export function SheetHeader({ title, leading, trailing }: { title: string; leading?: ReactNode; trailing?: ReactNode }) {
  const theme = useTheme();
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16, paddingTop: 14, paddingBottom: 10, gap: 8 }}>
      <View style={{ flex: 1, alignItems: 'flex-start' }}>{leading}</View>
      <Text
        accessibilityRole="header"
        numberOfLines={1}
        style={{ fontSize: 17, fontWeight: '700', color: theme.textPrimary, flexShrink: 1, textAlign: 'center' }}
      >
        {title}
      </Text>
      <View style={{ flex: 1, alignItems: 'flex-end' }}>{trailing}</View>
    </View>
  );
}

/**
 * A round icon button, 44 pt: `card` (a card circle with a textPrimary symbol, or the accent with `tint`) or
 * `translucent` (white 22 % with a white symbol, on a group's hero).
 */
export function CircleButton({
  icon,
  label,
  onPress,
  variant = 'card',
  tint,
  size = 44,
}: {
  icon: IconName;
  label: string;
  onPress: () => void;
  variant?: 'card' | 'translucent';
  tint?: string;
  size?: number;
}) {
  const theme = useTheme();
  const translucent = variant === 'translucent';
  return (
    <PressableScale
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      scaleTo={0.92}
      pressedOpacity={0.75}
      style={[
        {
          width: size,
          height: size,
          borderRadius: size / 2,
          backgroundColor: translucent ? 'rgba(255,255,255,0.22)' : theme.card,
          alignItems: 'center',
          justifyContent: 'center',
        },
        !translucent && theme.cardShadow,
      ]}
    >
      <Ionicons name={icon} size={size * 0.5} color={translucent ? '#FFF' : (tint ?? theme.textPrimary)} />
    </PressableScale>
  );
}

export interface MenuItem {
  label: string;
  icon?: IconName;
  destructive?: boolean;
  disabled?: boolean;
  onPress: () => void;
}

/** One group of items; groups are separated by a thicker line, like the iOS menus. */
export type MenuSection = readonly MenuItem[];

/**
 * A button that opens a pop-up menu anchored under it (the « + » of « Groupes », the « … » of a group, the « ⋯ » of a
 * member). The chosen item runs once the menu has closed, so that it can open an alert or push a screen.
 */
export function MenuButton({
  sections,
  accessibilityLabel,
  children,
  style,
  disabled,
}: {
  sections: readonly MenuSection[];
  accessibilityLabel: string;
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
  disabled?: boolean;
}) {
  const theme = useTheme();
  const window = useWindowDimensions();
  const anchor = useRef<View>(null);
  const [frame, setFrame] = useState<{ x: number; y: number; width: number; height: number } | null>(null);
  const visible = sections.filter((section) => section.length > 0);

  const open = () => {
    tap();
    anchor.current?.measureInWindow((x, y, width, height) => setFrame({ x, y, width, height }));
  };

  const choose = (item: MenuItem) => {
    setFrame(null);
    setTimeout(item.onPress, Platform.OS === 'ios' ? 350 : 50);
  };

  const menuWidth = Math.min(260, window.width - 32);
  const left = frame ? Math.max(16, Math.min(frame.x + frame.width - menuWidth, window.width - menuWidth - 16)) : 0;
  const top = frame ? frame.y + frame.height + 8 : 0;

  return (
    <>
      <Pressable
        ref={anchor}
        accessibilityRole="button"
        accessibilityLabel={accessibilityLabel}
        disabled={disabled || visible.length === 0}
        onPress={open}
        style={({ pressed }) => [{ opacity: pressed ? 0.7 : 1 }, style]}
      >
        {children}
      </Pressable>
      <Modal visible={frame !== null} transparent animationType="fade" onRequestClose={() => setFrame(null)} statusBarTranslucent>
        <Pressable style={{ flex: 1, backgroundColor: theme.dark ? 'rgba(0,0,0,0.35)' : 'rgba(22,20,40,0.12)' }} onPress={() => setFrame(null)}>
          <View
            accessibilityRole="menu"
            style={[
              {
                position: 'absolute',
                left,
                top,
                width: menuWidth,
                backgroundColor: theme.card,
                borderRadius: 16,
                overflow: 'hidden',
              },
              theme.raisedShadow,
            ]}
          >
            {visible.map((section, sectionIndex) => (
              <View
                key={sectionIndex}
                style={sectionIndex > 0 ? { borderTopWidth: 6, borderTopColor: theme.background } : undefined}
              >
                {section.map((item, index) => {
                  const color = item.disabled ? theme.textSecondary : item.destructive ? theme.danger.text : theme.textPrimary;
                  return (
                    <Pressable
                      key={item.label}
                      accessibilityRole="menuitem"
                      disabled={item.disabled}
                      onPress={() => choose(item)}
                      style={({ pressed }) => ({
                        flexDirection: 'row',
                        alignItems: 'center',
                        gap: 12,
                        minHeight: 46,
                        paddingHorizontal: 16,
                        borderTopWidth: index === 0 ? 0 : 1,
                        borderTopColor: theme.hairline,
                        backgroundColor: pressed ? theme.track : 'transparent',
                      })}
                    >
                      <Text style={[typo.body, { flex: 1, color }]}>{item.label}</Text>
                      {item.icon ? <Ionicons name={item.icon} size={19} color={color} /> : null}
                    </Pressable>
                  );
                })}
              </View>
            ))}
          </View>
        </Pressable>
      </Modal>
    </>
  );
}

/** A small dialog with a text field (« Renommer le groupe »), for both platforms (Alert.prompt is iOS only). */
export function PromptModal({
  visible,
  title,
  message,
  initialValue,
  placeholder,
  confirmTitle,
  maxLength,
  onCancel,
  onConfirm,
}: {
  visible: boolean;
  title: string;
  message?: string;
  initialValue: string;
  placeholder?: string;
  confirmTitle: string;
  maxLength?: number;
  onCancel: () => void;
  onConfirm: (value: string) => void;
}) {
  const theme = useTheme();
  const [value, setValue] = useState(initialValue);
  const [shownFor, setShownFor] = useState(false);
  // Reset the field each time the prompt opens.
  if (visible !== shownFor) {
    setShownFor(visible);
    if (visible) setValue(initialValue);
  }
  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={onCancel} statusBarTranslucent>
      <KeyboardAvoidingView
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        style={{ flex: 1, backgroundColor: 'rgba(0,0,0,0.4)', alignItems: 'center', justifyContent: 'center', padding: 24 }}
      >
        <View style={{ width: '100%', maxWidth: 360, backgroundColor: theme.card, borderRadius: radius.card, padding: 20, gap: 12 }}>
          <Text accessibilityRole="header" style={{ fontFamily: fonts.heavy, fontSize: 20, color: theme.textPrimary, textAlign: 'center' }}>
            {title}
          </Text>
          {message ? <Text style={[typo.footnote, { color: theme.textSecondary, textAlign: 'center' }]}>{message}</Text> : null}
          <TextInput
            value={value}
            onChangeText={setValue}
            autoFocus
            placeholder={placeholder}
            placeholderTextColor={theme.textSecondary}
            autoCapitalize="sentences"
            autoCorrect={false}
            maxLength={maxLength}
            returnKeyType="done"
            onSubmitEditing={() => onConfirm(value)}
            style={[
              typo.body,
              {
                color: theme.textPrimary,
                backgroundColor: theme.background,
                borderRadius: 14,
                paddingHorizontal: 14,
                minHeight: 48,
              },
            ]}
          />
          <View style={{ flexDirection: 'row', gap: 10, marginTop: 4 }}>
            <DialogButton title="Annuler" onPress={onCancel} />
            <DialogButton title={confirmTitle} bold onPress={() => onConfirm(value)} />
          </View>
        </View>
      </KeyboardAvoidingView>
    </Modal>
  );
}

function DialogButton({ title, onPress, bold }: { title: string; onPress: () => void; bold?: boolean }) {
  const theme = useTheme();
  return (
    <PressableScale
      accessibilityRole="button"
      onPress={onPress}
      pressedOpacity={0.85}
      style={{
        flex: 1,
        minHeight: 46,
        borderRadius: 14,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: bold ? theme.accentFill : theme.track,
      }}
    >
      <Text style={{ fontSize: 16, fontWeight: bold ? '700' : '600', color: bold ? '#FFF' : theme.textPrimary }}>{title}</Text>
    </PressableScale>
  );
}
