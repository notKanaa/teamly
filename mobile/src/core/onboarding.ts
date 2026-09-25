import type { Instant } from './calendar';
import type { UserProfile } from './models';

/** A step of the onboarding, in display order (docs/CONTRACTS-V2.md §9). */
export type OnboardingStep = 'welcome' | 'avatar' | 'firstGroup' | 'notifications';

/** The notification permission, as the system reports it. */
export type NotificationAuthorization = 'notDetermined' | 'denied' | 'authorized';

/** Accounts at least this old never see the onboarding (it covers the accounts created with a v1 app). */
export const ONBOARDING_MAX_ACCOUNT_AGE_MS = 7 * 86_400 * 1000;

/**
 * After sign-in: true iff the onboarding was never completed and the account is less than 7 days old at `now`. False
 * when `createdAt` is unknown (a profile not read by `myProfile`).
 */
export function shouldShowOnboarding(profile: UserProfile, now: Instant): boolean {
  if (profile.onboardedAt !== null || profile.createdAt === null) return false;
  return now - profile.createdAt < ONBOARDING_MAX_ACCOUNT_AGE_MS;
}

/** The steps to show: « Premier groupe » is skipped with a group, the notifications step once the permission is decided. */
export function onboardingSteps(hasGroups: boolean, notifications: NotificationAuthorization): OnboardingStep[] {
  const steps: OnboardingStep[] = ['welcome', 'avatar'];
  if (!hasGroups) steps.push('firstGroup');
  if (notifications === 'notDetermined') steps.push('notifications');
  return steps;
}
