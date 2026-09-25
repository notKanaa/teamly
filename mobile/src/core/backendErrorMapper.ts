import { AppError, type AppErrorKind } from './appError';

/**
 * Business error codes raised by the SQL functions and triggers (the exception message; docs/CONTRACTS.md §4.2,
 * docs/CONTRACTS-V2.md §3).
 */
export const MESSAGE_CODES: Readonly<Record<string, AppErrorKind>> = {
  not_authenticated: 'notAuthenticated',
  invalid_display_name: 'invalidDisplayName',
  invalid_name: 'invalidName',
  invalid_title: 'invalidTitle',
  invalid_details: 'invalidDetails',
  invalid_due_at: 'invalidInput',
  invalid_input: 'invalidInput',
  invalid_code: 'invalidCode',
  rate_limited: 'rateLimited',
  forbidden: 'forbidden',
  forbidden_fields: 'forbiddenFields',
  immutable_field: 'forbidden',
  last_admin: 'lastAdmin',
  not_member: 'notMember',
  cannot_remove_self: 'cannotRemoveSelf',
  assignee_not_member: 'assigneeNotMember',
  too_many_assignees: 'tooManyAssignees',
  task_not_found: 'notFound',
  group_not_found: 'notFound',
  // v2
  invalid_color: 'invalidAppearance',
  invalid_emoji: 'invalidAppearance',
  invalid_recurrence: 'invalidRecurrence',
  recurrence_requires_due_date: 'recurrenceNeedsDueDate',
  invalid_rotation: 'invalidRotation',
  invalid_item_title: 'invalidChecklistItem',
  too_many_items: 'tooManyChecklistItems',
  item_not_found: 'notFound',
};

/**
 * Maps a PostgREST / Postgres error to an `AppError`: by message first (the business code), then by SQLSTATE or
 * PostgREST code, then by HTTP status (`BackendErrorMapper.map(code:message:httpStatus:)`).
 */
export function mapBackendError(code: string | null | undefined, message: string | null | undefined, httpStatus?: number | null): AppError {
  const trimmedMessage = message?.trim();
  if (trimmedMessage && Object.prototype.hasOwnProperty.call(MESSAGE_CODES, trimmedMessage)) {
    return new AppError(MESSAGE_CODES[trimmedMessage]!);
  }
  // PostgREST answers a request without a valid session (anon role) with HTTP 401 + 42501; our own 42501 errors
  // ('forbidden', 'forbidden_fields') are HTTP 403 and matched above.
  if (code === '42501' && httpStatus === 401) return new AppError('notAuthenticated');
  switch (code) {
    case '42501':
      return new AppError('forbidden');
    case '23505':
      return new AppError('conflict');
    case '23514':
    case '22001':
    case '22P02':
    case '22P05':
    case '23502':
      return new AppError('invalidInput');
    case '23503':
      return new AppError('notFound');
    case 'PGRST116':
      return new AppError('notFound');
    case 'PGRST301':
    case 'PGRST302':
      return new AppError('notAuthenticated');
    default:
      break;
  }
  switch (httpStatus) {
    case 401:
      return new AppError('notAuthenticated');
    case 403:
      return new AppError('forbidden');
    case 404:
      return new AppError('notFound');
    case 409:
      return new AppError('conflict');
    default:
      break;
  }
  return AppError.unknown([code, message].filter((part): part is string => !!part).join(' '));
}
