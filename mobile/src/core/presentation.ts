import { automaticColor, type ColorKey, resolvedColor } from './colorKey';
import { firstName, frenchCount, groupShortName, initialsOf, UNKNOWN_INITIALS } from './frenchText';
import {
  type ChecklistItem,
  type MemberRole,
  type Membership,
  type TaskItem,
  type TaskPriority,
  type TaskStatus,
  type TeamGroup,
  type UserProfile,
  groupColor,
  profileColor,
} from './models';
import { compareNames, nameKey, namePrecedes } from './nameOrder';
import { recurrenceSummary } from './recurrenceText';
import { statusFilterLabel, type TaskFilter, type TaskStatusFilter } from './taskList';
import { compareUuids, type Uuid } from './uuid';

// French labels and ready-to-display values shared by the screens (Swift `Presentation.swift`,
// `PresentationV2.swift`), so that every screen words things the same way.

// MARK: - Labels

/** « À faire », « En cours », « Terminée ». */
export function statusLabel(status: TaskStatus): string {
  switch (status) {
    case 'todo':
      return 'À faire';
    case 'in_progress':
      return 'En cours';
    case 'done':
      return 'Terminée';
  }
}

/** Next status of the one-tap cycle: à faire → en cours → terminée → à faire. */
export function nextStatus(status: TaskStatus): TaskStatus {
  switch (status) {
    case 'todo':
      return 'in_progress';
    case 'in_progress':
      return 'done';
    case 'done':
      return 'todo';
  }
}

/** « Basse », « Moyenne », « Haute ». */
export function priorityLabel(priority: TaskPriority): string {
  switch (priority) {
    case 'low':
      return 'Basse';
    case 'medium':
      return 'Moyenne';
    case 'high':
      return 'Haute';
  }
}

/** Picker order: high first. */
export const PRIORITY_PICKER_ORDER: readonly TaskPriority[] = ['high', 'medium', 'low'];

/** « Admin », « Membre ». */
export function roleLabel(role: MemberRole): string {
  return role === 'admin' ? 'Admin' : 'Membre';
}

// MARK: - Appearance

/** How a person or a group is drawn: its (resolved) color, and its emoji or else its initials. */
export interface AvatarAppearance {
  color: ColorKey;
  emoji: string | null;
  /** « CM », « CR », « ? ». */
  initials: string;
}

/** What to draw on the color: the emoji, else the initials. */
export function avatarSymbol(appearance: AvatarAppearance): string {
  return appearance.emoji ?? appearance.initials;
}

/** Someone the app does not know (any more): the automatic color of the id, and « ? ». */
export function unknownAppearance(id: Uuid): AvatarAppearance {
  return { color: automaticColor(id), emoji: null, initials: UNKNOWN_INITIALS };
}

export function profileAppearance(profile: UserProfile): AvatarAppearance {
  return { color: profileColor(profile), emoji: profile.avatarEmoji, initials: initialsOf(profile.displayName) };
}

export function groupAppearance(group: TeamGroup): AvatarAppearance {
  return { color: groupColor(group), emoji: group.emoji, initials: initialsOf(group.name) };
}

/** The badge of a task's group from the « Mes tâches » fields; null when `groupName` is not filled. */
export function taskGroupAppearance(task: TaskItem): AvatarAppearance | null {
  if (task.groupName === null) return null;
  return { color: resolvedColor(task.groupColor, task.groupId), emoji: task.groupEmoji, initials: initialsOf(task.groupName) };
}

/** The curated emojis of the pickers (all valid emojis for the server). */
export const EMOJI_CHOICES = {
  avatars: [
    '\u{1F98A}',
    '\u{1F43C}',
    '\u{1F438}',
    '\u{1F981}',
    '\u{1F419}',
    '\u{1F33B}',
    '\u{26A1}',
    '\u{1F431}',
    '\u{1F436}',
    '\u{1F43B}',
    '\u{1F428}',
    '\u{1F42F}',
    '\u{1F435}',
    '\u{1F984}',
    '\u{1F422}',
    '\u{1F41D}',
    '\u{1F308}',
    '\u{1F335}',
    '\u{1F340}',
    '\u{1F355}',
    '\u{2B50}',
    '\u{1F525}',
    '\u{1F680}',
  ],
  groups: [
    '\u{1F3E0}',
    '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}',
    '\u{26BD}',
    '\u{1F393}',
    '\u{1F4BC}',
    '\u{1F389}',
    '\u{1F3E1}',
    '\u{1F373}',
    '\u{1F9F9}',
    '\u{1F6D2}',
    '\u{1F331}',
    '\u{1F43E}',
    '\u{1F3B5}',
    '\u{1F3AE}',
    '\u{2708}\u{FE0F}',
    '\u{1F3D6}\u{FE0F}',
    '\u{1F6B2}',
    '\u{1F4DA}',
  ],
} as const;

