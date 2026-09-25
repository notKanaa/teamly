import 'react-native-url-polyfill/auto';

import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient, processLock, type SupabaseClient } from '@supabase/supabase-js';
import { AppState, Platform } from 'react-native';

import { AppError } from '@/core/appError';

import { readConfig } from './config';

// The Supabase client of the app, as in Supabase's Expo guide: the session is persisted in AsyncStorage
// (localStorage on the web), never read from the URL, and refreshed automatically while the app is in the
// foreground only.

const result = readConfig();

/** The client, or null when the app is not configured (the « misconfigured » screen is shown). */
export const supabase: SupabaseClient | null =
  'config' in result
    ? createClient(result.config.url, result.config.key, {
        auth: {
          storage: AsyncStorage,
          autoRefreshToken: true,
          persistSession: true,
          detectSessionInUrl: false,
          lock: processLock,
        },
      })
    : null;

export const configProblem = 'problem' in result ? result.problem : null;

/** The configured client; throws `misconfigured` otherwise (screens check `supabase` first). */
export function requireSupabase(): SupabaseClient {
  if (supabase === null) throw new AppError('misconfigured');
  return supabase;
}

if (supabase !== null && Platform.OS !== 'web') {
  // Refresh the session automatically only while the app is in the foreground (Supabase's guide): the client keeps
  // emitting TOKEN_REFRESHED or SIGNED_OUT, and Realtime gets the new token.
  AppState.addEventListener('change', (state) => {
    if (state === 'active') {
      supabase.auth.startAutoRefresh();
    } else {
      supabase.auth.stopAutoRefresh();
    }
  });
}
