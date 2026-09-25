import type { FrenchCalendar, Instant } from './calendar';
import { relativeDateText } from './frenchDate';
import { frenchCount } from './frenchText';
import {
  hasRotation,
  isOverdue,
  type GroupSummary,
  type MemberRole,
  type Membership,
  type TaskItem,
  type TaskStatus,
} from './models';
import { sortedMembers } from './nameOrder';
import { canChangeTaskStatus, canDeleteTask, canEditTask } from './permissions';
import {
  filterChips,
  type GroupOverview,
  makeTaskRow,
  MemberDirectory,
  type PersonBadge,
  STATUS_CHIP_CHOICES,
  type TaskFilterChip,
  type TaskRow,
} from './presentation';
import { rotationHandover } from './rotation';
import { applyFilter, sortTasks, type TaskFilter, type TaskSort, type TaskStatusFilter } from './taskList';
import type { Uuid } from './uuid';

// The groups list and the group screen (Swift `GroupsListViewModel`, `GroupDetailViewModel`), as pure functions: the
// React screens keep the state (filter, tab) and call these with the loaded data.

// MARK: - Groups list

export const GROUPS_EMPTY_TITLE = 'Aucun groupe';
export const GROUPS_EMPTY_MESSAGE = 'Crée un groupe ou rejoins-en un avec un code d’invitation.';

/**
 * The overview of one group from the rows the backends read: members in any order, and the state of each task. A task
 * counts as open when it is not done, as done when it was completed at or after `doneSince`.
 */
export function makeGroupOverview(
  groupId: Uuid,
  members: readonly Membership[],
  tasks: ReadonlyArray<{ status: TaskStatus; completedAt: Instant | null }>,
  doneSince: Instant,
): GroupOverview {
  let open = 0;
  let done = 0;
  for (const task of tasks) {
    if (task.status !== 'done') open += 1;
    else if (task.completedAt !== null && task.completedAt >= doneSince) done += 1;
  }
  return { groupId, members: sortedMembers(members), openTaskCount: open, doneTaskCount: done };
}

/**
 * The header's summary: « 3 groupes · 11 tâches à faire », « 1 groupe · aucune tâche à faire »; only « 3 groupes »
 * while a listed group has no overview; null without groups.
 */
export function groupsHeaderText(
  groups: readonly GroupSummary[],
  overviews: ReadonlyMap<Uuid, GroupOverview> | null,
): string | null {
  if (groups.length === 0) return null;
  const groupsText = frenchCount(groups.length, 'groupe', 'groupes');
  const counts = groups.map((summary) => overviews?.get(summary.group.id)?.openTaskCount);
  if (counts.some((count) => count === undefined)) return groupsText;
  const open = counts.reduce<number>((sum, count) => sum + (count ?? 0), 0);
  const openText = open === 0 ? 'aucune tâche à faire' : `${frenchCount(open, 'tâche', 'tâches')} à faire`;
  return `${groupsText} · ${openText}`;
}

// MARK: - Group screen

export type GroupTab = 'tasks' | 'activity';

export function groupTabLabel(tab: GroupTab): string {
  return tab === 'tasks' ? 'Tâches' : 'Activité';
}

export const GROUP_GONE_MESSAGE = 'Ce groupe n’existe plus ou tu n’en fais plus partie.';
export const GROUP_EMPTY_MESSAGE = 'Aucune tâche pour l’instant.';
export const GROUP_NO_MATCH_MESSAGE = 'Aucune tâche ne correspond aux filtres.';
export const TURN_CARDS_TITLE = 'À qui le tour\u{a0}?';

/** « 3 membres · Tu es admin », « 2 membres · Tu es membre ». */
export function membersSummary(memberCount: number, myRole: MemberRole | null): string {
  const count = frenchCount(memberCount, 'membre', 'membres');
  if (myRole === 'admin') return `${count} · Tu es admin`;
  if (myRole === 'member') return `${count} · Tu es membre`;
  return count;
}

/** A pending occurrence of a rotating task whose turn is `userId`'s. */
export function isTurnOf(userId: Uuid, task: TaskItem): boolean {
  return task.status !== 'done' && hasRotation(task) && task.turnUserId === userId;
}

