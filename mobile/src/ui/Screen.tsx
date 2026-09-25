import type { ReactNode } from 'react';
import { KeyboardAvoidingView, Platform, RefreshControl, ScrollView, View, type StyleProp, type ViewStyle } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { spacing, useTheme } from './theme';

/** A scrolling page on the `background` ground, with the page margins and the safe area. */
export function Screen({
  children,
  refreshing,
  onRefresh,
  contentStyle,
  topInset = true,
  footer,
}: {
  children: ReactNode;
  refreshing?: boolean;
  onRefresh?: () => void;
  contentStyle?: StyleProp<ViewStyle>;
  topInset?: boolean;
  footer?: ReactNode;
}) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  return (
    <KeyboardAvoidingView style={{ flex: 1, backgroundColor: theme.background }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
      <ScrollView
        keyboardShouldPersistTaps="handled"
        contentContainerStyle={[
          { paddingHorizontal: spacing.page, paddingTop: topInset ? insets.top + 12 : 12, paddingBottom: insets.bottom + 100, gap: 14 },
          contentStyle,
        ]}
        refreshControl={
          onRefresh ? <RefreshControl refreshing={refreshing ?? false} onRefresh={onRefresh} tintColor={theme.accent} /> : undefined
        }
      >
        {children}
      </ScrollView>
      {footer ? <View>{footer}</View> : null}
    </KeyboardAvoidingView>
  );
}
