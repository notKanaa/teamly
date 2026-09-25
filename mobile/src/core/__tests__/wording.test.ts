import {
  activityDayTitle,
  activityText,
  emphasizedParts,
  plainText,
  RECAP_EMPTY_MESSAGE,
  recapPlace,
  recapRange,
  recapStreak,
  recapTotalLabel,
} from '../activityText';
import { automaticColor, COLOR_KEYS, colorLabel } from '../colorKey';
import { capitalizingFirstLetter, de, dePrefix, firstName, frenchCount, GROUP_SHORT_NAME_MAX, groupShortName, initialsOf, ordinal, quoted } from '../frenchText';
import { validateEmoji } from '../inputValidation';
import { ACTIVITY_KINDS, type ActivityEvent, type ActivityKind, makeProfile, makeRule, type Membership, type RecurrenceRule } from '../models';
import {
  checklistProgress,
  EMOJI_CHOICES,
  filterChips,
  groupAppearance,
  MemberDirectory,
  profileAppearance,
  progressCompactText,
  progressFraction,
  progressIsComplete,
  progressText,
  taskGroupAppearance,
  unknownAppearance,
} from '../presentation';
import { monthDayText, recurrenceDescription, recurrenceSummary, weekdaysText } from '../recurrenceText';
import { ALL_TASKS_FILTER } from '../taskList';
import { graphemes } from '../unicode';
import { F, typographyProblems } from './support';

describe('FrenchText', () => {
  it('quotes and elides', () => {
    expect(quoted('Lessive')).toBe('«\u{a0}Lessive\u{a0}»');
    expect(de('Lucas')).toBe('de Lucas');
    expect(de('Inès')).toBe('d’Inès');
    expect(de('Élodie')).toBe('d’Élodie');
    expect(de('Œdipe')).toBe('d’Œdipe');
    expect(de('un ancien membre')).toBe('d’un ancien membre');
    expect(de('Hugo')).toBe('de Hugo');
    expect(de('Yanis')).toBe('de Yanis');
    expect(dePrefix('Anna')).toBe('d’');
    expect(dePrefix('')).toBe('de ');
  });

  it('gives first names, ordinals and counts', () => {
    expect(firstName(' Camille Martin ')).toBe('Camille');
    expect(firstName('Jean-Pierre Durand')).toBe('Jean-Pierre');
    expect(firstName('Inès')).toBe('Inès');
    expect(firstName('   ')).toBe('');
    expect(ordinal(1)).toBe('1re');
    expect(ordinal(2)).toBe('2e');
    expect(ordinal(3)).toBe('3e');
    expect(frenchCount(0, 'tâche', 'tâches')).toBe('0 tâche');
    expect(frenchCount(1, 'tâche', 'tâches')).toBe('1 tâche');
    expect(frenchCount(2, 'tâche', 'tâches')).toBe('2 tâches');
    expect(capitalizingFirstLetter('aujourd’hui à 20:00')).toBe('Aujourd’hui à 20:00');
    expect(capitalizingFirstLetter('école')).toBe('École');
    expect(capitalizingFirstLetter('')).toBe('');
  });

  it('gives initials', () => {
    expect(initialsOf('Camille Martin')).toBe('CM');
    expect(initialsOf('Coloc’ rue des Lilas')).toBe('CR');
    expect(initialsOf('Jean-Pierre')).toBe('JP');
    expect(initialsOf('inès')).toBe('I');
    expect(initialsOf('\u{1F389} Fête')).toBe('F');
    expect(initialsOf('')).toBe('?');
    expect(initialsOf('  -  ')).toBe('?');
    expect(initialsOf('élodie durand')).toBe('ÉD');
  });

  it('gives group short names', () => {
    expect(groupShortName('Famille Martin')).toBe('Famille Martin');
    expect(groupShortName(' Coloc’ rue des Lilas ')).toBe('Coloc’');
    expect(groupShortName('Projet Asso Sport')).toBe('Projet');
    expect(groupShortName('Les copains du foot')).toBe('Copains');
    const long = groupShortName('Anticonstitutionnellement');
    expect(graphemes(long)).toHaveLength(GROUP_SHORT_NAME_MAX);
    expect(long.startsWith('Anticonstitu')).toBe(true);
    expect(long.endsWith('…')).toBe(true);
  });
});

