import { useQueryClient } from '@tanstack/react-query';
import * as Notifications from 'expo-notifications';
import { router } from 'expo-router';
import { useEffect } from 'react';
import { AppState } from 'react-native';

import type { TaskItem } from '@/core/models';
import { keys, useMyTasks } from '@/data/queries';
import { supabase } from '@/data/supabase';

import { notificationRoute } from './planning';
import {
  cancelAllNotifications,
  configureNotifications,
  getAuthorization,
  notificationsSupported,
  requestAuthorization,
  resynchronize,
  synchronizeMyTasks,
  synchronizeWeeklyRecap,
} from './scheduler';
import { subscribeSettings } from './settings';

// The notification work of a signed-in session (docs/NOTIFICATIONS.md), mounted once by the (app) layout.

/** « Plus tard » on the onboarding's notifications step: the app does not ask by itself during this session. */
let promptDeferred = false;

export function deferNotificationPrompt() {
  promptDeferred = true;
}

/**
 * - reminders and new assignments: every time the « Mes tâches » query succeeds (it is kept loaded here), never with
 *   a list emptied by an error;
 * - « Récap du lundi »: at start, on return to the foreground and when the settings change;
 * - a tap opens the task (or « Mes tâches », or « Groupes » for the recap);
 * - the permission is asked once signed in, when `canPrompt` (not during the onboarding, which asks itself);
 * - leaving the signed-in app without a session (sign-out, account deleted) removes every notification.
 */
export function useNotifications(userId: string | null, canPrompt: boolean) {
  const client = useQueryClient();
  // Keeps « Mes tâches » loaded (and refetched on Realtime signals) even when its tab was never opened.
  useMyTasks();

  useEffect(() => {
    if (!notificationsSupported || !userId) return;
    configureNotifications();
    const sync = (data: unknown) => {
      if (Array.isArray(data)) void synchronizeMyTasks(userId, data as TaskItem[]);
    };
    const initial = client.getQueryState(keys.myTasks);
    if (initial?.status === 'success') sync(initial.data);
    const unsubscribeCache = client.getQueryCache().subscribe((event) => {
      if (event.type !== 'updated' || event.action.type !== 'success') return;
      if (event.query.queryKey[0] !== keys.myTasks[0]) return;
      sync(event.query.state.data);
    });
    void synchronizeWeeklyRecap();
    const unsubscribeSettings = subscribeSettings(() => resynchronize());
    const appState = AppState.addEventListener('change', (state) => {
      // The permission may have changed in the system settings.
      if (state === 'active') resynchronize();
    });
    return () => {
      unsubscribeCache();
      unsubscribeSettings();
      appState.remove();
      // Signed out (or the account is gone): nothing of this user may fire any more.
      void supabase?.auth.getSession().then(({ data }) => {
        if (data.session === null) void cancelAllNotifications();
      });
    };
  }, [client, userId]);

  useEffect(() => {
    if (!notificationsSupported || !userId || !canPrompt || promptDeferred) return;
    void getAuthorization().then((status) => {
      if (status === 'notDetermined' && !promptDeferred) void requestAuthorization();
    });
  }, [userId, canPrompt]);

  useEffect(() => {
    if (!notificationsSupported || !userId) return;
    const open = (response: Notifications.NotificationResponse | null) => {
      if (!response) return;
      const request = response.notification.request;
      const key = `${request.identifier}@${response.notification.date}`;
      if (openedResponses.has(key)) return;
      openedResponses.add(key);
      const route = notificationRoute(request.identifier, request.content.data);
      // After the first render of the stack (a cold start from the notification).
      setTimeout(() => router.push(route as never), 0);
    };
    // The tap that launched the app, then every later one.
    void Notifications.getLastNotificationResponseAsync().then(open).catch(() => undefined);
    const subscription = Notifications.addNotificationResponseReceivedListener(open);
    return () => subscription.remove();
  }, [userId]);
}

/** Taps already handled in this process (the last response stays readable after a sign-in). */
const openedResponses = new Set<string>();
