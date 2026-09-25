import { APP_ERROR_KINDS, AppError, type AppErrorKind, errorMessage, messageFR } from '../appError';
import { mapBackendError } from '../backendErrorMapper';

/** The French message of every error (docs/CONTRACTS-V2.md §13: « tu »). */
const MESSAGES: Record<Exclude<AppErrorKind, 'unknown'>, string> = {
  notAuthenticated: 'Ta session a expiré. Reconnecte-toi.',
  invalidCredentials: 'E-mail ou mot de passe incorrect.',
  emailAlreadyUsed: 'Un compte existe déjà avec cet e-mail.',
  weakPassword: 'Mot de passe trop faible (8 caractères minimum).',
  invalidEmail: 'Adresse e-mail invalide.',
  otpInvalid: 'Code invalide ou expiré.',
  emailRateLimited: 'Trop d’e-mails envoyés. Réessaie plus tard.',
  emailNotConfirmed: 'Confirme d’abord ton adresse e-mail.',
  invalidDisplayName: 'Le nom doit contenir entre 1 et 50 caractères.',
  invalidName: 'Le nom du groupe doit contenir entre 1 et 60 caractères.',
  invalidTitle: 'Le titre doit contenir entre 1 et 200 caractères.',
  invalidDetails: 'La description ne doit pas dépasser 5000 caractères.',
  invalidInput: 'Certaines informations sont invalides.',
  invalidCode: 'Code d’invitation invalide.',
  rateLimited: 'Trop de tentatives. Réessaie dans une heure.',
  lastAdmin: 'Tu es l’unique admin\u{a0}: nomme d’abord un autre admin.',
  notMember: 'Cette personne ne fait pas partie du groupe.',
  cannotRemoveSelf: 'Pour te retirer du groupe, utilise «\u{a0}Quitter le groupe\u{a0}».',
  assigneeNotMember: 'Une personne assignée ne fait pas partie du groupe.',
  tooManyAssignees: '20 personnes assignées au maximum.',
  invalidAppearance: 'Couleur ou emoji invalide.',
  invalidRecurrence: 'Répétition invalide.',
  recurrenceNeedsDueDate: 'Choisis une échéance pour répéter la tâche.',
  invalidRotation: 'Le tour de rôle demande de 2 à 20 membres du groupe.',
  invalidChecklistItem: 'Un élément doit contenir entre 1 et 200 caractères.',
  tooManyChecklistItems: '30 éléments au maximum.',
  forbidden: 'Action non autorisée.',
  forbiddenFields: 'Tu peux seulement changer le statut de cette tâche.',
  notFound: 'Élément introuvable. Il a peut-être été supprimé.',
  conflict: 'Cet élément existe déjà.',
  network: 'Connexion impossible. Vérifie ton réseau.',
  misconfigured: 'L’application n’est pas configurée (Supabase).',
};

describe('AppError messages', () => {
  it.each(Object.entries(MESSAGES))('%s reads its French message', (kind, message) => {
    expect(messageFR(kind as AppErrorKind)).toBe(message);
    expect(new AppError(kind as AppErrorKind).messageFR).toBe(message);
    expect(new AppError(kind as AppErrorKind).message).toBe(message);
  });

  it('covers every kind', () => {
    expect(APP_ERROR_KINDS.filter((kind) => kind !== 'unknown').sort()).toEqual(Object.keys(MESSAGES).sort());
  });

  it('wraps unknown details in the generic message', () => {
    expect(AppError.unknown('le serveur est momentanément indisponible, réessaie dans un instant').messageFR).toBe(
      'Une erreur est survenue. (le serveur est momentanément indisponible, réessaie dans un instant)',
    );
  });

  it('wraps any error and never shows a cancellation', () => {
    const error = new AppError('forbidden');
    expect(AppError.wrap(error)).toBe(error);
    expect(AppError.wrap(new Error('boom')).equals(AppError.unknown('boom'))).toBe(true);
    expect(AppError.wrap('texte').equals(AppError.unknown('texte'))).toBe(true);
    const abort = Object.assign(new Error('aborted'), { name: 'AbortError' });
    expect(AppError.wrap(abort).equals(AppError.unknown('annulé'))).toBe(true);
    expect(errorMessage(abort)).toBeNull();
    expect(errorMessage(error)).toBe('Action non autorisée.');
    expect(AppError.isAppError(error)).toBe(true);
    expect(AppError.isAppError(new Error('x'))).toBe(false);
  });
});