describe('RecurrenceText', () => {
  const rule = (frequency: RecurrenceRule['frequency'], interval = 1, options: { weekdays?: number[]; monthDay?: number; zone?: string } = {}) =>
    makeRule({ frequency, interval, weekdays: options.weekdays ?? null, monthDay: options.monthDay ?? null, timeZoneId: options.zone ?? 'Europe/Paris' });

  it('summarizes the frequency', () => {
    expect(recurrenceSummary(rule('daily'))).toBe('Chaque jour');
    expect(recurrenceSummary(rule('daily', 2))).toBe('Tous les 2 jours');
    expect(recurrenceSummary(rule('weekly'))).toBe('Chaque semaine');
    expect(recurrenceSummary(rule('weekly', 2))).toBe('Toutes les 2 semaines');
    expect(recurrenceSummary(rule('monthly'))).toBe('Chaque mois');
    expect(recurrenceSummary(rule('monthly', 3))).toBe('Tous les 3 mois');
    expect(recurrenceSummary(rule('daily', 0))).toBe('Chaque jour');
  });

  it('describes the days', () => {
    const saturday = F.date(2026, 9, 26, 11);
    expect(recurrenceDescription(rule('daily'), saturday)).toBe('Chaque jour');
    expect(recurrenceDescription(rule('daily', 2), saturday)).toBe('Tous les 2 jours');
    expect(recurrenceDescription(rule('weekly'), saturday)).toBe('Chaque semaine, le samedi');
    expect(recurrenceDescription(rule('weekly', 2, { weekdays: [5, 2] }), saturday)).toBe('Toutes les 2 semaines, le mardi et le vendredi');
    expect(recurrenceDescription(rule('monthly'), F.date(2026, 9, 25, 18))).toBe('Chaque mois, le 25');
    expect(recurrenceDescription(rule('monthly'), F.date(2026, 10, 1, 18))).toBe('Chaque mois, le 1er');
    expect(recurrenceDescription(rule('monthly', 1, { monthDay: 31 }), F.date(2026, 9, 30, 18))).toBe('Chaque mois, le 31 ou le dernier jour du mois');
    expect(recurrenceDescription(rule('weekly', 1, { weekdays: [1, 3, 5] }), saturday)).toBe('Chaque semaine, le lundi, le mercredi et le vendredi');
    expect(recurrenceDescription(rule('weekly', 1, { weekdays: [1, 2, 3, 4, 5] }), null)).toBe('Chaque semaine, du lundi au vendredi');
    expect(recurrenceDescription(rule('weekly', 1, { weekdays: [1, 2, 3, 4, 5, 6, 7] }), null)).toBe('Chaque semaine, tous les jours');
    expect(recurrenceDescription(rule('weekly'), null)).toBe('Chaque semaine');
    expect(recurrenceDescription(rule('monthly'), null)).toBe('Chaque mois');
    expect(weekdaysText([])).toBeNull();
    expect(monthDayText(28)).toBe('le 28');
    expect(monthDayText(29)).toBe('le 29 ou le dernier jour du mois');
  });

  it('reads the days in the rule’s time zone', () => {
    // Saturday 26 September, 23:30 in Paris, is Sunday 27 in Tokyo.
    const due = F.date(2026, 9, 26, 23, 30);
    expect(recurrenceDescription(rule('weekly', 1, { zone: 'Asia/Tokyo' }), due)).toBe('Chaque semaine, le dimanche');
    expect(recurrenceDescription(rule('monthly', 1, { zone: 'Asia/Tokyo' }), due)).toBe('Chaque mois, le 27');
    expect(recurrenceDescription(rule('weekly'), due)).toBe('Chaque semaine, le samedi');
  });
});

