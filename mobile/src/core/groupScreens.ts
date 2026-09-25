import { messageFR } from './appError';
import type { FrenchCalendar, Instant } from './calendar';
import { automaticColor, type ColorKey } from './colorKey';
import { GROUP_NAME_MAX } from './forms';
import { dayOffset, formatTime, MONTH_NAMES } from './frenchDate';
import { frenchCount, initialsOf } from './frenchText';
import { activityDayTitle, activityText, recapPlace, recapStreak, type EmphasizedText } from './activityText';
import { trimmed } from './inputValidation';
import { formatInviteCode } from './inviteCode';
import type { ActivityEvent, ActivityKind, MemberRole, Membership, TeamGroup } from './models';
import { MemberDirectory, type AvatarAppearance, type PersonBadge } from './presentation';
import { codePointLength } from './unicode';
import type { Uuid } from './uuid';
import type { WeeklyRecap } from './weeklyRecap';

// The group sheets and screens of the v2 redesign (Swift `CreateGroupViewModel`, `MembersViewModel`,
// `GroupAppearanceViewModel`, `GroupActivityViewModel`, `InviteCodeSheet`), as pure functions for the React screens.

// MARK: - Nouveau groupe

/** « n/60 » of « Nouveau groupe », measured like the validation: code points of the trimmed name. */
export function groupNameLength(name: string): number {
  return codePointLength(trimmed(name));
}

export function isGroupNameTooLong(name: string): boolean {
  return groupNameLength(name) > GROUP_NAME_MAX;
}

/** « 15/60 ». */
export function groupNameCounterText(name: string): string {
  return `${groupNameLength(name)}/${GROUP_NAME_MAX}`;
}

export const CREATE_GROUP_FOOTER = 'Tu seras admin du groupe et pourras inviter d’autres personnes.';

/** Picking the selected emoji again removes it (null: the initials). */
export function toggledEmoji(current: string | null, option: string): string | null {
  return current === option ? null : option;
}

// MARK: - Rejoindre un groupe

export const JOIN_TITLE = 'Ton code d’invitation';
export const JOIN_HINT = 'Demande le code à un admin du groupe\u{a0}: 8 lettres ou chiffres, par exemple ABCD-EFGH.';
export const JOINED_TITLE = 'Bienvenue\u{a0}!';
export const ALREADY_MEMBER_TITLE = 'Déjà membre';

// MARK: - Code d’invitation

/** « Rejoins mon groupe « X » sur Équipe avec le code ABCD-EFGH ». `code` is the raw 8-character code. */
export function inviteShareText(groupName: string, code: string): string {
  return `Rejoins mon groupe «\u{a0}${groupName}\u{a0}» sur Équipe avec le code ${formatInviteCode(code)}`;
}

/** The explanation of the invite sheet. */
export function inviteExplanation(groupName: string): string {
  return `Partage ce code avec les personnes à inviter dans «\u{a0}${groupName}\u{a0}». Elles le saisiront dans «\u{a0}Rejoindre un groupe\u{a0}».`;
}

export const INVITE_VALIDITY_TEXT = 'Le code reste valable jusqu’à ce qu’un admin en génère un nouveau.';
export const INVITE_FOOTER = 'Toute personne qui a ce code peut rejoindre le groupe.';
export const REGENERATE_TITLE = 'Générer un nouveau code\u{a0}?';
export const REGENERATE_MESSAGE = 'L’ancien code ne fonctionnera plus. Les membres actuels restent dans le groupe.';
export const INVITE_ADMINS_ONLY_TITLE = 'Code réservé aux admins';
export const INVITE_ADMINS_ONLY_MESSAGE = 'Seuls les admins du groupe peuvent voir et partager le code d’invitation.';

// MARK: - Membres

/** The members screen's state: the members, the current user and their role. */
export interface MembersState {
  members: readonly Membership[];
  userId: Uuid;
  myRole: MemberRole | null;
}

export function isMe(state: MembersState, member: Membership): boolean {
  return member.user.id === state.userId;
}

/** « Camille Martin (toi) » for the current user. */
export function memberDisplayName(state: MembersState, member: Membership): string {
  return isMe(state, member) ? `${member.user.displayName} (toi)` : member.user.displayName;
}

function adminCount(state: MembersState): number {
  return state.members.filter((member) => member.role === 'admin').length;
}