// MARK: - People

/** A person as the screens show them: names and avatar. */
export interface PersonBadge {
  id: Uuid;
  /** Display name; « Ancien membre » for someone who is not a member (any more). */
  name: string;
  /** First name, or the display name when another member has the same first name. */
  shortName: string;
  appearance: AvatarAppearance;
  isMe: boolean;
  /** False for someone who left the group, or a deleted account. */
  isMember: boolean;
}

export const FORMER_MEMBER_NAME = 'Ancien membre';
export const ME_NAME = 'Toi';
export const UNASSIGNED_TEXT = 'Non assignée';

/** Display names of a group's members, as seen by the current user (Swift `MemberDirectory`). */
export class MemberDirectory {
  readonly members: readonly Membership[];
  readonly currentUserId: Uuid;
  private shortNamesCache: Map<Uuid, string> | null = null;

  constructor(members: readonly Membership[], currentUserId: Uuid) {
    this.members = members;
    this.currentUserId = currentUserId;
  }

  private member(userId: Uuid | null): Membership | undefined {
    if (userId === null) return undefined;
    return this.members.find((member) => member.user.id === userId);
  }

  /** The current user's role, null when not a member. */
  get myRole(): MemberRole | null {
    return this.role(this.currentUserId);
  }

  role(userId: Uuid): MemberRole | null {
    return this.member(userId)?.role ?? null;
  }

  /** Display name of a member, « Ancien membre » when unknown or null. */
  name(userId: Uuid | null): string {
    return this.member(userId)?.user.displayName ?? FORMER_MEMBER_NAME;
  }

  /** Names for a list: « Toi » first, then the others in name order. */
  names(userIds: readonly Uuid[]): string[] {
    let includesMe = false;
    const others: string[] = [];
    for (const userId of new Set(userIds)) {
      if (userId === this.currentUserId) includesMe = true;
      else others.push(this.name(userId));
    }
    others.sort(compareNames);
    return [...(includesMe ? [ME_NAME] : []), ...others];
  }

  /** « Toi, Lucas Bernard », or « Non assignée ». */
  assigneesText(userIds: readonly Uuid[]): string {
    const names = this.names(userIds);
    return names.length === 0 ? UNASSIGNED_TEXT : names.join(', ');
  }

  /** Every member's first name, or the whole display name when another member has the same first name. */
  get shortNames(): Map<Uuid, string> {
    if (this.shortNamesCache) return this.shortNamesCache;
    const people = this.members.map((member) => ({
      id: member.user.id,
      first: firstName(member.user.displayName),
      full: member.user.displayName,
    }));
    const counts = new Map<string, number>();
    for (const person of people) counts.set(nameKey(person.first), (counts.get(nameKey(person.first)) ?? 0) + 1);
    const names = new Map<Uuid, string>();
    for (const person of people) {
      const isShared = (counts.get(nameKey(person.first)) ?? 0) > 1;
      names.set(person.id, isShared || person.first === '' ? person.full : person.first);
    }
    this.shortNamesCache = names;
    return names;
  }

  /** Short name of a member, « Ancien membre » when unknown or null. */
  shortName(userId: Uuid | null): string {
    if (userId === null) return FORMER_MEMBER_NAME;
    return this.shortNames.get(userId) ?? FORMER_MEMBER_NAME;
  }

  /** The badge of a member, or of someone who is not a member (« Ancien membre », « ? »). */
  badge(userId: Uuid): PersonBadge {
    const member = this.member(userId);
    if (!member) {
      return {
        id: userId,
        name: FORMER_MEMBER_NAME,
        shortName: FORMER_MEMBER_NAME,
        appearance: unknownAppearance(userId),
        isMe: userId === this.currentUserId,
        isMember: false,
      };
    }
    return {
      id: userId,
      name: member.user.displayName,
      shortName: this.shortNames.get(userId) ?? member.user.displayName,
      appearance: profileAppearance(member.user),
      isMe: userId === this.currentUserId,
      isMember: true,
    };
  }

