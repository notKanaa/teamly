import { automaticColor } from '../colorKey';
import {
  activityBadgeTone,
  activityFeedSections,
  activityPersonId,
  appearanceColorChoice,
  appearanceHasChanges,
  appearancePreview,
  canChangeRole,
  canRemoveMember,
  groupNameCounterText,
  inviteExplanation,
  inviteShareText,
  isGroupNameTooLong,
  isLastAdmin,
  isLastMember,
  leaveConfirmationMessage,
  leaveConfirmTitle,
  leaveFooter,
  memberDisplayName,
  memberSinceText,
  membersSectionTitle,
  type MembersState,
  podiumEntries,
  podiumStageOrder,
  recapStreakText,
  roleActionTitle,
  toggledEmoji,
} from '../groupScreens';
import { plainText } from '../activityText';
import { makeProfile, type ActivityEvent, type MemberRole, type Membership, type TeamGroup } from '../models';
import { computeWeeklyRecap } from '../weeklyRecap';
import { F } from './support';

const calendar = F.parisCalendar;
const camille = makeProfile({ id: F.me, displayName: 'Camille Martin' });
const ines = makeProfile({ id: F.uuid(0xc3), displayName: 'Inès Dubois' });
const lucas = makeProfile({ id: F.uuid(0xc2), displayName: 'Lucas Bernard' });
const member = (user = camille, role: MemberRole = 'member', joinedAt = F.date(2026, 9, 15)): Membership => ({
  groupId: F.groupA,
  user,
  role,
  joinedAt,
});
const now = F.date(2026, 9, 24, 10);
const group: TeamGroup = {
  id: F.groupA,
  name: 'Coloc\u{2019} rue des Lilas',
  createdBy: F.me,
  createdAt: F.date(2026, 1, 1),
  lastActivityAt: F.date(2026, 1, 1),
  color: null,
  emoji: '\u{1F3E0}',
};

describe('Nouveau groupe', () => {
  it('counts the trimmed name in code points', () => {
    expect(groupNameCounterText('  Club de lecture ')).toBe('15/60');
    expect(groupNameCounterText('\u{1F44D}\u{1F3FD}')).toBe('2/60');
    expect(isGroupNameTooLong('a'.repeat(60))).toBe(false);
    expect(isGroupNameTooLong('a'.repeat(61))).toBe(true);
  });

  it('clears the emoji picked again', () => {
    expect(toggledEmoji(null, '\u{1F3E0}')).toBe('\u{1F3E0}');
    expect(toggledEmoji('\u{1F3E0}', '\u{1F3E0}')).toBeNull();
    expect(toggledEmoji('\u{1F3E0}', '\u{26BD}')).toBe('\u{26BD}');
  });
});

describe('Code d’invitation', () => {
  it('words the share text and the explanation', () => {
    expect(inviteShareText('Coloc', 'LYLAS234')).toBe('Rejoins mon groupe «\u{a0}Coloc\u{a0}» sur Équipe avec le code LYLA-S234');
    expect(inviteExplanation('Coloc')).toBe(
      'Partage ce code avec les personnes à inviter dans «\u{a0}Coloc\u{a0}». Elles le saisiront dans «\u{a0}Rejoindre un groupe\u{a0}».',
    );
  });
});