/** Admins can change anyone's role; their own only while another admin exists. */
export function canChangeRole(state: MembersState, member: Membership): boolean {
  if (state.myRole !== 'admin') return false;
  return !isMe(state, member) || member.role !== 'admin' || adminCount(state) > 1;
}

/** Admins can remove anyone but themselves (they use « Quitter le groupe »). */
export function canRemoveMember(state: MembersState, member: Membership): boolean {
  return state.myRole === 'admin' && !isMe(state, member);
}

/** « Nommer admin » / « Retirer le rôle d’admin ». */
export function roleActionTitle(member: Membership): string {
  return member.role === 'admin' ? 'Retirer le rôle d’admin' : 'Nommer admin';
}

/** The only member: leaving deletes the group. */
export function isLastMember(state: MembersState): boolean {
  return state.members.length === 1 && state.members[0]?.user.id === state.userId;
}

/** The only admin while other members remain: leaving is refused. */
export function isLastAdmin(state: MembersState): boolean {
  return state.myRole === 'admin' && adminCount(state) === 1 && state.members.length > 1;
}

/** Text of the « Quitter le groupe » confirmation (or why it is impossible). */
export function leaveConfirmationMessage(state: MembersState, groupName: string): string {
  if (isLastMember(state)) {
    return `Il ne reste que toi\u{a0}: le groupe «\u{a0}${groupName}\u{a0}» et toutes ses tâches seront supprimés.`;
  }
  if (isLastAdmin(state)) return messageFR('lastAdmin');
  return `Tu ne verras plus «\u{a0}${groupName}\u{a0}» ni ses tâches. Tes assignations dans ce groupe seront retirées.`;
}

/** The footer under « Quitter le groupe », or null. */
export function leaveFooter(state: MembersState, groupName: string): string | null {
  if (isLastAdmin(state)) return leaveConfirmationMessage(state, groupName);
  if (isLastMember(state)) return 'Tu es le seul membre\u{a0}: quitter le groupe le supprimera avec toutes ses tâches.';
  return null;
}

export function leaveConfirmTitle(state: MembersState): string {
  return isLastMember(state) ? 'Quitter et supprimer le groupe' : 'Quitter le groupe';
}

/** « « Coloc’ rue des Lilas » · 3 membres ». */
export function membersSectionTitle(groupName: string, count: number): string {
  return `«\u{a0}${groupName}\u{a0}» · ${frenchCount(count, 'membre', 'membres')}`;
}

export function removeMemberMessage(member: Membership, groupName: string): string {
  return `${member.user.displayName} n’aura plus accès à «\u{a0}${groupName}\u{a0}». Ses assignations dans ce groupe seront retirées.`;
}

export const SELF_DEMOTION_TITLE = 'Retirer ton rôle d’admin\u{a0}?';
export const SELF_DEMOTION_MESSAGE = 'Tu ne pourras plus gérer les membres, le code d’invitation ni le nom du groupe.';

/** « Membre depuis aujourd’hui », « … hier », « … le 14 septembre », « … le 1er décembre 2025 ». */
export function memberSinceText(joinedAt: Instant, now: Instant, calendar: FrenchCalendar): string {
  const offset = dayOffset(joinedAt, now, calendar);
  if (offset >= 0) return 'Membre depuis aujourd’hui';
  if (offset === -1) return 'Membre depuis hier';
  const { day, month, year } = calendar.components(joinedAt);
  let text = `le ${day === 1 ? '1er' : day} ${MONTH_NAMES[month - 1]}`;
  if (year !== calendar.components(now).year) text += ` ${year}`;
  return `Membre depuis ${text}`;
}

// MARK: - Apparence

export const APPEARANCE_TITLE = 'Apparence';

/** The color stored when `option` is picked: the automatic color of a group whose color is automatic stays null. */
export function appearanceColorChoice(group: TeamGroup, option: ColorKey): ColorKey | null {
  if (group.color === null && option === automaticColor(group.id)) return null;
  return option;
}

/** The group as it will look. */
export function appearancePreview(group: TeamGroup, color: ColorKey | null, emoji: string | null): AvatarAppearance {
  return { color: color ?? automaticColor(group.id), emoji, initials: initialsOf(group.name) };
}

export function appearanceHasChanges(group: TeamGroup, color: ColorKey | null, emoji: string | null): boolean {
  return color !== group.color || emoji !== group.emoji;
}

export function renameGroupMessage(): string {
  return `Le nouveau nom sera visible par tous les membres (${GROUP_NAME_MAX} caractères au maximum).`;
}

