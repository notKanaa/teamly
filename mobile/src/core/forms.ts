import { AppError } from './appError';
import { initialsOf } from './frenchText';
import {
  validateDisplayName,
  validateEmail,
  validateGroupName,
  validatePassword,
} from './inputValidation';
import { INVITE_CODE_LENGTH, normalizeInviteCode } from './inviteCode';
import type { ColorKey } from './colorKey';
import type { JoinResult } from './models';
import type { AvatarAppearance } from './presentation';

// Field rules and texts of the forms (Swift `SignUpViewModel`, `PasswordResetViewModel`, `CreateGroupViewModel`,
// `JoinGroupViewModel`, `LoginViewModel`).

// MARK: - Connexion

export const PASSWORD_MISSING_MESSAGE = 'Saisis ton mot de passe.';

// MARK: - Inscription

export const PASSWORD_TOO_LONG_MESSAGE = 'Mot de passe trop long (72 caractères maximum).';
export const CONFIRMATION_REQUIRED_MESSAGE =
  'Compte créé. Confirme ton adresse e-mail grâce au lien reçu, puis connecte-toi.';

export function emailMessage(email: string): string | null {
  try {
    validateEmail(email);
    return null;
  } catch {
    return new AppError('invalidEmail').messageFR;
  }
}

export function passwordMessage(password: string): string | null {
  try {
    validatePassword(password);
    return null;
  } catch (error) {
    if (AppError.isAppError(error) && error.kind === 'weakPassword') return error.messageFR;
    return PASSWORD_TOO_LONG_MESSAGE;
  }
}

export function displayNameMessage(name: string): string | null {
  try {
    validateDisplayName(name);
    return null;
  } catch {
    return new AppError('invalidDisplayName').messageFR;
  }
}

// MARK: - Mot de passe oublié

export const RESET_CODE_LENGTH = 6;
export const RESET_MISMATCH_MESSAGE = 'Les mots de passe ne correspondent pas.';
export const RESET_INCOMPLETE_CODE_MESSAGE = 'Saisis les 6 chiffres du code reçu par e-mail.';
export const RESET_RESENT_MESSAGE = 'Un nouveau code vient d’être envoyé.';
export const RESET_DONE_MESSAGE = 'Ton mot de passe a été modifié.';
export const RESET_RECOVERY_ENDED_MESSAGE =
  'La session de réinitialisation a expiré avant l’enregistrement du nouveau mot de passe. Demande un nouveau code.';

/** « Si un compte existe pour … », after the code was sent (no account enumeration). */
export function resetCodeSentMessage(email: string): string {
  return `Si un compte existe pour ${email}, un code à 6 chiffres vient d’y être envoyé.`;
}

/** Keeps the ASCII digits, at most 6. */
export function sanitizedResetCode(input: string): string {
  return input.replace(/[^0-9]/g, '').slice(0, RESET_CODE_LENGTH);
}

// MARK: - Nouveau groupe

export const GROUP_NAME_MAX = 60;
export const GROUP_NAME_PLACEHOLDER = 'Coloc’, famille, asso…';

export function groupNameMessage(name: string): string | null {
  try {
    validateGroupName(name);
    return null;
  } catch {
    return new AppError('invalidName').messageFR;
  }
}

/** The group as it will look (initials of the name typed so far). */
export function groupPreview(name: string, color: ColorKey, emoji: string | null): AvatarAppearance {
  return { color, emoji, initials: initialsOf(name) };
}

// MARK: - Rejoindre un groupe

export const JOIN_PLACEHOLDER = 'ABCD-EFGH';
export const JOIN_INCOMPLETE_CODE_MESSAGE = 'Le code contient 8 caractères, par exemple ABCD-EFGH.';

export function isInviteCodeComplete(code: string): boolean {
  return normalizeInviteCode(code).length === INVITE_CODE_LENGTH;
}

/** « Tu as rejoint « X ». » / « Tu fais déjà partie de « X ». » */
export function joinResultMessage(result: JoinResult): string {
  return result.alreadyMember
    ? `Tu fais déjà partie de «\u{a0}${result.groupName}\u{a0}».`
    : `Tu as rejoint «\u{a0}${result.groupName}\u{a0}».`;
}