describe('Membres', () => {
  const admins = (roles: [Membership['user'], MemberRole][], myRole: MemberRole | null = 'admin'): MembersState => ({
    members: roles.map(([user, role]) => member(user, role)),
    userId: F.me,
    myRole,
  });

  it('names the current user « (toi) »', () => {
    const state = admins([[camille, 'admin'], [ines, 'member']]);
    expect(memberDisplayName(state, state.members[0]!)).toBe('Camille Martin (toi)');
    expect(memberDisplayName(state, state.members[1]!)).toBe('Inès Dubois');
    expect(membersSectionTitle('Coloc', 3)).toBe('«\u{a0}Coloc\u{a0}» · 3 membres');
  });

  it('lets admins change roles, not the last admin’s own', () => {
    const alone = admins([[camille, 'admin'], [ines, 'member']]);
    expect(canChangeRole(alone, alone.members[0]!)).toBe(false);
    expect(canChangeRole(alone, alone.members[1]!)).toBe(true);
    expect(canRemoveMember(alone, alone.members[0]!)).toBe(false);
    expect(canRemoveMember(alone, alone.members[1]!)).toBe(true);
    const two = admins([[camille, 'admin'], [ines, 'admin']]);
    expect(canChangeRole(two, two.members[0]!)).toBe(true);
    const plain = admins([[camille, 'member'], [ines, 'admin']], 'member');
    expect(canChangeRole(plain, plain.members[1]!)).toBe(false);
    expect(canRemoveMember(plain, plain.members[1]!)).toBe(false);
    expect(roleActionTitle(two.members[0]!)).toBe('Retirer le rôle d’admin');
    expect(roleActionTitle(alone.members[1]!)).toBe('Nommer admin');
  });

  it('explains leaving', () => {
    const lastAdmin = admins([[camille, 'admin'], [ines, 'member']]);
    expect(isLastAdmin(lastAdmin)).toBe(true);
    expect(leaveFooter(lastAdmin, 'Coloc')).toBe('Tu es l’unique admin\u{a0}: nomme d’abord un autre admin.');
    const alone = admins([[camille, 'admin']]);
    expect(isLastMember(alone)).toBe(true);
    expect(isLastAdmin(alone)).toBe(false);
    expect(leaveConfirmTitle(alone)).toBe('Quitter et supprimer le groupe');
    expect(leaveConfirmationMessage(alone, 'Coloc')).toBe(
      'Il ne reste que toi\u{a0}: le groupe «\u{a0}Coloc\u{a0}» et toutes ses tâches seront supprimés.',
    );
    const plain = admins([[camille, 'member'], [ines, 'admin']], 'member');
    expect(leaveFooter(plain, 'Coloc')).toBeNull();
    expect(leaveConfirmTitle(plain)).toBe('Quitter le groupe');
    expect(leaveConfirmationMessage(plain, 'Coloc')).toBe(
      'Tu ne verras plus «\u{a0}Coloc\u{a0}» ni ses tâches. Tes assignations dans ce groupe seront retirées.',
    );
  });

  it('says since when someone is a member', () => {
    expect(memberSinceText(F.date(2026, 9, 15, 9), now, calendar)).toBe('Membre depuis le 15 septembre');
    expect(memberSinceText(F.date(2026, 9, 1, 9), now, calendar)).toBe('Membre depuis le 1er septembre');
    expect(memberSinceText(F.date(2025, 12, 3, 9), now, calendar)).toBe('Membre depuis le 3 décembre 2025');
    expect(memberSinceText(F.date(2026, 9, 23, 22), now, calendar)).toBe('Membre depuis hier');
    expect(memberSinceText(F.date(2026, 9, 25, 1), now, calendar)).toBe('Membre depuis aujourd’hui');
  });
});

describe('Apparence', () => {
  it('keeps an automatic color automatic', () => {
    const automatic = automaticColor(group.id);
    expect(appearanceColorChoice(group, automatic)).toBeNull();
    const other = automatic === 'pink' ? 'teal' : 'pink';
    expect(appearanceColorChoice(group, other)).toBe(other);
    expect(appearanceColorChoice({ ...group, color: other }, automatic)).toBe(automatic);
    expect(appearancePreview(group, null, null)).toEqual({ color: automatic, emoji: null, initials: 'CR' });
    expect(appearanceHasChanges(group, null, group.emoji)).toBe(false);
    expect(appearanceHasChanges(group, null, null)).toBe(true);
  });
});