export interface GroupContext {
  tasks: readonly TaskItem[];
  members: readonly Membership[];
  myRole: MemberRole | null;
  userId: Uuid;
  now: Instant;
  calendar: FrenchCalendar;
}

/** Filtered and sorted tasks of the group screen, ready to display. */
export function groupTaskRows(context: GroupContext, filter: TaskFilter, sort: TaskSort = 'dueDate'): TaskRow[] {
  const directory = new MemberDirectory(context.members, context.userId);
  const { now, calendar, userId, myRole } = context;
  return sortTasks(sort, applyFilter(filter, context.tasks, userId, now)).map((task) =>
    makeTaskRow({
      task,
      dueText: task.dueAt === null ? null : relativeDateText(task.dueAt, now, calendar),
      isOverdue: isOverdue(task, now),
      assigneesText: directory.assigneesText(task.assigneeIds),
      groupName: null,
      isNew: false,
      canChangeStatus: canChangeTaskStatus(task, userId, myRole),
      canEdit: canEditTask(task, userId, myRole),
      canDelete: canDeleteTask(task, userId, myRole),
      assignees: directory.badges(task.assigneeIds),
      isMyTurn: isTurnOf(userId, task),
    }),
  );
}

/** The number of tasks a status chip shows, the other criteria of the filter applied. */
export function statusCount(context: GroupContext, filter: TaskFilter, status: TaskStatusFilter): number {
  return applyFilter({ ...filter, status }, context.tasks, context.userId, context.now).length;
}

/** The filter chips of the group screen, the status chips with their counts (« À faire · 4 »). */
export function groupFilterChips(context: GroupContext, filter: TaskFilter): TaskFilterChip[] {
  const counts: Partial<Record<TaskStatusFilter, number>> = {};
  for (const status of STATUS_CHIP_CHOICES) counts[status] = statusCount(context, filter, status);
  return filterChips(filter, counts);
}

/** A card of « À qui le tour ? »: a pending occurrence of a rotating task, whose turn it is and who comes next. */
export interface TurnCard {
  id: Uuid;
  task: TaskItem;
  title: string;
  dueText: string | null;
  isOverdue: boolean;
  current: PersonBadge | null;
  next: PersonBadge | null;
  isMyTurn: boolean;
  /** « puis Lucas », « puis toi »; null without a next person. */
  nextText: string | null;
}

/** The pending occurrences of the rotating tasks, by due date, the next turn computed like the server. */
export function turnCards(context: GroupContext): TurnCard[] {
  const directory = new MemberDirectory(context.members, context.userId);
  const memberIds = new Set(context.members.map((member) => member.user.id));
  const pending = context.tasks.filter((task) => task.status !== 'done' && hasRotation(task));
  return sortTasks('dueDate', pending).map((task) => {
    const handover = rotationHandover(task.rotation, task.turnUserId, (userId) => memberIds.has(userId));
    const nextId = handover.assigneeId !== null && handover.assigneeId !== task.turnUserId ? handover.assigneeId : null;
    const current = task.turnUserId === null ? null : directory.badge(task.turnUserId);
    const next = nextId === null ? null : directory.badge(nextId);
    return {
      id: task.id,
      task,
      title: task.title,
      dueText: task.dueAt === null ? null : relativeDateText(task.dueAt, context.now, context.calendar),
      isOverdue: isOverdue(task, context.now),
      current,
      next,
      isMyTurn: current?.isMe === true,
      nextText: next === null ? null : `puis ${next.isMe ? 'toi' : next.shortName}`,
    };
  });
}

/** « 2 tâches tournantes », null without rotating task. */
export function turnCardsSubtitle(cards: readonly TurnCard[]): string | null {
  return cards.length === 0 ? null : frenchCount(cards.length, 'tâche tournante', 'tâches tournantes');
}

/** Confirmation text of « Supprimer le groupe ». */
export function deleteGroupConfirmationMessage(name: string): string {
  return `Le groupe «\u{a0}${name}\u{a0}» et toutes ses tâches seront supprimés pour tous ses membres. Cette action est définitive.`;
}
