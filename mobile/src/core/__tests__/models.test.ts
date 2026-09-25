import { AUTOMATIC_COLOR_ORDER, automaticColor, COLOR_KEYS, resolvedColor, storedColor } from '../colorKey';
import { Limits } from '../limits';
import {
  ACTIVITY_KINDS,
  draftFromTask,
  groupColor,
  hasRotation,
  isRecurring,
  isRotationTurn,
  makeDraft,
  makeProfile,
  makeRule,
  makeTask,
  profileColor,
  sortedChecklist,
} from '../models';
import { onboardingSteps, shouldShowOnboarding } from '../onboarding';
import {
  canChangeTaskStatus,
  canDeleteTask,
  canEditRecurrence,
  canEditTask,
  canManageChecklist,
  GroupPermissions,
} from '../permissions';
import { F } from './support';

describe('ColorKey (docs/CONTRACTS-V2.md §1)', () => {
  it('stores the palette keys as texts', () => {
    expect(COLOR_KEYS).toEqual(['indigo', 'violet', 'blue', 'teal', 'green', 'amber', 'orange', 'coral', 'pink']);
    expect(AUTOMATIC_COLOR_ORDER).toEqual(['blue', 'indigo', 'violet', 'pink', 'orange', 'teal', 'green', 'coral', 'amber']);
    expect(new Set(AUTOMATIC_COLOR_ORDER)).toEqual(new Set(COLOR_KEYS));
  });

  /** Reference values computed independently (djb2 over the uppercase uuid string, UInt64 wrapping, % 9). */
  it.each([
    ['11111111-1111-4111-8111-111111111111', 'coral'],
    ['22222222-2222-4222-8222-222222222222', 'indigo'],
    ['33333333-3333-4333-8333-333333333333', 'green'],
    ['a0000000-0000-4000-8000-000000000001', 'pink'],
    ['A0000000-0000-4000-8000-000000000002', 'orange'],
    ['00000000-0000-0000-0000-000000000000', 'green'],
    ['FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF', 'teal'],
  ])('gives %s the automatic color %s', (id, expected) => {
    expect(automaticColor(id)).toBe(expected);
  });

  it('resolves colors', () => {
    const id = '11111111-1111-4111-8111-111111111111';
    expect(resolvedColor(null, id)).toBe('coral');
    expect(resolvedColor('teal', id)).toBe('teal');
    expect(profileColor(makeProfile({ id, displayName: 'Camille' }))).toBe('coral');
    expect(profileColor(makeProfile({ id, displayName: 'Camille', avatarColor: 'pink' }))).toBe('pink');
    const group = { id, name: 'G', createdBy: null, createdAt: 0, lastActivityAt: 0, color: null, emoji: null };
    expect(groupColor(group)).toBe('coral');
    expect(groupColor({ ...group, color: 'blue' })).toBe('blue');
    expect(storedColor('coral')).toBe('coral');
    expect(storedColor('Coral')).toBeNull();
    expect(storedColor(null)).toBeNull();
  });
});

describe('v2 models', () => {
  it('leaves the v2 fields empty by default', () => {
    const task = makeTask({ id: F.uuid(1), groupId: F.groupA, title: 'T', createdBy: F.me, createdAt: 0, updatedAt: 0 });
    expect(task.recurrence).toBeNull();
    expect(task.rotation).toEqual([]);
    expect(task.checklist).toEqual([]);
    expect(isRecurring(task) || hasRotation(task)).toBe(false);
    const draft = makeDraft({ title: 'T' });
    expect(draft.recurrence).toBeNull();
    expect(draft.rotation).toEqual([]);
    expect(draft.checklist).toEqual([]);
  });

  it('starts a full edit from the task', () => {
    const date = F.date(2026, 9, 24);
    const rule = makeRule({ frequency: 'monthly', timeZoneId: 'Europe/Paris', monthDay: 31 });
    const task = makeTask({
      id: F.uuid(1),
      groupId: F.groupA,
      title: 'Poubelles',
      details: 'Jaunes',
      priority: 'high',
      dueAt: date,
      createdBy: F.me,
      createdAt: date,
      updatedAt: date,
      assigneeIds: [F.other],
      recurrence: rule,
      rotation: [F.other, F.me],
      turnUserId: F.other,
      seriesId: F.uuid(1),
      checklist: [{ id: F.uuid(9), title: 'Sacs', position: 1, isDone: false, doneAt: null, doneBy: null }],
    });
    expect(isRecurring(task) && hasRotation(task)).toBe(true);
    expect(draftFromTask(task)).toEqual(
      makeDraft({ title: 'Poubelles', details: 'Jaunes', priority: 'high', dueAt: date, assigneeIds: [F.other], recurrence: rule, rotation: [F.other, F.me] }),
    );
  });

  it('orders a checklist by position, then id', () => {
    const item = (id: number, title: string, position: number) => ({ id: F.uuid(id), title, position, isDone: false, doneAt: null, doneBy: null });
    expect(sortedChecklist([item(3, 'C', 3), item(2, 'A', 3), item(1, 'B', 1)]).map((entry) => entry.title)).toEqual(['B', 'A', 'C']);
  });

  it('normalizes the weekdays of a rule', () => {
    expect(makeRule({ frequency: 'weekly', weekdays: [5, 1, 3, 1], timeZoneId: 'UTC' }).weekdays).toEqual([1, 3, 5]);
  });

  it('knows the stored activity kinds', () => {
    expect(ACTIVITY_KINDS).toEqual(['task_created', 'task_completed', 'turn_started', 'checklist_item_done', 'member_joined', 'member_left']);
  });

  it('recognizes the turns handed out by the server', () => {
    const event = (assignedBy: string | null, taskHasRotation: boolean) => ({
      taskId: F.uuid(1),
      groupId: F.groupA,
      taskTitle: 'T',
      groupName: 'G',
      assignedBy,
      assignedAt: 0,
      dueAt: null,
      taskHasRotation,
    });
    expect(isRotationTurn(event(null, true))).toBe(true);
    expect(isRotationTurn(event(F.other, true))).toBe(false);
    expect(isRotationTurn(event(null, false))).toBe(false);
  });

  it('pins the limits', () => {
    expect(Limits.checklistItemsMax).toBe(30);
    expect(Limits.checklistItemTitleMax).toBe(200);
    expect(Limits.rotationMin).toBe(2);
    expect(Limits.rotationMax).toBe(20);
    expect(Limits.repeatIntervalMax).toBe(52);
    expect(Limits.emojiCodePointsMax).toBe(16);
    expect(Limits.activityFeedMax).toBe(50);
    expect(Limits.activityRetentionDays).toBe(90);
  });
});