describe('Activité', () => {
  const members = [member(camille, 'admin'), member(ines), member(lucas)];
  const event = (id: number, fields: Partial<ActivityEvent>): ActivityEvent => ({
    id,
    kind: 'task_completed',
    actorId: null,
    subjectId: null,
    taskId: null,
    taskTitle: null,
    itemTitle: null,
    createdAt: now,
    ...fields,
  });

  it('groups the feed by day, newest first, with the member concerned', () => {
    const sections = activityFeedSections(
      [
        event(1, { kind: 'member_joined', subjectId: F.uuid(0xde), createdAt: F.date(2026, 9, 23, 18) }),
        event(3, { actorId: ines.id, taskTitle: 'Arroser les plantes', createdAt: F.date(2026, 9, 24, 16, 52) }),
        event(2, { kind: 'turn_started', subjectId: F.me, taskTitle: 'Poubelles', createdAt: F.date(2026, 9, 24, 8, 5) }),
      ],
      members,
      F.me,
      F.date(2026, 9, 24, 18),
      calendar,
    );
    expect(sections.map((section) => section.title)).toEqual(['Aujourd’hui', 'Hier']);
    const [first, second] = sections[0]!.rows;
    expect(plainText(first!.text)).toBe('Inès a terminé «\u{a0}Arroser les plantes\u{a0}»');
    expect(first!.timeText).toBe('16:52');
    expect(first!.person?.shortName).toBe('Inès');
    expect(second!.person?.isMe).toBe(true);
    expect(sections[1]!.rows[0]!.person).toBeNull();
  });

  it('knows who an event is about and its badge', () => {
    expect(activityPersonId(event(1, { kind: 'member_left', actorId: F.me, subjectId: ines.id }))).toBe(ines.id);
    expect(activityPersonId(event(1, { kind: 'member_joined', actorId: ines.id }))).toBe(ines.id);
    expect(activityPersonId(event(1, { kind: 'task_created', actorId: lucas.id, subjectId: ines.id }))).toBe(lucas.id);
    expect(activityBadgeTone('task_completed')).toBe('green');
    expect(activityBadgeTone('member_left')).toBe('neutral');
  });

  it('builds the podium in stage order and the streak', () => {
    let counter = 0;
    const done = (userId: string, times: number, date = F.date(2026, 9, 22)) =>
      Array.from({ length: times }, () => ({ taskId: F.uuid((counter += 1)), completedBy: userId, completedAt: date }));
    const recap = computeWeeklyRecap(
      [...done(ines.id, 3), ...done(F.me, 2), ...done(lucas.id, 1), ...done(ines.id, 2, F.date(2026, 9, 15))],
      members,
      now,
      calendar,
    );
    const entries = podiumEntries(recap, members, F.me);
    expect(entries.map((entry) => [entry.person.shortName, entry.count, entry.placeText])).toEqual([
      ['Inès', 3, '1re'],
      ['Camille', 2, '2e'],
      ['Lucas', 1, '3e'],
    ]);
    expect(podiumStageOrder(entries).map((entry) => entry.place)).toEqual([2, 1, 3]);
    expect(podiumStageOrder([1, 2])).toEqual([2, 1]);
    expect(podiumStageOrder([1])).toEqual([1]);
    expect(plainText(recapStreakText(recap, members, F.me)!)).toBe('Inès mène pour la 2e semaine d’affilée.');
  });

  it('shares a place on ties', () => {
    const recap = computeWeeklyRecap(
      [
        { taskId: F.uuid(1), completedBy: ines.id, completedAt: F.date(2026, 9, 22) },
        { taskId: F.uuid(2), completedBy: lucas.id, completedAt: F.date(2026, 9, 22) },
      ],
      members,
      now,
      calendar,
    );
    expect(podiumEntries(recap, members, F.me).map((entry) => entry.place)).toEqual([1, 1]);
    expect(recapStreakText(recap, members, F.me)).toBeNull();
  });
});
