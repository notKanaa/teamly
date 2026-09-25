import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';

import { FrenchCalendar } from '@/core/calendar';
import type { TaskItem } from '@/core/models';
import type { NotificationAuthorization } from '@/core/onboarding';
import type { Uuid } from '@/core/uuid';

import {
  planAssignments,
  planReminders,
  RECAP_BODY,
  RECAP_ID,
  RECAP_SCHEDULE,
  RECAP_TITLE,
  reconcileReminders,
  type LocalNotification,
} from './planning';
import { loadAssignmentState, loadSettings, saveAssignmentState } from './settings';

// The local notifications on expo-notifications (Swift `UserNotificationScheduler`, `ReminderReconciler`,
// `WeeklyRecapNotifier`), which work in Expo Go. Every change runs in one queue, one at a time; signing out bumps the
// epoch, which makes a change still queued or running do nothing more.

export const notificationsSupported = Platform.OS !== 'web';

let configured = false;

/** Banners also while the app is open; the Android channel. Idempotent. */
export function configureNotifications() {
  if (!notificationsSupported || configured) return;
  configured = true;
  Notifications.setNotificationHandler({
    handleNotification: async () => ({ shouldShowBanner: true, shouldShowList: true, shouldPlaySound: true, shouldSetBadge: false }),
  });
  if (Platform.OS === 'android') {
    void Notifications.setNotificationChannelAsync('default', {
      name: 'Équipe',
      importance: Notifications.AndroidImportance.DEFAULT,
    }).catch(() => undefined);
  }
}

// MARK: - Permission

function authorization(status: Notifications.NotificationPermissionsStatus): NotificationAuthorization {
  const ios = status.ios?.status;
  if (ios !== undefined) {
    if (ios === Notifications.IosAuthorizationStatus.NOT_DETERMINED) return 'notDetermined';
    return ios === Notifications.IosAuthorizationStatus.DENIED ? 'denied' : 'authorized';
  }
  if (status.granted) return 'authorized';
  return status.canAskAgain ? 'notDetermined' : 'denied';
}

export async function getAuthorization(): Promise<NotificationAuthorization> {
  if (!notificationsSupported) return 'denied';
  try {
    return authorization(await Notifications.getPermissionsAsync());
  } catch {
    return 'denied';
  }
}

/** Asks for the permission (the system shows its prompt once); once granted, everything is scheduled. */
export async function requestAuthorization(): Promise<NotificationAuthorization> {
  if (!notificationsSupported) return 'denied';
  let result: NotificationAuthorization;
  try {
    result = authorization(
      await Notifications.requestPermissionsAsync({ ios: { allowAlert: true, allowSound: true, allowBadge: true } }),
    );
  } catch {
    result = await getAuthorization();
  }
  if (result === 'authorized') resynchronize();
  return result;
}

// MARK: - Queue

let epoch = 0;
let queue: Promise<void> = Promise.resolve();

/** Runs `work` after the changes already queued; skipped when a sign-out happened since the call. */
function enqueue(work: (isCurrent: () => boolean) => Promise<void>): Promise<void> {
  const started = epoch;
  const isCurrent = () => epoch === started;
  queue = queue.then(() => (isCurrent() ? work(isCurrent) : undefined)).catch(() => undefined);
  return queue;
}

async function schedule(notification: LocalNotification): Promise<void> {
  await Notifications.scheduleNotificationAsync({
    identifier: notification.id,
    content: { title: notification.title, body: notification.body, data: notification.data },
    trigger:
      notification.fireAt === null
        ? null
        : { type: Notifications.SchedulableTriggerInputTypes.DATE, date: notification.fireAt, channelId: 'default' },
  });
}

async function pendingIds(): Promise<string[]> {
  return (await Notifications.getAllScheduledNotificationsAsync()).map((request) => request.identifier);
}

// MARK: - Synchronization

/** The last « Mes tâches » list loaded successfully, to resynchronize after a settings or permission change. */
let lastTasks: { userId: Uuid; tasks: readonly TaskItem[] } | null = null;

/**
 * Brings the due-date reminders in line with `tasks` (a successfully loaded « Mes tâches » list, never one emptied by
 * an error), and notifies the tasks newly assigned by someone else.
 */
export function synchronizeMyTasks(userId: Uuid, tasks: readonly TaskItem[]): Promise<void> {
  if (!notificationsSupported) return Promise.resolve();
  lastTasks = { userId, tasks };
  return enqueue(async (isCurrent) => {
    const authorized = (await getAuthorization()) === 'authorized';
    await synchronizeReminders(userId, tasks, authorized, isCurrent);
    await notifyAssignments(userId, tasks, authorized, isCurrent);
  });
}

async function synchronizeReminders(
  userId: Uuid,
  tasks: readonly TaskItem[],
  authorized: boolean,
  isCurrent: () => boolean,
): Promise<void> {
  const settings = await loadSettings();
  const desired = authorized
    ? planReminders({ tasks, userId, leadTime: settings.leadTime, now: Date.now(), calendar: FrenchCalendar.device() })
    : [];
  const { cancel, schedule: toSchedule } = reconcileReminders(await pendingIds(), desired);
  for (const id of cancel) await Notifications.cancelScheduledNotificationAsync(id).catch(() => undefined);
  for (const notification of toSchedule) {
    if (!isCurrent()) return;
    // A fire date that passed meanwhile is skipped.
    if (notification.fireAt !== null && notification.fireAt <= Date.now()) continue;
    await schedule(notification).catch(() => undefined);
  }
}

async function notifyAssignments(
  userId: Uuid,
  tasks: readonly TaskItem[],
  authorized: boolean,
  isCurrent: () => boolean,
): Promise<void> {
  const planned = planAssignments({ tasks, userId, state: await loadAssignmentState(userId), now: Date.now() });
  if (!isCurrent()) return;
  // Not authorized: nothing is shown, but the assignments count as handled.
  if (authorized) {
    for (const notification of planned.notifications) await schedule(notification).catch(() => undefined);
  }
  await saveAssignmentState(userId, planned.state);
}

/** Schedules « Récap du lundi » (every Monday at 09:00) when it is on and authorized, removes it otherwise. */
export function synchronizeWeeklyRecap(): Promise<void> {
  if (!notificationsSupported) return Promise.resolve();
  return enqueue(async (isCurrent) => {
    const settings = await loadSettings();
    const authorized = (await getAuthorization()) === 'authorized';
    const pending = (await pendingIds()).includes(RECAP_ID);
    if (!settings.weeklyRecap || !authorized) {
      if (pending) await Notifications.cancelScheduledNotificationAsync(RECAP_ID).catch(() => undefined);
      return;
    }
    if (pending || !isCurrent()) return;
    await Notifications.scheduleNotificationAsync({
      identifier: RECAP_ID,
      content: { title: RECAP_TITLE, body: RECAP_BODY, data: {} },
      trigger: { type: Notifications.SchedulableTriggerInputTypes.WEEKLY, channelId: 'default', ...RECAP_SCHEDULE },
    }).catch(() => undefined);
  });
}

/** After a settings or permission change: the reminders of the last list, and the recap. */
export function resynchronize() {
  if (lastTasks) void synchronizeMyTasks(lastTasks.userId, lastTasks.tasks);
  void synchronizeWeeklyRecap();
}

/** Sign-out: every pending notification of this device goes, and nothing queued before runs. */
export async function cancelAllNotifications(): Promise<void> {
  epoch += 1;
  lastTasks = null;
  if (!notificationsSupported) return;
  await Notifications.cancelAllScheduledNotificationsAsync().catch(() => undefined);
}
