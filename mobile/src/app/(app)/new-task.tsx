import { useQueryClient } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { errorMessage } from '@/core/appError';
import { FrenchCalendar } from '@/core/calendar';
import { makeDraft, type TaskPriority } from '@/core/models';
import { PRIORITY_PICKER_ORDER, priorityLabel, profileAppearance } from '@/core/presentation';
import { tasks } from '@/data/api';
import { keys, useMembers } from '@/data/queries';
import { useUserId } from '@/data/session';
import { Avatar, Card, ErrorText, Field, FilterChip, PrimaryButton, SecondaryButton, SegmentedPill } from '@/ui/components';
import { Screen } from '@/ui/Screen';
import { type as typo, useTheme } from '@/ui/theme';

type Due = 'none' | 'today' | 'tomorrow' | 'week';

const DUE_CHOICES: readonly { key: Due; label: string }[] = [
  { key: 'none', label: 'Sans échéance' },
  { key: 'today', label: 'Ce soir' },
  { key: 'tomorrow', label: 'Demain' },
  { key: 'week', label: 'Dans 7 jours' },
];

/** A quick « Nouvelle tâche » sheet: title, notes, due date, assignees, priority (the full editor is milestone 2). */
export default function NewTaskSheet() {
  const theme = useTheme();
  const client = useQueryClient();
  const userId = useUserId();
  const { groupId = '' } = useLocalSearchParams<{ groupId: string }>();
  const members = useMembers(groupId);
  const calendar = useMemo(() => FrenchCalendar.device(), []);
  const [title, setTitle] = useState('');
  const [details, setDetails] = useState('');
  const [due, setDue] = useState<Due>('none');
  const [priority, setPriority] = useState<TaskPriority>('medium');
  const [assignees, setAssignees] = useState<string[]>([userId]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const dueAt = (): number | null => {
    if (due === 'none') return null;
    const days = due === 'today' ? 0 : due === 'tomorrow' ? 1 : 7;
    const { year, month, day } = calendar.components(calendar.addingDays(days, Date.now()));
    return calendar.date(year, month, day, 20, 0);
  };

  const submit = async () => {
    setLoading(true);
    setError(null);
    try {
      await tasks.create(groupId, makeDraft({ title, details, priority, dueAt: dueAt(), assigneeIds: assignees }));
      void client.invalidateQueries({ queryKey: keys.group(groupId) });
      void client.invalidateQueries({ queryKey: keys.myTasks });
      void client.invalidateQueries({ queryKey: ['overviews'] });
      router.back();
    } catch (caught) {
      setError(errorMessage(caught));
    } finally {
      setLoading(false);
    }
  };

  const toggle = (id: string) => setAssignees((list) => (list.includes(id) ? list.filter((item) => item !== id) : [...list, id]));

  return (
    <Screen topInset={false} contentStyle={{ paddingTop: 20 }}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
        <Text style={[typo.title, { color: theme.textPrimary }]}>Nouvelle tâche</Text>
        <SecondaryButton title="Annuler" onPress={() => router.back()} />
      </View>
      <Card style={{ gap: 12 }}>
        <Field label="Titre" value={title} onChangeText={setTitle} placeholder="Sortir les poubelles" autoFocus maxLength={200} />
        <Field label="Notes" value={details} onChangeText={setDetails} multiline style={{ minHeight: 80, paddingTop: 12 }} />
      </Card>
      <Card style={{ gap: 10 }}>
        <Text style={[typo.headline, { color: theme.textPrimary }]}>Quand ?</Text>
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
          {DUE_CHOICES.map((choice) => (
            <FilterChip key={choice.key} label={choice.label} selected={due === choice.key} onPress={() => setDue(choice.key)} />
          ))}
        </View>
      </Card>
      <Card style={{ gap: 10 }}>
        <Text style={[typo.headline, { color: theme.textPrimary }]}>Qui s’en occupe ?</Text>
        {(members.data ?? []).map((member) => {
          const selected = assignees.includes(member.user.id);
          return (
            <Pressable
              key={member.user.id}
              onPress={() => toggle(member.user.id)}
              style={{ flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 44 }}
            >
              <Avatar appearance={profileAppearance(member.user)} size={32} />
              <Text style={[typo.body, { flex: 1, color: theme.textPrimary }]}>
                {member.user.id === userId ? 'Toi' : member.user.displayName}
              </Text>
              <View
                style={{
                  width: 24,
                  height: 24,
                  borderRadius: 12,
                  borderWidth: selected ? 0 : 2,
                  borderColor: theme.textSecondary,
                  backgroundColor: selected ? theme.accentFill : 'transparent',
                  alignItems: 'center',
                  justifyContent: 'center',
                }}
              >
                {selected ? <Text style={{ color: '#FFF', fontWeight: '800' }}>✓</Text> : null}
              </View>
            </Pressable>
          );
        })}
      </Card>
      <Card style={{ gap: 10 }}>
        <Text style={[typo.headline, { color: theme.textPrimary }]}>Priorité</Text>
        <SegmentedPill
          options={PRIORITY_PICKER_ORDER.map((key) => ({ key, label: priorityLabel(key) }))}
          value={priority}
          onChange={setPriority}
        />
      </Card>
      <ErrorText message={error} />
      <PrimaryButton title="Créer la tâche" onPress={submit} loading={loading} disabled={title.trim() === ''} />
    </Screen>
  );
}
