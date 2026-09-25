import DateTimePicker, { DateTimePickerAndroid, type DateTimePickerEvent } from '@react-native-community/datetimepicker';
import { Pressable, Platform, Text, View } from 'react-native';

import type { FrenchCalendar, Instant } from '@/core/calendar';
import { formatDay, formatTime } from '@/core/frenchDate';
import { capitalizingFirstLetter } from '@/core/frenchText';

import { tap } from './components';
import { useTheme } from './theme';

/** The date and the time of a due date: the native compact pickers on iOS, dialogs on Android, steppers on the web. */
export function DueDatePicker({
  value,
  onChange,
  calendar,
}: {
  value: Instant;
  onChange: (value: Instant) => void;
  calendar: FrenchCalendar;
}) {
  const theme = useTheme();
  const date = new Date(value);

  if (Platform.OS === 'ios') {
    const handle = (_event: DateTimePickerEvent, selected?: Date) => {
      if (selected) onChange(selected.getTime());
    };
    return (
      <View style={{ flexDirection: 'row', justifyContent: 'flex-end', gap: 8 }}>
        <DateTimePicker value={date} mode="date" display="compact" locale="fr-FR" timeZoneName={calendar.zone} onChange={handle} accentColor={theme.accent} />
        <DateTimePicker value={date} mode="time" display="compact" locale="fr-FR" timeZoneName={calendar.zone} onChange={handle} accentColor={theme.accent} />
      </View>
    );
  }

  const button = (label: string, onPress: () => void, accessibilityLabel: string) => (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      onPress={() => {
        tap();
        onPress();
      }}
      style={({ pressed }) => ({
        minHeight: 40,
        paddingHorizontal: 12,
        borderRadius: 10,
        justifyContent: 'center',
        backgroundColor: theme.track,
        opacity: pressed ? 0.6 : 1,
      })}
    >
      <Text style={{ fontSize: 16, fontWeight: '600', color: theme.textPrimary }}>{label}</Text>
    </Pressable>
  );

  const dayText = capitalizingFirstLetter(formatDay(value, calendar, false));
  const timeText = formatTime(value, calendar);

  if (Platform.OS === 'android') {
    const open = (mode: 'date' | 'time') =>
      DateTimePickerAndroid.open({
        value: date,
        mode,
        is24Hour: true,
        timeZoneName: calendar.zone,
        onChange: (event, selected) => {
          if (event.type === 'set' && selected) onChange(selected.getTime());
        },
      });
    return (
      <View style={{ flexDirection: 'row', justifyContent: 'flex-end', gap: 8, flexWrap: 'wrap' }}>
        {button(dayText, () => open('date'), `Date\u{a0}: ${dayText}`)}
        {button(timeText, () => open('time'), `Heure\u{a0}: ${timeText}`)}
      </View>
    );
  }

  // Web (no native picker): step the day and the time.
  const shift = (days: number, minutes: number) => onChange(calendar.addingDays(days, value) + minutes * 60_000);
  return (
    <View style={{ gap: 8, alignItems: 'flex-end' }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        {button('−', () => shift(-1, 0), 'Jour précédent')}
        <Text style={{ fontSize: 16, color: theme.textPrimary, minWidth: 150, textAlign: 'center' }}>{dayText}</Text>
        {button('+', () => shift(1, 0), 'Jour suivant')}
      </View>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        {button('−', () => shift(0, -30), '30 minutes plus tôt')}
        <Text style={{ fontSize: 16, color: theme.textPrimary, minWidth: 150, textAlign: 'center' }}>{timeText}</Text>
        {button('+', () => shift(0, 30), '30 minutes plus tard')}
      </View>
    </View>
  );
}
