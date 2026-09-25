import { Ionicons } from '@expo/vector-icons';
import { Children, Fragment, isValidElement, useState, type ReactNode } from 'react';
import {
  ActionSheetIOS,
  ActivityIndicator,
  Modal,
  Platform,
  Pressable,
  Switch,
  Text,
  View,
  type StyleProp,
  type TextStyle,
} from 'react-native';

import type { IconName } from './components';
import { extraTokens, IconTile } from './onboardingKit';
import { type Soft, type as typo, useTheme } from './theme';

// The grouped rows of « Réglages » (Swift `SettingsView`: a `Form` of cards over the grouped background, each row led
// by an icon tile).

const ROW_INSET = 16;
const TILE = 30;
const CARD_RADIUS = 26;

/** A header, a card of rows separated by inset hairlines, and a footer. */
export function SettingsSection({ title, footer, children }: { title?: string; footer?: ReactNode; children: ReactNode }) {
  const theme = useTheme();
  const rows = Children.toArray(children).filter(isValidElement);
  return (
    <View style={{ gap: 8 }}>
      {title ? (
        <Text accessibilityRole="header" style={{ fontSize: 17, fontWeight: '600', color: theme.textSecondary, marginLeft: ROW_INSET, marginTop: 10 }}>
          {title}
        </Text>
      ) : null}
      <View style={[{ backgroundColor: theme.card, borderRadius: CARD_RADIUS, overflow: 'hidden' }, theme.dark && { borderWidth: 1, borderColor: theme.hairline }]}>
        {rows.map((row, index) => (
          <Fragment key={row.key ?? index}>
            {index > 0 ? <View style={{ height: 1, marginLeft: ROW_INSET + TILE + 14, marginRight: ROW_INSET, backgroundColor: theme.track }} /> : null}
            {row}
          </Fragment>
        ))}
      </View>
      {footer ? <View style={{ marginHorizontal: ROW_INSET, gap: 6 }}>{footer}</View> : null}
    </View>
  );
}

/** A footer text below a section. */
export function SettingsFooter({ children, color }: { children: ReactNode; color?: string }) {
  const theme = useTheme();
  return <Text style={[typo.subheadline, { lineHeight: 20, color: color ?? theme.textSecondary }]}>{children}</Text>;
}

/**
 * A row: the icon tile and the title, then a value, a control (`trailing`), a spinner or a chevron. Tappable with
 * `onPress`.
 */
export function SettingsRow({
  icon,
  soft,
  title,
  titleColor,
  value,
  trailing,
  onPress,
  disabled,
  busy,
  chevron,
  accessibilityHint,
}: {
  icon?: IconName;
  soft?: Soft;
  title: string;
  titleColor?: string;
  value?: string | null;
  trailing?: ReactNode;
  onPress?: () => void;
  disabled?: boolean;
  busy?: boolean;
  chevron?: boolean;
  accessibilityHint?: string;
}) {
  const theme = useTheme();
  return (
    <Pressable
      accessibilityRole={onPress ? 'button' : undefined}
      accessibilityHint={accessibilityHint}
      accessibilityState={onPress ? { disabled: disabled || busy } : undefined}
      disabled={!onPress || disabled || busy}
      onPress={onPress}
      style={({ pressed }) => ({
        flexDirection: 'row',
        alignItems: 'center',
        gap: 14,
        minHeight: 52,
        paddingVertical: 10,
        paddingHorizontal: ROW_INSET,
        backgroundColor: pressed ? theme.hairline : 'transparent',
        opacity: disabled ? 0.5 : 1,
      })}
    >
      {icon && soft ? <IconTile icon={icon} soft={soft} size={TILE} /> : null}
      <Text style={[typo.body, { flexShrink: 1, color: titleColor ?? theme.textPrimary }]}>{title}</Text>
      <View style={{ flex: 1, flexDirection: 'row', justifyContent: 'flex-end', alignItems: 'center', gap: 8 }}>
        {value ? (
          <Text numberOfLines={1} ellipsizeMode="middle" style={[typo.body, { flexShrink: 1, color: theme.textSecondary, textAlign: 'right' }]}>
            {value}
          </Text>
        ) : null}
        {trailing}
        {busy ? <ActivityIndicator color={theme.textSecondary} /> : null}
        {chevron && !busy ? <Ionicons name="chevron-forward" size={17} color={extraTokens(theme).textTertiary} /> : null}
      </View>
    </Pressable>
  );
}

