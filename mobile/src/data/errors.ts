import { AppError, isCancellation } from '@/core/appError';
import { mapBackendError } from '@/core/backendErrorMapper';

// Maps every failure of the Supabase stack to `AppError` (docs/CONTRACTS.md §4.2, §9; Swift `SupabaseErrorMapping`).
// Nothing the server says in English reaches the user: the conditions without an `AppError` kind of their own become
// `unknown` with one of the French details below, which address the user with « tu » (docs/CONTRACTS-V2.md §13).

/** A malformed answer (not JSON, an HTML page of a captive portal, a missing field). */
export const UNEXPECTED_ANSWER = 'réponse inattendue du serveur';
/** Temporary server-side failure: 5xx, 429, PostgREST PGRST000–PGRST003, statement timeout, Auth timeouts. */
export const SERVER_UNAVAILABLE = 'le serveur est momentanément indisponible, réessaie dans un instant';
/** Supabase Auth request rate limit (a window of minutes). */
export const AUTH_RATE_LIMITED = 'trop de tentatives, réessaie dans quelques minutes';
/** The project's built-in SMTP only delivers to its team members until a custom SMTP server is configured. */
export const EMAIL_DELIVERY_UNAVAILABLE = 'l’envoi d’e-mails vers cette adresse n’est pas encore possible';
export const SIGNUP_DISABLED = 'les inscriptions sont fermées pour le moment';
export const EMAIL_PROVIDER_DISABLED = 'la connexion par e-mail est désactivée pour le moment';
export const USER_BANNED = 'ce compte est suspendu';
export const REAUTHENTICATION_NEEDED = 'reconnecte-toi, puis réessaie';
export const CAPTCHA_FAILED = 'la vérification de sécurité a échoué';

/** PostgREST codes of a database it cannot reach, and the statement timeout. */
const TEMPORARY_POSTGREST_CODES = new Set(['PGRST000', 'PGRST001', 'PGRST002', 'PGRST003', '57014']);

/** The JSON error body of PostgREST (`{code, message, details, hint}`), or null when the body was not JSON. */
export interface PostgrestErrorBody {
  code?: string | null;
  message?: string | null;
}

/**
 * A non-2xx PostgREST answer: the business code first, then the SQLSTATE, then the HTTP status. Temporary failures
 * become a retryable French message; an unusable body names the HTTP status.
 */
export function mapPostgrestError(status: number, body: PostgrestErrorBody | null): AppError {
  const mapped = mapBackendError(body?.code ?? null, body?.message ?? null, status);
  if (mapped.kind !== 'unknown') return mapped;
  const code = body?.code ?? null;
  if (status >= 500 || status === 429 || (code !== null && TEMPORARY_POSTGREST_CODES.has(code))) {
    return AppError.unknown(SERVER_UNAVAILABLE);
  }
  return mapped.detail ? mapped : AppError.unknown(`HTTP ${status}`);
}

/**
 * The error of a supabase-js PostgREST response: `status` 0 is a network failure (or a cancellation), a JSON error body
 * has a `code` key, a non-JSON body (an HTML page) only a `message`.
 */
export function mapPostgrestResponse(
  status: number,
  error: { code?: string | null; message?: string | null; details?: string | null } | null,
): AppError {
  if (status === 0) return new AppError('network');
  const isJsonBody = error !== null && typeof error === 'object' && 'code' in error;
  return mapPostgrestError(status, isJsonBody ? error : null);
}

/** Where an Auth error happened: a few codes mean something specific to one call. */
export type AuthContext = 'general' | 'signIn' | 'verifyOTP';

