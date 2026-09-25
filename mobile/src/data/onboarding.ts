import AsyncStorage from '@react-native-async-storage/async-storage';
import type { QueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';

import type { UserProfile } from '@/core/models';
import { shouldShowOnboarding } from '@/core/onboarding';

import { profiles } from './api';
import { keys } from './queries';

// When the onboarding shows, and how it ends (Swift `OnboardingStore`, `OnboardingViewModel.finish()`). Ending it
// (finished, or « Passer ») opens the tabs at once, then tells the server; until the server confirms, this device
// remembers it, never shows the onboarding again, and tells the server again at the next session.

function settledKey(userId: string): string {
  return `onboarding.settled.${userId}`;
}

function pendingKey(userId: string): string {
  return `onboarding.pendingCompletion.${userId}`;
}

/** Users whose onboarding ended on this device (read once from AsyncStorage). */
const settled = new Map<string, boolean>();
const retried = new Set<string>();

async function isSettled(userId: string): Promise<boolean> {
  const known = settled.get(userId);
  if (known !== undefined) return known;
  const stored = await AsyncStorage.getItem(settledKey(userId)).catch(() => null);
  const value = stored === 'true';
  settled.set(userId, value);
  return value;
}

/** A profile written by a PATCH keeps what only `profiles.mine()` reads (`onboardedAt`, `createdAt`). */
export function mergedProfile(updated: UserProfile, previous: UserProfile | undefined): UserProfile {
  return {
    ...updated,
    onboardedAt: updated.onboardedAt ?? previous?.onboardedAt ?? null,
    createdAt: updated.createdAt ?? previous?.createdAt ?? null,
  };
}

/**
 * Whether the onboarding shows for `profile`: null until it is known (the local mark is being read). Also retries a
 * completion the server has not confirmed yet.
 */
export function useOnboardingGate(userId: string, profile: UserProfile | undefined): boolean | null {
  const [settledHere, setSettledHere] = useState<boolean | null>(settled.get(userId) ?? null);

  useEffect(() => {
    let active = true;
    void isSettled(userId).then((value) => {
      if (active) setSettledHere(value);
    });
    return () => {
      active = false;
    };
  }, [userId]);

  useEffect(() => {
    if (!settledHere || !profile || profile.onboardedAt !== null || retried.has(userId)) return;
    retried.add(userId);
    void AsyncStorage.getItem(pendingKey(userId)).then((pending) => {
      if (pending === 'true') void confirmCompletion(userId);
    });
  }, [settledHere, profile, userId]);

  if (profile === undefined) return null;
  if (!shouldShowOnboarding(profile, Date.now())) return false;
  // The map first: `finishOnboarding` updates it before the profile re-renders this hook.
  const isDone = settled.get(userId) ?? settledHere;
  if (isDone === null) return null;
  return !isDone;
}

async function confirmCompletion(userId: string): Promise<void> {
  try {
    await profiles.completeOnboarding();
    await AsyncStorage.removeItem(pendingKey(userId)).catch(() => undefined);
  } catch {
    // Told again at the next session.
  }
}

/** Ends the onboarding: the tabs open at once (the cached profile is marked onboarded), then the server is told. */
export async function finishOnboarding(client: QueryClient, userId: string): Promise<void> {
  settled.set(userId, true);
  await AsyncStorage.multiSet([
    [settledKey(userId), 'true'],
    [pendingKey(userId), 'true'],
  ]).catch(() => undefined);
  client.setQueryData<UserProfile>(keys.profile, (profile) => (profile ? { ...profile, onboardedAt: Date.now() } : profile));
  await confirmCompletion(userId);
  void client.invalidateQueries({ queryKey: keys.profile });
}