/** A row with a switch (the accent when on). */
export function SettingsToggleRow({
  icon,
  soft,
  title,
  value,
  onChange,
}: {
  icon: IconName;
  soft: Soft;
  title: string;
  value: boolean;
  onChange: (value: boolean) => void;
}) {
  const theme = useTheme();
  return (
    <SettingsRow
      icon={icon}
      soft={soft}
      title={title}
      trailing={
        <Switch
          accessibilityLabel={title}
          value={value}
          onValueChange={onChange}
          trackColor={{ true: theme.accentFill, false: theme.track }}
          thumbColor={Platform.OS === 'android' ? '#FFF' : undefined}
          ios_backgroundColor={theme.track}
        />
      }
    />
  );
}

/** A row showing the chosen option in the accent with ⌃⌄; a tap opens the options (an action sheet on iOS). */
export function SettingsPickerRow<K extends string>({
  icon,
  soft,
  title,
  options,
  value,
  onChange,
}: {
  icon: IconName;
  soft: Soft;
  title: string;
  options: readonly { key: K; label: string }[];
  value: K;
  onChange: (key: K) => void;
}) {
  const theme = useTheme();
  const [open, setOpen] = useState(false);
  const current = options.find((option) => option.key === value)?.label ?? '';

  const show = () => {
    if (Platform.OS === 'ios') {
      ActionSheetIOS.showActionSheetWithOptions(
        { title, options: [...options.map((option) => option.label), 'Annuler'], cancelButtonIndex: options.length },
        (index) => {
          const picked = options[index];
          if (picked) onChange(picked.key);
        },
      );
    } else {
      setOpen(true);
    }
  };

  return (
    <>
      <SettingsRow
        icon={icon}
        soft={soft}
        title={title}
        onPress={show}
        accessibilityHint={current}
        trailing={
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4, flexShrink: 1 }}>
            <Text numberOfLines={1} style={[typo.body, { color: theme.accent, flexShrink: 1 }]}>
              {current}
            </Text>
            <Ionicons name="chevron-expand" size={17} color={theme.accent} />
          </View>
        }
      />
      <Modal visible={open} transparent animationType="fade" onRequestClose={() => setOpen(false)}>
        <Pressable style={{ flex: 1, backgroundColor: 'rgba(0,0,0,0.35)', justifyContent: 'center', padding: 24 }} onPress={() => setOpen(false)}>
          <View style={{ backgroundColor: theme.card, borderRadius: CARD_RADIUS, paddingVertical: 8 }}>
            <Text style={[typo.headline, { color: theme.textPrimary, paddingHorizontal: 20, paddingVertical: 10 }]}>{title}</Text>
            {options.map((option) => (
              <Pressable
                key={option.key}
                accessibilityRole="button"
                accessibilityState={{ selected: option.key === value }}
                onPress={() => {
                  setOpen(false);
                  onChange(option.key);
                }}
                style={({ pressed }) => ({
                  minHeight: 48,
                  paddingHorizontal: 20,
                  flexDirection: 'row',
                  alignItems: 'center',
                  backgroundColor: pressed ? theme.hairline : 'transparent',
                })}
              >
                <Text style={[typo.body, { flex: 1, color: theme.textPrimary }]}>{option.label}</Text>
                {option.key === value ? <Ionicons name="checkmark" size={20} color={theme.accent} /> : null}
              </Pressable>
            ))}
          </View>
        </Pressable>
      </Modal>
    </>
  );
}

/** A row that is a plain text, led by a number in an accent disc (the ntfy instructions). */
export function SettingsTextRow({ number, children, style }: { number?: number; children: ReactNode; style?: StyleProp<TextStyle> }) {
  const theme = useTheme();
  return (
    <View style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 12, paddingVertical: 12, paddingHorizontal: ROW_INSET }}>
      {number !== undefined ? (
        <View style={{ width: TILE, alignItems: 'center', paddingTop: 1 }}>
          <View style={{ width: 22, height: 22, borderRadius: 11, backgroundColor: theme.accent, alignItems: 'center', justifyContent: 'center' }}>
            <Text style={{ fontSize: 13, fontWeight: '800', color: theme.dark ? theme.background : '#FFF' }}>{number}</Text>
          </View>
        </View>
      ) : null}
      <Text style={[typo.body, { flex: 1, color: theme.textPrimary }, style]}>{children}</Text>
    </View>
  );
}