describe('ActivityText', () => {
  const me = F.me;
  const lucas = F.uuid(0xc2);
  const ines = F.uuid(0xc3);
  const departed = F.uuid(0xde);
  const names = new Map([
    [me, 'Camille'],
    [lucas, 'Lucas'],
    [ines, 'Inès'],
  ]);
  const text = (
    kind: ActivityKind,
    fields: { actor?: string | null; subject?: string | null; task?: string | null; item?: string | null } = {},
  ) => {
    const event: ActivityEvent = {
      id: 1,
      kind,
      actorId: fields.actor ?? null,
      subjectId: fields.subject ?? null,
      taskId: F.uuid(1),
      taskTitle: fields.task === undefined ? 'Sortir les poubelles' : fields.task,
      itemTitle: fields.item ?? null,
      createdAt: F.date(2026, 9, 24),
    };
    return activityText(event, me, names);
  };
  const nb = '\u{a0}';

  it('words tasks and checklist items', () => {
    expect(plainText(text('task_created', { actor: lucas }))).toBe(`Lucas a créé «${nb}Sortir les poubelles${nb}»`);
    expect(emphasizedParts(text('task_created', { actor: lucas }))).toEqual(['Lucas']);
    expect(plainText(text('task_created', { actor: me }))).toBe(`Tu as créé «${nb}Sortir les poubelles${nb}»`);
    expect(plainText(text('task_completed', { actor: ines }))).toBe(`Inès a terminé «${nb}Sortir les poubelles${nb}»`);
    expect(plainText(text('task_completed', { actor: departed }))).toBe(`Un ancien membre a terminé «${nb}Sortir les poubelles${nb}»`);
    expect(plainText(text('task_completed', { actor: null, task: null }))).toBe('Un ancien membre a terminé une tâche');
    expect(plainText(text('checklist_item_done', { actor: ines, task: 'Faire les courses', item: 'Lessive' }))).toBe(
      `Inès a coché «${nb}Lessive${nb}» dans «${nb}Faire les courses${nb}»`,
    );
    expect(plainText(text('checklist_item_done', { actor: me, task: null, item: 'Lessive' }))).toBe(`Tu as coché «${nb}Lessive${nb}»`);
    expect(plainText(text('checklist_item_done', { actor: lucas, task: 'Faire les courses' }))).toBe(
      `Lucas a coché un élément de «${nb}Faire les courses${nb}»`,
    );
    expect(plainText(text('checklist_item_done', { actor: lucas, task: null }))).toBe('Lucas a coché un élément');
  });

  it('words turns', () => {
    expect(plainText(text('turn_started', { subject: me }))).toBe(`C’est ton tour pour «${nb}Sortir les poubelles${nb}»`);
    expect(emphasizedParts(text('turn_started', { subject: me }))).toEqual(['ton tour']);
    expect(plainText(text('turn_started', { subject: lucas }))).toBe(`C’est au tour de Lucas pour «${nb}Sortir les poubelles${nb}»`);
    expect(plainText(text('turn_started', { subject: ines }))).toBe(`C’est au tour d’Inès pour «${nb}Sortir les poubelles${nb}»`);
    expect(emphasizedParts(text('turn_started', { subject: ines }))).toEqual(['Inès']);
    expect(plainText(text('turn_started', { subject: departed }))).toBe(
      `C’est au tour d’un ancien membre pour «${nb}Sortir les poubelles${nb}»`,
    );
    expect(plainText(text('turn_started', { subject: lucas, task: null }))).toBe('C’est au tour de Lucas');
  });

  it('words members joining and leaving', () => {
    expect(plainText(text('member_joined', { actor: ines, subject: ines, task: null }))).toBe('Inès a rejoint le groupe');
    expect(plainText(text('member_joined', { actor: me, subject: me, task: null }))).toBe('Tu as rejoint le groupe');
    expect(plainText(text('member_left', { actor: departed, subject: departed, task: null }))).toBe('Un ancien membre a quitté le groupe');
    expect(plainText(text('member_left', { actor: lucas, subject: lucas, task: null }))).toBe('Lucas a quitté le groupe');
    expect(plainText(text('member_left', { actor: me, subject: me, task: null }))).toBe('Tu as quitté le groupe');
    const removed = text('member_left', { actor: me, subject: departed, task: null });
    expect(plainText(removed)).toBe('Tu as retiré un ancien membre du groupe');
    expect(emphasizedParts(removed)).toEqual(['Tu', 'un ancien membre']);
    expect(plainText(text('member_left', { actor: lucas, subject: ines, task: null }))).toBe('Lucas a retiré Inès du groupe');
    expect(plainText(text('member_left', { actor: lucas, subject: me, task: null }))).toBe('Lucas t’a retiré du groupe');
    expect(plainText(text('member_left', { actor: departed, subject: lucas, task: null }))).toBe('Un ancien membre a retiré Lucas du groupe');
    expect(plainText(text('member_left', { actor: lucas, subject: null, task: null }))).toBe('Lucas a retiré un ancien membre du groupe');
    expect(plainText(text('member_left', { actor: null, subject: lucas, task: null }))).toBe('Lucas a été retiré du groupe');
    expect(plainText(text('member_left', { actor: null, subject: me, task: null }))).toBe('Tu as été retiré du groupe');
    const deleted = text('member_left', { actor: null, subject: null, task: null });
    expect(plainText(deleted)).toBe('Un membre a supprimé son compte');
    expect(emphasizedParts(deleted)).toEqual(['Un membre']);
  });

  it('titles the days of the feed', () => {
    const now = F.date(2026, 9, 24, 10);
    const calendar = F.parisCalendar;
    expect(activityDayTitle(F.date(2026, 9, 24, 0, 5), now, calendar)).toBe('Aujourd’hui');
    expect(activityDayTitle(F.date(2026, 9, 25, 0, 1), now, calendar)).toBe('Aujourd’hui');
    expect(activityDayTitle(F.date(2026, 9, 23, 23, 59), now, calendar)).toBe('Hier');
    expect(activityDayTitle(F.date(2026, 9, 21, 10), now, calendar)).toBe('Lundi 21 septembre');
    expect(activityDayTitle(F.date(2025, 12, 31, 10), now, calendar)).toBe('Mercredi 31 décembre 2025');
  });
});