  /** The badges of `userIds`: the current user first, then by display name, then id. */
  badges(userIds: readonly Uuid[]): PersonBadge[] {
    return Array.from(new Set(userIds))
      .map((userId) => this.badge(userId))
      .sort((lhs, rhs) => {
        if (lhs.isMe !== rhs.isMe) return lhs.isMe ? -1 : 1;
        const order = namePrecedes(lhs.name, rhs.name);
        if (order !== null) return order ? -1 : 1;
        return compareUuids(lhs.id, rhs.id);
      });
  }

  /** Every member's badge, in the order of `members`. */
  get memberBadges(): PersonBadge[] {
    return this.members.map((member) => this.badge(member.user.id));
  }
}

// MARK: - Checklist

/** Progress of a task's checklist. */
export interface ChecklistProgress {
  done: number;
  total: number;
}

/** The progress of `items`; null for an empty checklist. */
export function checklistProgress(items: readonly ChecklistItem[]): ChecklistProgress | null {
  if (items.length === 0) return null;
  return { done: items.filter((item) => item.isDone).length, total: items.length };
}

export function progressFraction(progress: ChecklistProgress): number {
  return progress.total === 0 ? 0 : progress.done / progress.total;
}

export function progressIsComplete(progress: ChecklistProgress): boolean {
  return progress.total > 0 && progress.done === progress.total;
}

/** « 2/5 », for rows. */
export function progressCompactText(progress: ChecklistProgress): string {
  return `${progress.done}/${progress.total}`;
}

/** « 2 sur 5 », for the task screen. */
export function progressText(progress: ChecklistProgress): string {
  return `${progress.done} sur ${progress.total}`;
}

// MARK: - Task rows

export const ROTATION_LABEL = 'À tour de rôle';
export const MY_TURN_LABEL = 'Ton tour';

/** One row of a task list, ready to display (Swift `TaskRow`). */
export interface TaskRow {
  task: TaskItem;
  id: Uuid;
  title: string;
  status: TaskStatus;
  priority: TaskPriority;
  isDone: boolean;
  /** « Aujourd’hui à 20:00 », null without due date. */
  dueText: string | null;
  isOverdue: boolean;
  /** « Toi, Lucas Bernard » / « Non assignée »; null on screens that do not show assignees (« Mes tâches »). */
  assigneesText: string | null;
  /** Group name, « Mes tâches » only. */
  groupName: string | null;
  /** « Nouveau » badge (« Mes tâches » only). */
  isNew: boolean;
  canChangeStatus: boolean;
  canEdit: boolean;
  canDelete: boolean;
  /** v2, group screen: the assignees as badges, the current user first. */
  assignees: PersonBadge[];
  /** v2: a pending occurrence of a rotating task whose turn is the current user's. */
  isMyTurn: boolean;
  /** v2: « Chaque semaine », null for a plain task. */
  recurrenceText: string | null;
  hasRotation: boolean;
  checklistProgress: ChecklistProgress | null;
  /** v2, « Mes tâches »: the group's badge. */
  groupAppearance: AvatarAppearance | null;
  /** v2, « Mes tâches »: the group's short name for its chip (« Coloc’ »). */
  groupShortName: string | null;
}

export function makeTaskRow(fields: {
  task: TaskItem;
  dueText: string | null;
  isOverdue: boolean;
  assigneesText: string | null;
  groupName: string | null;
  isNew: boolean;
  canChangeStatus: boolean;
  canEdit: boolean;
  canDelete: boolean;
  assignees?: PersonBadge[];
  isMyTurn?: boolean;
}): TaskRow {
  const { task } = fields;
  return {
    ...fields,
    assignees: fields.assignees ?? [],
    isMyTurn: fields.isMyTurn ?? false,
    id: task.id,
    title: task.title,
    status: task.status,
    priority: task.priority,
    isDone: task.status === 'done',
    recurrenceText: task.recurrence === null ? null : recurrenceSummary(task.recurrence),
    hasRotation: task.rotation.length > 0,
    checklistProgress: checklistProgress(task.checklist),
    groupAppearance: fields.groupName === null ? null : taskGroupAppearance(task),
    groupShortName: fields.groupName === null ? null : groupShortName(fields.groupName),
  };
}

// MARK: - Filter chips

export type TaskFilterChipKind =
  | { kind: 'status'; status: TaskStatusFilter }
  | { kind: 'assignedToMe' }
  | { kind: 'overdue' };

/** A filter chip of a task list (« Toutes », « À faire », « En cours », « Terminées », « Assignées à moi », « En retard »). */
export interface TaskFilterChip {
  id: string;
  kind: TaskFilterChipKind;
  label: string;
  isSelected: boolean;
  /** v2, status chips of the group screen: the number of tasks the chip shows. */
  count: number | null;
  /** « À faire · 4 » with a count, the label otherwise. */
  countedLabel: string;
}