// MARK: - Activité

export const ACTIVITY_FEED_TITLE = 'Fil d’activité';
export const ACTIVITY_EMPTY_TITLE = 'Aucune activité';
export const ACTIVITY_EMPTY_MESSAGE = 'Rien pour l’instant\u{a0}: les tâches créées et terminées apparaîtront ici.';

/** One event of the feed, ready to display. */
export interface ActivityFeedRow {
  event: ActivityEvent;
  text: EmphasizedText;
  /** « 14:32 ». */
  timeText: string;
  /** The current member the event is about; null otherwise (draw the kind's tile). */
  person: PersonBadge | null;
}

export interface ActivityFeedSection {
  /** « Aujourd’hui », « Hier », « Lundi 21 septembre ». */
  title: string;
  rows: ActivityFeedRow[];
}

/** Who an event is about: the actor, the turn holder of `turn_started`, the member of the member events. */
export function activityPersonId(event: ActivityEvent): Uuid | null {
  switch (event.kind) {
    case 'task_created':
    case 'task_completed':
    case 'checklist_item_done':
      return event.actorId;
    case 'turn_started':
    case 'member_left':
      return event.subjectId;
    case 'member_joined':
      return event.subjectId ?? event.actorId;
  }
}

/** The feed by day, newest first. */
export function activityFeedSections(
  events: readonly ActivityEvent[],
  members: readonly Membership[],
  userId: Uuid,
  now: Instant,
  calendar: FrenchCalendar,
): ActivityFeedSection[] {
  const directory = new MemberDirectory(members, userId);
  const names = directory.shortNames;
  const sections: ActivityFeedSection[] = [];
  const byTitle = new Map<string, ActivityFeedSection>();
  for (const event of [...events].sort((a, b) => b.id - a.id)) {
    const personId = activityPersonId(event);
    const badge = personId === null ? null : directory.badge(personId);
    const row: ActivityFeedRow = {
      event,
      text: activityText(event, userId, names),
      timeText: formatTime(event.createdAt, calendar),
      person: badge?.isMember ? badge : null,
    };
    const title = activityDayTitle(event.createdAt, now, calendar);
    const section = byTitle.get(title);
    if (section) section.rows.push(row);
    else {
      const created = { title, rows: [row] };
      byTitle.set(title, created);
      sections.push(created);
    }
  }
  return sections;
}

/** The badge of an event kind: a color key (or the accent / neutral) and the glyph's meaning. */
export type ActivityBadgeTone = ColorKey | 'accent' | 'neutral';

export function activityBadgeTone(kind: ActivityKind): ActivityBadgeTone {
  switch (kind) {
    case 'task_created':
      return 'accent';
    case 'task_completed':
      return 'green';
    case 'turn_started':
      return 'coral';
    case 'checklist_item_done':
      return 'teal';
    case 'member_joined':
      return 'blue';
    case 'member_left':
      return 'neutral';
  }
}

/** A member of the weekly podium. */
export interface PodiumEntry {
  person: PersonBadge;
  count: number;
  /** 1, 2 or 3; members with the same count share a place. */
  place: number;
  /** « 1re », « 2e », « 3e ». */
  placeText: string;
}

/** The podium, first place first. */
export function podiumEntries(recap: WeeklyRecap, members: readonly Membership[], userId: Uuid): PodiumEntry[] {
  const directory = new MemberDirectory(members, userId);
  return recap.podium.map((entry) => {
    const place = 1 + recap.podium.filter((other) => other.count > entry.count).length;
    return { person: directory.badge(entry.user.id), count: entry.count, place, placeText: recapPlace(place) };
  });
}

/** The podium in stage order, the first place in the middle: 2nd, 1st, 3rd. */
export function podiumStageOrder<T>(entries: readonly T[]): T[] {
  if (entries.length === 3) return [entries[1]!, entries[0]!, entries[2]!];
  if (entries.length === 2) return [entries[1]!, entries[0]!];
  return [...entries];
}

/** « Inès mène pour la 3e semaine d’affilée. », null without a streak. */
export function recapStreakText(recap: WeeklyRecap, members: readonly Membership[], userId: Uuid): EmphasizedText | null {
  if (recap.streak === null) return null;
  const id = recap.streak.user.id;
  const directory = new MemberDirectory(members, userId);
  return recapStreak(directory.shortName(id), id === userId, recap.streak.weeks);
}