describe('BackendErrorMapper (docs/CONTRACTS.md §4.2)', () => {
  const kind = (code: string | null, message: string | null, status?: number) => {
    const error = mapBackendError(code, message, status);
    return error.kind === 'unknown' ? `unknown(${error.detail})` : error.kind;
  };

  it('maps the business codes by message', () => {
    const cases: Array<[string, AppErrorKind]> = [
      ['not_authenticated', 'notAuthenticated'],
      ['invalid_display_name', 'invalidDisplayName'],
      ['invalid_name', 'invalidName'],
      ['invalid_title', 'invalidTitle'],
      ['invalid_details', 'invalidDetails'],
      ['invalid_due_at', 'invalidInput'],
      ['invalid_input', 'invalidInput'],
      ['invalid_code', 'invalidCode'],
      ['rate_limited', 'rateLimited'],
      ['forbidden', 'forbidden'],
      ['forbidden_fields', 'forbiddenFields'],
      ['immutable_field', 'forbidden'],
      ['last_admin', 'lastAdmin'],
      ['not_member', 'notMember'],
      ['cannot_remove_self', 'cannotRemoveSelf'],
      ['assignee_not_member', 'assigneeNotMember'],
      ['too_many_assignees', 'tooManyAssignees'],
      ['task_not_found', 'notFound'],
      ['group_not_found', 'notFound'],
      // v2
      ['invalid_color', 'invalidAppearance'],
      ['invalid_emoji', 'invalidAppearance'],
      ['invalid_recurrence', 'invalidRecurrence'],
      ['recurrence_requires_due_date', 'recurrenceNeedsDueDate'],
      ['invalid_rotation', 'invalidRotation'],
      ['invalid_item_title', 'invalidChecklistItem'],
      ['too_many_items', 'tooManyChecklistItems'],
      ['item_not_found', 'notFound'],
    ];
    for (const [message, expected] of cases) {
      expect([message, kind('P0001', message, 400)]).toEqual([message, expected]);
    }
    // Whatever the status: the message decides.
    expect(kind('P0001', 'invalid_rotation', 500)).toBe('invalidRotation');
    expect(kind('23502', 'invalid_input', 400)).toBe('invalidInput');
    expect(kind('P0001', ' last_admin ', 400)).toBe('lastAdmin');
  });

  it('then the SQLSTATE, then the HTTP status', () => {
    expect(kind('42501', 'permission denied for table tasks', 401)).toBe('notAuthenticated');
    expect(kind('42501', 'permission denied for table tasks', 403)).toBe('forbidden');
    expect(kind('23505', 'duplicate key value', 409)).toBe('conflict');
    expect(kind('22P05', 'unsupported Unicode escape sequence', 400)).toBe('invalidInput');
    expect(kind('23514', 'check', 400)).toBe('invalidInput');
    expect(kind('23503', 'fk', 400)).toBe('notFound');
    expect(kind('PGRST116', 'no rows', 406)).toBe('notFound');
    expect(kind('PGRST301', 'JWT cryptographic operation failed', 401)).toBe('notAuthenticated');
    expect(kind('PGRST303', 'JWT expired', 401)).toBe('notAuthenticated');
    expect(kind(null, null, 404)).toBe('notFound');
    expect(kind('PGRST100', 'failed to parse filter', 400)).toBe('unknown(PGRST100 failed to parse filter)');
  });
});
