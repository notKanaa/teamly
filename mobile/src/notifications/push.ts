import { AppError } from '@/core/appError';
import { rpc, send } from '@/data/rest';

// The optional ntfy push (docs/NOTIFICATIONS.md §3): a private topic per user, created by `enable_push()` and deleted
// by `disable_push()`. The server sends the pushes; the app only shows the topic and how to subscribe to it.

export const NTFY_SERVER = 'https://ntfy.sh';
/** The free ntfy app on the App Store. */
export const NTFY_APP_STORE_URL = 'https://apps.apple.com/app/ntfy/id1625396347';

export const PUSH_INSTRUCTION_STEPS = [
  'Installe l’application gratuite «\u{a0}ntfy\u{a0}» depuis l’App Store.',
  'Dans ntfy, touche «\u{a0}+\u{a0}» puis abonne-toi au sujet ci-dessous (serveur ntfy.sh).',
  'Une notification te prévient quand une tâche t’est assignée, même quand Équipe est fermée.',
] as const;
export const PUSH_PRIVACY_NOTE =
  'Garde ce sujet secret\u{a0}: toute personne qui le connaît peut voir quand une tâche t’est assignée (le titre de la tâche n’est jamais envoyé).';
export const PUSH_DISABLED_EXPLANATION =
  'Reçois une notification quand une tâche t’est assignée, même quand Équipe est fermée, grâce à l’application gratuite ntfy.';

/** The topic opened in the ntfy app. */
export function ntfyAppUrl(topic: string): string {
  return `ntfy://ntfy.sh/${topic}`;
}

/** My topic, or null when the push is off (`push_subscriptions?select=topic&user_id=eq.<me>`). */
export async function pushTopic(): Promise<string | null> {
  const rows = await send((me) => ({ path: 'push_subscriptions', query: [['select', 'topic'], ['user_id', `eq.${me}`]] }));
  const topic = Array.isArray(rows) ? (rows[0] as { topic?: unknown } | undefined)?.topic : undefined;
  return typeof topic === 'string' ? topic : null;
}

/** Creates the topic (or returns the existing one). */
export async function enablePush(): Promise<string> {
  const topic = await send(() => rpc('enable_push'));
  if (typeof topic !== 'string') throw AppError.unknown('sujet ntfy inattendu');
  return topic;
}

export async function disablePush(): Promise<void> {
  await send(() => rpc('disable_push'));
}
