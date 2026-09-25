import { Text, View } from 'react-native';

import { type as typo, useTheme } from './theme';

/** The app badge, a large title and a subtitle, on the sign-in screens. */
export function AuthHeader({ title, subtitle }: { title: string; subtitle: string }) {
  const theme = useTheme();
  return (
    <View style={{ alignItems: 'center', gap: 10, marginBottom: 10 }}>
      <View
        style={{
          width: 84,
          height: 84,
          borderRadius: 26,
          backgroundColor: theme.accentFill,
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        <Text style={{ fontFamily: 'Nunito_900Black', fontSize: 44, color: '#FFF' }}>É</Text>
      </View>
      <Text style={[typo.largeTitle, { color: theme.textPrimary, textAlign: 'center' }]}>{title}</Text>
      <Text style={[typo.body, { color: theme.textSecondary, textAlign: 'center' }]}>{subtitle}</Text>
    </View>
  );
}