describe('Permissions (docs/CONTRACTS.md §2, CONTRACTS-V2.md §4)', () => {
  const admin = F.uuid(0xa0);
  const creator = F.uuid(0xa1);
  const assignee = F.uuid(0xa2);
  const other = F.uuid(0xa3);
  const task = makeTask({ id: F.uuid(1), groupId: F.groupA, title: 'Poubelles', createdBy: creator, createdAt: 0, updatedAt: 0, assigneeIds: [assignee] });

  it('follows the matrix', () => {
    // (user, role) → (edit, status, delete, recurrence, checklist)
    const cases: Array<[string, 'admin' | 'member' | null, boolean, boolean, boolean]> = [
      [admin, 'admin', true, true, true],
      [creator, 'member', true, true, true],
      [assignee, 'member', false, true, false],
      [other, 'member', false, false, false],
      [creator, null, false, false, false],
      [assignee, null, false, false, false],
    ];
    for (const [user, role, edit, status, remove] of cases) {
      expect([user, role, canEditTask(task, user, role)]).toEqual([user, role, edit]);
      expect(canChangeTaskStatus(task, user, role)).toBe(status);
      expect(canDeleteTask(task, user, role)).toBe(remove);
      expect(canEditRecurrence(task, user, role)).toBe(edit);
      expect(canManageChecklist(task, user, role)).toBe(status);
    }
    expect(GroupPermissions.canSetAppearance('admin')).toBe(true);
    expect(GroupPermissions.canSetAppearance('member')).toBe(false);
    expect(GroupPermissions.canSetAppearance(null)).toBe(false);
    expect(GroupPermissions.canSeeActivity('member')).toBe(true);
    expect(GroupPermissions.canSeeActivity(null)).toBe(false);
    expect(GroupPermissions.canSeeInviteCode('admin')).toBe(true);
    expect(GroupPermissions.canSeeInviteCode('member')).toBe(false);
  });
});

describe('OnboardingPolicy (docs/CONTRACTS-V2.md §9)', () => {
  const now = F.date(2026, 9, 24, 10);
  const profile = (createdAt: number | null, onboardedAt: number | null = null) =>
    makeProfile({ id: F.me, displayName: 'Camille', createdAt, onboardedAt });

  it('shows the onboarding to new accounts only', () => {
    const day = 86_400_000;
    expect(shouldShowOnboarding(profile(now), now)).toBe(true);
    expect(shouldShowOnboarding(profile(now - 7 * day + 1000), now)).toBe(true);
    expect(shouldShowOnboarding(profile(now - 7 * day), now)).toBe(false);
    expect(shouldShowOnboarding(profile(now - 30 * day), now)).toBe(false);
    expect(shouldShowOnboarding(profile(now, now), now)).toBe(false);
    expect(shouldShowOnboarding(profile(null), now)).toBe(false);
  });

  it('skips what is already done', () => {
    expect(onboardingSteps(false, 'notDetermined')).toEqual(['welcome', 'avatar', 'firstGroup', 'notifications']);
    expect(onboardingSteps(true, 'notDetermined')).toEqual(['welcome', 'avatar', 'notifications']);
    expect(onboardingSteps(false, 'authorized')).toEqual(['welcome', 'avatar', 'firstGroup']);
    expect(onboardingSteps(true, 'denied')).toEqual(['welcome', 'avatar']);
  });
});