/** Status choices offered as chips, in display order. */
export const STATUS_CHIP_CHOICES: readonly TaskStatusFilter[] = ['all', 'todo', 'inProgress', 'done'];

function chip(kind: TaskFilterChipKind, id: string, label: string, isSelected: boolean, count: number | null): TaskFilterChip {
  return { id, kind, label, isSelected, count, countedLabel: count === null ? label : `${label} · ${count}` };
}

/** The chips describing `filter`, each status chip with its count from `counts` when present. */
export function filterChips(filter: TaskFilter, counts: Partial<Record<TaskStatusFilter, number>> = {}): TaskFilterChip[] {
  return [
    ...STATUS_CHIP_CHOICES.map((status) =>
      chip({ kind: 'status', status }, `status-${status}`, statusFilterLabel(status), filter.status === status, counts[status] ?? null),
    ),
    chip({ kind: 'assignedToMe' }, 'assignedToMe', 'Assignées à moi', filter.onlyAssignedToMe, null),
    chip({ kind: 'overdue' }, 'overdue', 'En retard', filter.onlyOverdue, null),
  ];
}

/** `filter` after a tap on a chip: a status chip selects its status (again: « Toutes »); the others toggle. */
export function togglingFilterChip(kind: TaskFilterChipKind, filter: TaskFilter): TaskFilter {
  switch (kind.kind) {
    case 'status':
      return { ...filter, status: filter.status === kind.status && kind.status !== 'all' ? 'all' : kind.status };
    case 'assignedToMe':
      return { ...filter, onlyAssignedToMe: !filter.onlyAssignedToMe };
    case 'overdue':
      return { ...filter, onlyOverdue: !filter.onlyOverdue };
  }
}

// MARK: - Groups overview (docs/CONTRACTS-V2.md §10)

/** A group as the groups list shows it: its members and task counts. */
export interface GroupOverview {
  groupId: Uuid;
  /** Admins first, then by name. */
  members: Membership[];
  /** Tasks not done (« N à faire »). */
  openTaskCount: number;
  /** Tasks done at or after `doneSince` (« X faites »). */
  doneTaskCount: number;
}

export const OVERVIEW_AVATAR_SLOTS = 3;
export const OVERVIEW_WEEK_TITLE = 'Cette semaine';

/** The avatars of the card: every member when they fit in 3 circles, else the first 2 (the last circle is « +N »). */
export function overviewMemberAvatars(overview: GroupOverview): AvatarAppearance[] {
  const shown = overview.members.length <= OVERVIEW_AVATAR_SLOTS ? overview.members.length : OVERVIEW_AVATAR_SLOTS - 1;
  return overview.members.slice(0, shown).map((member) => profileAppearance(member.user));
}

/** « +2 »: the members without an avatar on the card; null when every member has one. */
export function overviewMoreMembersText(overview: GroupOverview): string | null {
  const hidden = overview.members.length - overviewMemberAvatars(overview).length;
  return hidden > 0 ? `+${hidden}` : null;
}

/** « 3 membres », « 1 membre ». */
export function overviewMembersText(overview: GroupOverview): string {
  return frenchCount(overview.members.length, 'membre', 'membres');
}

/** « 4 à faire », « rien à faire ». */
export function overviewOpenText(overview: GroupOverview): string {
  return overview.openTaskCount === 0 ? 'rien à faire' : `${overview.openTaskCount} à faire`;
}

/** « 3 membres · 4 à faire ». */
export function overviewSummaryText(overview: GroupOverview): string {
  return `${overviewMembersText(overview)} · ${overviewOpenText(overview)}`;
}

/** Done this week plus still to do (the 13 of « 9 faites sur 13 »). */
export function overviewWeekTaskCount(overview: GroupOverview): number {
  return overview.doneTaskCount + overview.openTaskCount;
}

/** 0…1, for the progress bar (0 without any task). */
export function overviewWeekProgress(overview: GroupOverview): number {
  const total = overviewWeekTaskCount(overview);
  return total === 0 ? 0 : overview.doneTaskCount / total;
}

/** « 9 faites sur 13 », « 1 faite sur 6 », « Rien de prévu ». */
export function overviewWeekProgressText(overview: GroupOverview): string {
  const total = overviewWeekTaskCount(overview);
  if (total === 0) return 'Rien de prévu';
  return `${frenchCount(overview.doneTaskCount, 'faite', 'faites')} sur ${total}`;
}

export { compareNames };
