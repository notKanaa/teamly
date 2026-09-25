import AsyncStorage from '@react-native-async-storage/async-storage';
import { useEffect, useState } from 'react';

import { DEFAULT_LEAD_TIME, EMPTY_ASSIGNMENT_STATE, isReminderLeadTime, type AssignmentState, type ReminderLeadTime } from './planning';

// The notification settings of this device (Swift `KeyValueStore` keys), in AsyncStorage. Changes are broadcast so
// that the scheduler resynchronizes and every screen showing them updates.

const LEAD_TIME_KEY = 'settings.reminderLeadTime';
const WEEKLY_RECAP_KEY = 'settings.weeklyRecapNotification';

export interface NotificationSettings {
  leadTime: ReminderLeadTime;
  /** « Récap du lundi »: on unless switched off. */
  weeklyRecap: boolean;
}

export const DEFAULT_SETTINGS: NotificationSettings = { leadTime: DEFAULT_LEAD_TIME, weeklyRecap: true };

let current: NotificationSettings | null = null;
const listeners = new Set<(settings: NotificationSettings) => void>();

export async function loadSettings(): Promise<NotificationSettings> {
  if (current) return current;
  try {
    const [lead, recap] = await Promise.all([AsyncStorage.getItem(LEAD_TIME_KEY), AsyncStorage.getItem(WEEKLY_RECAP_KEY)]);
    current = {
      leadTime: isReminderLeadTime(lead) ? lead : DEFAULT_SETTINGS.leadTime,
      weeklyRecap: recap === null ? DEFAULT_SETTINGS.weeklyRecap : recap === 'true',
    };
  } catch {
    current = DEFAULT_SETTINGS;
  }
  return current;
}

export async function updateSettings(change: Partial<NotificationSettings>): Promise<void> {
  const next = { ...(await loadSettings()), ...change };
  current = next;
  listeners.forEach((listener) => listener(next));
  await AsyncStorage.multiSet([
    [LEAD_TIME_KEY, next.leadTime],
    [WEEKLY_RECAP_KEY, String(next.weeklyRecap)],
  ]).catch(() => undefined);
}

export function subscribeSettings(listener: (settings: NotificationSettings) => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** The settings, kept up to date (the defaults until they are read). */
export function useNotificationSettings(): NotificationSettings {
  const [settings, setSettings] = useState<NotificationSettings>(current ?? DEFAULT_SETTINGS);
  useEffect(() => {
    let active = true;
    void loadSettings().then((loaded) => {
      if (active) setSettings(loaded);
    });
    const unsubscribe = subscribeSettings(setSettings);
    return () => {
      active = false;
      unsubscribe();
    };
  }, []);
  return settings;
}

// MARK: - Assignment state (per user)

function assignmentKey(userId: string): string {
  return `assignments.state.${userId}`;
}

export async function loadAssignmentState(userId: string): Promise<AssignmentState> {
  try {
    const raw = await AsyncStorage.getItem(assignmentKey(userId));
    if (raw === null) return EMPTY_ASSIGNMENT_STATE;
    const parsed = JSON.parse(raw) as Partial<AssignmentState>;
    return {
      cursor: typeof parsed.cursor === 'number' ? parsed.cursor : null,
      handled: Array.isArray(parsed.handled) ? parsed.handled.filter((key): key is string => typeof key === 'string') : [],
    };
  } catch {
    return EMPTY_ASSIGNMENT_STATE;
  }
}

export async function saveAssignmentState(userId: string, state: AssignmentState): Promise<void> {
  await AsyncStorage.setItem(assignmentKey(userId), JSON.stringify(state)).catch(() => undefined);
}
