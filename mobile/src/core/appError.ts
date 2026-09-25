/** Every error kind surfaced to the UI (Swift `AppError`); backends map their errors to these kinds. */
export const APP_ERROR_KINDS = [
  // Auth
  'notAuthenticated',
  'invalidCredentials',
  'emailAlreadyUsed',
  'weakPassword',
  'invalidEmail',
  'otpInvalid',
  'emailRateLimited',
  'emailNotConfirmed',
  // Input validation
  'invalidDisplayName',
  'invalidName',
  'invalidTitle',
  'invalidDetails',
  'invalidInput',
  // Groups / membership
  'invalidCode',
  'rateLimited',
  'lastAdmin',
  'notMember',
  'cannotRemoveSelf',
  // Tasks
  'assigneeNotMember',
  'tooManyAssignees',
  // v2 (docs/CONTRACTS-V2.md §3)
  'invalidAppearance',
  'invalidRecurrence',
  'recurrenceNeedsDueDate',
  'invalidRotation',
  'invalidChecklistItem',
  'tooManyChecklistItems',
  // Generic
  'forbidden',
  'forbiddenFields',
  'notFound',
  'conflict',
  'network',
  'misconfigured',
  'unknown',
] as const;
export type AppErrorKind = (typeof APP_ERROR_KINDS)[number];

/**
 * The French message of an error, addressing the user with « tu » (docs/CONTRACTS-V2.md §13), with the French
 * typography of the app (’ and no-break spaces).
 */
export function messageFR(kind: AppErrorKind, detail: string | null = null): string {
  switch (kind) {
    case 'notAuthenticated':
      return 'Ta session a expiré. Reconnecte-toi.';
    case 'invalidCredentials':
      return 'E-mail ou mot de passe incorrect.';
    case 'emailAlreadyUsed':
      return 'Un compte existe déjà avec cet e-mail.';
    case 'weakPassword':
      return 'Mot de passe trop faible (8 caractères minimum).';
    case 'invalidEmail':
      return 'Adresse e-mail invalide.';
    case 'otpInvalid':
      return 'Code invalide ou expiré.';
    case 'emailRateLimited':
      return 'Trop d’e-mails envoyés. Réessaie plus tard.';
    case 'emailNotConfirmed':
      return 'Confirme d’abord ton adresse e-mail.';
    case 'invalidDisplayName':
      return 'Le nom doit contenir entre 1 et 50 caractères.';
    case 'invalidName':
      return 'Le nom du groupe doit contenir entre 1 et 60 caractères.';
    case 'invalidTitle':
      return 'Le titre doit contenir entre 1 et 200 caractères.';
    case 'invalidDetails':
      return 'La description ne doit pas dépasser 5000 caractères.';
    case 'invalidInput':
      return 'Certaines informations sont invalides.';
    case 'invalidCode':
      return 'Code d’invitation invalide.';
    case 'rateLimited':
      return 'Trop de tentatives. Réessaie dans une heure.';
    case 'lastAdmin':
      return 'Tu es l’unique admin\u{a0}: nomme d’abord un autre admin.';
    case 'notMember':
      return 'Cette personne ne fait pas partie du groupe.';
    case 'cannotRemoveSelf':
      return 'Pour te retirer du groupe, utilise «\u{a0}Quitter le groupe\u{a0}».';
    case 'assigneeNotMember':
      return 'Une personne assignée ne fait pas partie du groupe.';
    case 'tooManyAssignees':
      return '20 personnes assignées au maximum.';
    case 'invalidAppearance':
      return 'Couleur ou emoji invalide.';
    case 'invalidRecurrence':
      return 'Répétition invalide.';
    case 'recurrenceNeedsDueDate':
      return 'Choisis une échéance pour répéter la tâche.';
    case 'invalidRotation':
      return 'Le tour de rôle demande de 2 à 20 membres du groupe.';
    case 'invalidChecklistItem':
      return 'Un élément doit contenir entre 1 et 200 caractères.';
    case 'tooManyChecklistItems':
      return '30 éléments au maximum.';
    case 'forbidden':
      return 'Action non autorisée.';
    case 'forbiddenFields':
      return 'Tu peux seulement changer le statut de cette tâche.';
    case 'notFound':
      return 'Élément introuvable. Il a peut-être été supprimé.';
    case 'conflict':
      return 'Cet élément existe déjà.';
    case 'network':
      return 'Connexion impossible. Vérifie ton réseau.';
    case 'misconfigured':
      return 'L’application n’est pas configurée (Supabase).';
    case 'unknown':
      return `Une erreur est survenue. (${detail ?? ''})`;
  }
}

const BRAND = '__equipeAppError';

/** An error of the app: a kind, plus a French detail for `unknown`. Thrown by the core and the data layer. */
export class AppError extends Error {
  readonly kind: AppErrorKind;
  /** The detail of `unknown` (French, shown in parentheses); null for the other kinds. */
  readonly detail: string | null;
  readonly [BRAND] = true;

  constructor(kind: AppErrorKind, detail: string | null = null) {
    super(messageFR(kind, detail));
    this.name = 'AppError';
    this.kind = kind;
    this.detail = kind === 'unknown' ? (detail ?? '') : null;
  }

  static unknown(detail: string): AppError {
    return new AppError('unknown', detail);
  }

  /** The message shown to the user. */
  get messageFR(): string {
    return messageFR(this.kind, this.detail);
  }

  /** Same kind and same detail. */
  is(kind: AppErrorKind, detail?: string): boolean {
    return this.kind === kind && (detail === undefined || this.detail === detail);
  }

  equals(other: AppError): boolean {
    return this.kind === other.kind && this.detail === other.detail;
  }

  /** True for an `AppError`, even across bundles or transpiled classes. */
  static isAppError(value: unknown): value is AppError {
    return typeof value === 'object' && value !== null && (value as Record<string, unknown>)[BRAND] === true;
  }

  /** Wraps any error into an `AppError` (already-mapped errors pass through; a cancellation is « annulé »). */
  static wrap(error: unknown): AppError {
    if (AppError.isAppError(error)) return error;
    if (isCancellation(error)) return AppError.unknown('annulé');
    if (error instanceof Error) return AppError.unknown(error.message);
    return AppError.unknown(String(error));
  }
}

/** A cancelled request (an aborted fetch): never shown to the user. */
export function isCancellation(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false;
  const name = (error as { name?: unknown }).name;
  return name === 'AbortError' || name === 'CancelledError';
}

/** The message to show for any error, or null for a cancellation (a cancelled load must not surface « annulé »). */
export function errorMessage(error: unknown): string | null {
  if (isCancellation(error)) return null;
  return AppError.wrap(error).messageFR;
}