describe('RecapText', () => {
  it('words the week ranges', () => {
    const calendar = F.parisCalendar;
    expect(recapRange(F.date(2026, 9, 21), F.date(2026, 9, 28), calendar)).toBe('Du lundi 21 au dimanche 27 septembre');
    expect(recapRange(F.date(2026, 9, 28), F.date(2026, 10, 5), calendar)).toBe('Du lundi 28 septembre au dimanche 4 octobre');
    expect(recapRange(F.date(2025, 12, 29), F.date(2026, 1, 5), calendar)).toBe('Du lundi 29 décembre 2025 au dimanche 4 janvier 2026');
    expect(recapRange(F.date(2026, 6, 1), F.date(2026, 6, 8), calendar)).toBe('Du lundi 1er au dimanche 7 juin');
    // The week of the fall-back change (a 25-hour Sunday).
    expect(recapRange(F.date(2026, 10, 19), F.date(2026, 10, 26), calendar)).toBe('Du lundi 19 au dimanche 25 octobre');
  });

  it('words totals, places and streaks', () => {
    expect(recapTotalLabel(0)).toBe('tâche faite');
    expect(recapTotalLabel(1)).toBe('tâche faite');
    expect(recapTotalLabel(14)).toBe('tâches faites');
    expect(recapPlace(1)).toBe('1re');
    expect(recapPlace(2)).toBe('2e');
    const streak = recapStreak('Inès', false, 3);
    expect(plainText(streak)).toBe('Inès mène pour la 3e semaine d’affilée.');
    expect(emphasizedParts(streak)).toEqual(['Inès']);
    expect(plainText(recapStreak('Camille', true, 2))).toBe('Tu mènes pour la 2e semaine d’affilée.');
  });
});

