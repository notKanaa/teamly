import AsyncStorage from '@react-native-async-storage/async-storage';
import { useEffect, useState } from 'react';

import type { Instant } from '@/core/calendar';
import { lastSeenKey } from '@/core/myTasks';
import type { Uuid } from '@/core/uuid';

// The « last seen » mark of « Mes tâches » (the « Nouveau » badges), stored per user in AsyncStorage and shared in
// memory by the screen and the tab bar badge.

type Listener = (value: Instant | null) => void;

const values = new Map<Uuid, Instant | null>();
const listeners = new Map<Uuid, Set<Listener>>();
const loading = new Map<Uuid, Promise<void>>();

function emit(userId: Uuid, value: Instant | null) {
  values.set(userId, value);
  for (const listener of listeners.get(userId) ?? []) listener(value);
}

function load(userId: Uuid): Promise<void> {
  let promise = loading.get(userId);
  if (!promise) {
    promise = AsyncStorage.getItem(lastSeenKey(userId))
      .then((value) => {
        if (!values.has(userId)) emit(userId, value === null ? null : Number(value));
      })
      .catch(() => undefined);
    loading.set(userId, promise);
  }
  return promise;
}

/** Stores a new mark (« tout vu »). */
export function markSeen(userId: Uuid, mark: Instant) {
  if (!userId) return;
  emit(userId, mark);
  void AsyncStorage.setItem(lastSeenKey(userId), String(mark)).catch(() => undefined);
}

/** The stored mark; `undefined` while it is read, null when never set. */
export function useLastSeen(userId: Uuid): Instant | null | undefined {
  const [value, setValue] = useState<Instant | null | undefined>(() => (values.has(userId) ? values.get(userId) : undefined));
  useEffect(() => {
    if (!userId) return;
    const listener: Listener = (next) => setValue(next);
    let set = listeners.get(userId);
    if (!set) {
      set = new Set();
      listeners.set(userId, set);
    }
    set.add(listener);
    if (values.has(userId)) setValue(values.get(userId));
    else void load(userId);
    return () => {
      set.delete(listener);
    };
  }, [userId]);
  return value;
}