/** Supabase Auth error codes (`error_code`) → `AppError`. */
export function mapAuthCode(code: string, message: string, httpStatus: number, context: AuthContext = 'general'): AppError {
  if (context === 'signIn' && code === 'validation_failed') return new AppError('invalidCredentials');
  if (context === 'verifyOTP' && ['validation_failed', 'otp_disabled', 'invalid_credentials'].includes(code)) {
    return new AppError('otpInvalid');
  }
  switch (code) {
    case 'invalid_credentials':
      return new AppError('invalidCredentials');
    case 'user_already_exists':
    case 'email_exists':
      return new AppError('emailAlreadyUsed');
    case 'weak_password':
      return new AppError('weakPassword');
    case 'email_address_invalid':
      return new AppError('invalidEmail');
    case 'email_not_confirmed':
      return new AppError('emailNotConfirmed');
    case 'otp_expired':
      return new AppError('otpInvalid');
    case 'over_email_send_rate_limit':
      return new AppError('emailRateLimited');
    case 'over_request_rate_limit':
      return AppError.unknown(AUTH_RATE_LIMITED);
    case 'session_not_found':
    case 'session_expired':
    case 'refresh_token_not_found':
    case 'refresh_token_already_used':
    case 'bad_jwt':
    case 'no_authorization':
    case 'user_not_found':
      return new AppError('notAuthenticated');
    case 'validation_failed':
      return new AppError('invalidInput');
    case 'email_address_not_authorized':
      return AppError.unknown(EMAIL_DELIVERY_UNAVAILABLE);
    case 'signup_disabled':
      return AppError.unknown(SIGNUP_DISABLED);
    case 'email_provider_disabled':
      return AppError.unknown(EMAIL_PROVIDER_DISABLED);
    case 'user_banned':
      return AppError.unknown(USER_BANNED);
    case 'reauthentication_needed':
    case 'reauthentication_not_valid':
      return AppError.unknown(REAUTHENTICATION_NEEDED);
    case 'captcha_failed':
      return AppError.unknown(CAPTCHA_FAILED);
    case 'unexpected_failure':
    case 'request_timeout':
      return AppError.unknown(SERVER_UNAVAILABLE);
    default:
      break;
  }
  // Servers older than the `error_code` field: the historical messages.
  if (message === 'Invalid login credentials') return new AppError('invalidCredentials');
  if (message === 'User already registered') return new AppError('emailAlreadyUsed');
  if (httpStatus === 401) return new AppError('notAuthenticated');
  if (httpStatus === 429) return AppError.unknown(AUTH_RATE_LIMITED);
  if (httpStatus >= 500) return AppError.unknown(SERVER_UNAVAILABLE);
  // The server's message is English: only the code is shown (for support).
  return AppError.unknown(code === 'unknown' || code === '' ? UNEXPECTED_ANSWER : code);
}

interface AuthErrorLike {
  name?: string;
  message?: string;
  status?: number;
  code?: string;
  __isAuthError?: boolean;
}

/** Maps an error returned or thrown by supabase-js Auth. */
export function mapAuthError(error: unknown, context: AuthContext = 'general'): AppError {
  if (AppError.isAppError(error)) return error;
  if (isCancellation(error)) return AppError.wrap(error);
  if (typeof error === 'object' && error !== null && (error as AuthErrorLike).__isAuthError) {
    const authError = error as AuthErrorLike;
    switch (authError.name) {
      case 'AuthSessionMissingError':
        return new AppError('notAuthenticated');
      case 'AuthWeakPasswordError':
        return new AppError('weakPassword');
      case 'AuthRetryableFetchError':
        // No answer (offline) or a gateway failure.
        return authError.status && authError.status >= 500 ? AppError.unknown(SERVER_UNAVAILABLE) : new AppError('network');
      case 'AuthApiError':
        return mapAuthCode(authError.code ?? 'unknown', authError.message ?? '', authError.status ?? 0, context);
      default:
        return AppError.unknown(UNEXPECTED_ANSWER);
    }
  }
  return mapTransportError(error);
}

/** Network-level failures: `fetch` rejections are `network`; anything else is an unexpected answer. */
export function mapTransportError(error: unknown): AppError {
  if (AppError.isAppError(error)) return error;
  if (isCancellation(error)) return AppError.wrap(error);
  if (error instanceof TypeError) return new AppError('network');
  return AppError.unknown(UNEXPECTED_ANSWER);
}
