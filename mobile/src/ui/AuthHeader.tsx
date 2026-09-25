import { Image, Platform, Text, View, type ViewStyle } from 'react-native';

import { IconTile, type IconName } from './components';
import { type as typo, useTheme } from './theme';

const APP_ICON = require('../../assets/images/icon.png') as number;

/** The app icon in its rounded square, with a soft coral shadow in light mode (ShellBrandMark). Decorative. */
export function BrandMark({ size = 88 }: { size?: number }) {
  const theme = useTheme();
  const corner = size * 0.2237;
  const shadow: ViewStyle = theme.dark
    ? { borderWidth: 1, borderColor: 'rgba(255,255,255,0.12)' }
    : (Platform.select<ViewStyle>({
        web: { boxShadow: `0 ${size * 0.1}px ${size * 0.32}px rgba(214,56,90,0.28)` } as ViewStyle,
        default: {
          shadowColor: '#D6385A',
          shadowOpacity: 0.28,
          shadowRadius: size * 0.16,
          shadowOffset: { width: 0, height: size * 0.1 },
          elevation: 6,
        },
      }) ?? {});
  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={[{ width: size, height: size, borderRadius: corner, backgroundColor: theme.card }, shadow]}
    >
      <Image source={APP_ICON} style={{ width: size, height: size, borderRadius: corner }} resizeMode="cover" />
    </View>
  );
}

/**
 * The top of the sign-in screens: the app icon (or an icon tile), a large title and a subtitle, centered
 * (ShellBrandHeader).
 */
export function AuthHeader({
  title,
  subtitle,
  icon,
  iconSize = 64,
  brandSize = 88,
}: {
  title?: string | null;
  subtitle?: string | null;
  /** An icon tile instead of the app icon (« Mot de passe oublié » steps). */
  icon?: IconName;
  iconSize?: number;
  brandSize?: number;
}) {
  const theme = useTheme();
  return (
    <View style={{ alignItems: 'center', gap: 14, marginBottom: 6 }}>
      <View style={{ marginBottom: 4 }}>{icon ? <IconTile icon={icon} size={iconSize} /> : <BrandMark size={brandSize} />}</View>
      {title ? (
        <Text accessibilityRole="header" style={[typo.largeTitle, { color: theme.textPrimary, textAlign: 'center' }]}>
          {title}
        </Text>
      ) : null}
      {subtitle ? <Text style={[typo.body, { fontSize: 16, color: theme.textSecondary, textAlign: 'center' }]}>{subtitle}</Text> : null}
    </View>
  );
}