describe('Presentation v2', () => {
  it('offers valid and distinct curated emojis', () => {
    for (const emoji of [...EMOJI_CHOICES.avatars, ...EMOJI_CHOICES.groups]) expect(validateEmoji(emoji)).toBe(emoji);
    expect(new Set(EMOJI_CHOICES.avatars).size).toBe(EMOJI_CHOICES.avatars.length);
    expect(new Set(EMOJI_CHOICES.groups).size).toBe(EMOJI_CHOICES.groups.length);
    expect(EMOJI_CHOICES.groups).toContain('\u{1F3E0}'); // « Coloc’ rue des Lilas »
    expect(EMOJI_CHOICES.groups).toContain('\u{26BD}'); // « Projet Asso Sport »
  });

  it('names the colors', () => {
    expect(COLOR_KEYS.map(colorLabel)).toEqual(['Indigo', 'Violet', 'Bleu', 'Turquoise', 'Vert', 'Ambre', 'Orange', 'Corail', 'Rose']);
  });

  it('builds appearances', () => {
    const date = F.date(2026, 9, 24);
    const camille = makeProfile({ id: F.me, displayName: 'Camille Martin' });
    expect(profileAppearance(camille)).toEqual({ color: automaticColor(F.me), emoji: null, initials: 'CM' });
    const fox = makeProfile({ id: F.me, displayName: 'Camille Martin', avatarColor: 'teal', avatarEmoji: '\u{1F98A}' });
    expect(profileAppearance(fox)).toEqual({ color: 'teal', emoji: '\u{1F98A}', initials: 'CM' });
    const group = { id: F.groupA, name: 'Coloc’ rue des Lilas', createdBy: null, createdAt: date, lastActivityAt: date, color: null, emoji: '\u{1F3E0}' };
    expect(groupAppearance(group)).toEqual({ color: automaticColor(F.groupA), emoji: '\u{1F3E0}', initials: 'CR' });
    expect(unknownAppearance(F.other)).toEqual({ color: automaticColor(F.other), emoji: null, initials: '?' });
    const task = { ...F.task(1), groupColor: 'green' as const, groupEmoji: '\u{26BD}' };
    expect(taskGroupAppearance(task)).toEqual({ color: 'green', emoji: '\u{26BD}', initials: 'CR' });
    expect(taskGroupAppearance({ ...task, groupName: null })).toBeNull();
  });

  it('measures checklist progress', () => {
    expect(checklistProgress([])).toBeNull();
    const items = [1, 2, 3, 4, 5].map((value) => ({
      id: F.uuid(value),
      title: `É${value}`,
      position: value,
      isDone: value <= 2,
      doneAt: null,
      doneBy: null,
    }));
    const progress = checklistProgress(items)!;
    expect(progress).toEqual({ done: 2, total: 5 });
    expect(progressCompactText(progress)).toBe('2/5');
    expect(progressText(progress)).toBe('2 sur 5');
    expect(progressFraction(progress)).toBe(0.4);
    expect(progressIsComplete(progress)).toBe(false);
    expect(progressIsComplete({ done: 3, total: 3 })).toBe(true);
  });

  it('gives short names and badges', () => {
    const date = F.date(2026, 1, 1);
    const lucas = F.uuid(0xc2);
    const ines = F.uuid(0xc3);
    const homonym = F.uuid(0xc4);
    const people: Array<[string, string, 'admin' | 'member']> = [
      [F.me, 'Camille Martin', 'admin'],
      [homonym, 'camille Dupont', 'member'],
      [lucas, 'Lucas Bernard', 'member'],
      [ines, 'Inès Dubois', 'member'],
    ];
    const members: Membership[] = people.map(([id, name, role]) => ({
      groupId: F.groupA,
      user: makeProfile({ id, displayName: name }),
      role,
      joinedAt: date,
    }));
    const directory = new MemberDirectory(members, F.me);
    expect(Object.fromEntries(directory.shortNames)).toEqual({
      [F.me]: 'Camille Martin',
      [homonym]: 'camille Dupont',
      [lucas]: 'Lucas',
      [ines]: 'Inès',
    });
    expect(directory.shortName(lucas)).toBe('Lucas');
    expect(directory.shortName(F.other)).toBe('Ancien membre');
    expect(directory.shortName(null)).toBe('Ancien membre');
    const departed = directory.badge(F.other);
    expect(departed.isMember).toBe(false);
    expect(departed.name).toBe('Ancien membre');
    expect(departed.appearance.initials).toBe('?');
    const me = directory.badge(F.me);
    expect(me.isMe && me.isMember && me.appearance.initials === 'CM').toBe(true);
    expect(directory.badges([lucas, F.me, ines, lucas]).map((badge) => badge.id)).toEqual([F.me, ines, lucas]);
    expect(directory.memberBadges.map((badge) => badge.id)).toEqual(people.map(([id]) => id));
    expect(directory.names([lucas, F.me, ines])).toEqual(['Toi', 'Inès Dubois', 'Lucas Bernard']);
    expect(directory.assigneesText([])).toBe('Non assignée');
    expect(directory.assigneesText([ines, F.me])).toBe('Toi, Inès Dubois');
  });

  it('counts the filter chips', () => {
    const chips = filterChips(ALL_TASKS_FILTER, { todo: 4, inProgress: 1 });
    expect(chips.map((chip) => chip.countedLabel)).toEqual(['Toutes', 'À faire · 4', 'En cours · 1', 'Terminées', 'Assignées à moi', 'En retard']);
    expect(filterChips(ALL_TASKS_FILTER)).toEqual(filterChips(ALL_TASKS_FILTER, {}));
  });

  it('follows the French typography in every v2 text', () => {
    const names = new Map([
      [F.me, 'Camille'],
      [F.other, 'Inès'],
    ]);
    const shown: string[] = [];
    const people: Array<[string | null, string | null]> = [
      [F.me, F.me],
      [F.other, F.other],
      [F.other, F.me],
      [F.me, null],
      [null, null],
      [null, F.other],
    ];
    for (const kind of ACTIVITY_KINDS) {
      for (const [actor, subject] of people) {
        const event: ActivityEvent = {
          id: 1,
          kind,
          actorId: actor,
          subjectId: subject,
          taskId: null,
          taskTitle: 'Vaisselle',
          itemTitle: 'Éponge',
          createdAt: F.date(2026, 9, 24),
        };
        shown.push(plainText(activityText(event, F.me, names)));
      }
    }
    shown.push(
      plainText(recapStreak('Inès', false, 2)),
      RECAP_EMPTY_MESSAGE,
      recapRange(F.date(2026, 9, 21), F.date(2026, 9, 28), F.parisCalendar),
      recurrenceDescription(makeRule({ frequency: 'monthly', timeZoneId: 'Europe/Paris', monthDay: 31 }), null),
    );
    const problems = shown.flatMap((line) => typographyProblems(line).map((problem) => `${problem} in « ${line} »`));
    expect(problems).toEqual([]);
    expect(shown.filter((line) => line.includes("'"))).toEqual([]);
  });

  it('scans typography problems', () => {
    expect(typographyProblems('Toi\u{a0}: _ !')).toEqual(['plain space before « ! »']);
    expect(typographyProblems('« x»')).toHaveLength(2);
    expect(typographyProblems('«\u{a0}x\u{202f}»\u{a0}?')).toEqual([]);
    expect(typographyProblems('https://ntfy.sh 20:00')).toEqual([]);
  });
});
