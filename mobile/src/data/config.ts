/**
 * The Supabase project of the app, from `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_KEY` (mobile/.env for the
 * hosted project; the process environment wins, e.g. for the local stack). The publishable key is public by design;
 * a secret key is refused so that it can never ship in the app.
 */
export interface SupabaseConfig {
  url: string;
  key: string;
}

/** Why the configuration cannot be used (shown on the « misconfigured » screen). */
export type ConfigProblem = 'missing' | 'invalidUrl' | 'secretKey';

export function readConfig(): { config: SupabaseConfig } | { problem: ConfigProblem } {
  // Expo inlines `process.env.EXPO_PUBLIC_*` at build time: they must be read with these exact member expressions.
  const url = (process.env.EXPO_PUBLIC_SUPABASE_URL ?? '').trim();
  const key = (process.env.EXPO_PUBLIC_SUPABASE_KEY ?? '').trim();
  if (url === '' || key === '') return { problem: 'missing' };
  if (!/^https?:\/\/[^\s/]+/.test(url)) return { problem: 'invalidUrl' };
  if (key.startsWith('sb_secret_') || /"role"\s*:\s*"service_role"/.test(decodeJwtPayload(key))) {
    return { problem: 'secretKey' };
  }
  return { config: { url: url.replace(/\/+$/, ''), key } };
}

/** The payload of a legacy JWT key (`eyJ…`), to recognize a service-role key; empty otherwise. */
function decodeJwtPayload(key: string): string {
  const part = key.split('.')[1];
  if (!key.startsWith('eyJ') || part === undefined) return '';
  try {
    const base64 = part.replace(/-/g, '+').replace(/_/g, '/');
    return typeof atob === 'function' ? atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, '=')) : '';
  } catch {
    return '';
  }
}
