import { AppError, isCancellation } from '@/core/appError';

import { mapPostgrestError, mapTransportError, UNEXPECTED_ANSWER } from './errors';
import { requireSupabase, supabaseConfig } from './supabase';

// Minimal PostgREST client (Swift `RestClient`): every request is built here with the exact query strings of
// docs/CONTRACTS.md §4.3, and the HTTP status of an error reaches the mapper (401 vs 403 matters for `42501`).

export type QueryItem = readonly [name: string, value: string];

export interface RestRequest {
  method?: 'GET' | 'POST' | 'PATCH';
  /** Relative to `/rest/v1/`, e.g. `group_members` or `rpc/create_group`. */
  path: string;
  query?: readonly QueryItem[];
  body?: unknown;
  prefer?: string;
}

/** RFC 3986 unreserved characters plus the PostgREST syntax characters `* , : ( ) !` stay as is. */
function percentEncoded(value: string): string {
  return encodeURIComponent(value).replace(/%2A/g, '*').replace(/%2C/g, ',').replace(/%3A/g, ':');
}

export function encodedPathAndQuery(request: RestRequest): string {
  const query = request.query ?? [];
  if (query.length === 0) return request.path;
  return `${request.path}?${query.map(([name, value]) => `${percentEncoded(name)}=${percentEncoded(value)}`).join('&')}`;
}

interface Credentials {
  accessToken: string;
  userId: string;
}

async function credentials(): Promise<Credentials> {
  const { data } = await requireSupabase().auth.getSession();
  const session = data.session;
  if (session === null) throw new AppError('notAuthenticated');
  return { accessToken: session.access_token, userId: session.user.id.toLowerCase() };
}

async function refreshedCredentials(): Promise<Credentials> {
  const { data, error } = await requireSupabase().auth.refreshSession();
  if (error !== null || data.session === null) {
    await requireSupabase().auth.signOut({ scope: 'local' }).catch(() => undefined);
    throw new AppError('notAuthenticated');
  }
  return { accessToken: data.session.access_token, userId: data.session.user.id.toLowerCase() };
}

interface RestResponse {
  status: number;
  body: unknown;
  error: AppError | null;
}

async function response(request: RestRequest, creds: Credentials): Promise<RestResponse> {
  if (supabaseConfig === null) throw new AppError('misconfigured');
  const url = `${supabaseConfig.url}/rest/v1/${encodedPathAndQuery(request)}`;
  const headers: Record<string, string> = {
    apikey: supabaseConfig.key,
    Authorization: `Bearer ${creds.accessToken}`,
    Accept: 'application/json',
  };
  if (request.prefer) headers.Prefer = request.prefer;
  if (request.body !== undefined) headers['Content-Type'] = 'application/json';
  let answer: Response;
  try {
    answer = await fetch(url, {
      method: request.method ?? 'GET',
      headers,
      body: request.body === undefined ? undefined : JSON.stringify(request.body),
    });
  } catch (error) {
    if (isCancellation(error)) throw error;
    throw mapTransportError(error);
  }
  const text = await answer.text().catch(() => '');
  let body: unknown = null;
  let isJson = false;
  if (text !== '') {
    try {
      body = JSON.parse(text);
      isJson = true;
    } catch {
      body = null;
    }
  }
  if (answer.status >= 200 && answer.status < 300) {
    if (text !== '' && !isJson) return { status: answer.status, body: null, error: AppError.unknown(UNEXPECTED_ANSWER) };
    return { status: answer.status, body, error: null };
  }
  const errorBody = isJson && typeof body === 'object' && body !== null ? (body as { code?: string; message?: string }) : null;
  return { status: answer.status, body, error: mapPostgrestError(answer.status, errorBody) };
}

/**
 * Sends a request for the current session and returns the JSON body of a 2xx answer. A refused session is refreshed
 * once and the request sent again; a dead session fails to refresh, which signs the device out.
 */
export async function send(build: (me: string) => RestRequest): Promise<unknown> {
  const creds = await credentials();
  const first = await response(build(creds.userId), creds);
  if (first.error?.kind !== 'notAuthenticated') {
    if (first.error) throw first.error;
    return first.body;
  }
  const fresh = await refreshedCredentials();
  const second = await response(build(fresh.userId), fresh);
  if (second.error) throw second.error;
  return second.body;
}

/** Sends once and returns the raw answer (the account deletion reads the error itself). */
export async function sendRaw(request: RestRequest): Promise<RestResponse> {
  return response(request, await credentials());
}

export async function currentUserId(): Promise<string> {
  return (await credentials()).userId;
}

/** `POST /rest/v1/rpc/<name>` with named `p_…` parameters. */
export function rpc(name: string, params: Record<string, unknown> = {}): RestRequest {
  return { method: 'POST', path: `rpc/${name}`, body: params };
}
