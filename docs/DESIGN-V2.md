# Design v2: « Moderne & coloré »

This is the visual system of the v2 redesign, derived from the mockups on the design canvas (onboarding, groups, my tasks,
group, activity, task, editor). It is shared by iOS (SwiftUI) and, later, Android (Compose). Every text/background pair
below was checked for WCAG AA (≥ 4.5:1 for text, ≥ 3:1 for large text and UI graphics).

## 1. Principles
- **Voice.** Friendly French, addressing the user as « tu » everywhere. Keep French typography: ’, no-break spaces
  before ? ! : ; and inside « ».
- **Identity per group.** Every group has a color and an emoji: they appear in its hero header, its cards and the chips
  of its tasks. People have an avatar color and optionally an emoji. Unset values fall back to `ColorKey.automatic`.
- **Surfaces.** Soft, toned surfaces: a lavender-grey ground and white rounded cards. Color comes from content (groups,
  people, statuses), not from gradients or decoration. The app icon is the only gradient.
- **Readability.**
  - Big rounded titles, clear hierarchy, generous spacing.
  - Touch targets ≥ 44 pt.
  - Dynamic Type everywhere: no fixed text heights. Layouts must survive the largest accessibility sizes (wrap, don't clip).
- **Platforms.**
  - **iOS 26:** native navigation and tab bar (Liquid Glass comes for free). No fake status bars, no custom tab bar.
  - **Android:** Material 3 with these tokens.
- **Dark mode.** Every token has a dark value. Shadows are replaced by 1 px hairlines in dark mode.

## 2. Typography
- **iOS**
  - Titles, numbers, section titles and buttons use **SF Pro Rounded**: `.fontDesign(.rounded)` with weight `.heavy`/`.bold`.
  - Body text uses SF Pro (default design).
  - Text styles:
    - large title: `.largeTitle.weight(.heavy)`, rounded;
    - card titles: `.headline`;
    - meta: `.subheadline` or `.footnote`;
    - chips: `.footnote.weight(.semibold)`.
- **Android:** titles in Nunito (OFL, bundled as a font resource), weights 800–900; body text in the system font.
- **Numbers** (progress rings, podium, counts): rounded design, heavy weight, `monospacedDigit()`.

## 3. Color tokens

**Neutrals**

| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | #F4F3F8 | #0F0E17 | screen ground (grouped background) |
| `card` | #FFFFFF | #1C1A27 | cards, rows, sheets' content |
| `track` | #E9E7F0 | #2B2840 | segmented-control track, progress track, dashed borders |
| `hairline` | #F1EFF6 | #2B2840 | separators inside cards |
| `textPrimary` | #16141F | #F4F3F8 | titles, body |
| `textSecondary` | #5F5C6E | #ABA8BD | meta, captions (5.9:1 / 7.4:1 on card) |
| `accent` | #4B3BE6 | #9D93FF (text) / #5B4CF0 (fills) | brand indigo: primary buttons, links, selection |
| `accentSoft` | #ECEAFD | #2A2650 | selected tab pill, soft accent chips (text: accent / #B7B0FF) |
| `onFill` | #FFFFFF | #FFFFFF | text and icons on colored fills |

**Palette (`ColorKey`).** A **fill** carries white text (≥ 4.5:1) and is used for group tiles, avatars, the group hero
and progress bars. A **soft** pair (background / text) is used for chips.

| Key | Fill | Soft light (bg / text) | Soft dark (bg / text) |
|---|---|---|---|
| indigo | #4B3BE6 | #ECEAFD / #4B3BE6 | #2A2650 / #B7B0FF |
| violet | #7C3AED | #EDE9FE / #6D28D9 | #2A1F4A / #B9A6FF |
| blue | #2563EB | #DBEAFE / #1D4ED8 | #172542 / #93B4FF |
| teal | #0F766E | #CCFBF1 / #0F766E | #0F2E2B / #5EEAD4 |
| green | #15803D | #DCFCE7 / #15803D | #12301F / #6EE7A8 |
| amber | #A16207 | #FEF3C7 / #B45309 | #3A2A0E / #FCC76A |
| orange | #C2410C | #FFEDD5 / #C2410C | #3B2210 / #FFA86B |
| coral | #D6385A | #FFE4E9 / #B01F3F | #3A1D28 / #FF8FA3 |
| pink | #BE185D | #FCE7F3 / #BE185D | #3B1830 / #F9A8D4 |

**Statuses and priorities** (chips, status controls):

| Meaning | Light (bg / text) | Dark (bg / text) |
|---|---|---|
| À faire | indigo soft | indigo soft dark |
| En cours | amber soft (#FEF3C7 / #B45309) | amber soft dark |
| Terminée | green soft (#DCFCE7 / #15803D) | green soft dark |
| Priorité haute, en retard | #FFE4E6 / #BE123C | #3A1818 / #FF8B8B |
| Priorité moyenne | orange soft | orange soft dark |
| Priorité basse | #EEEDF3 / #5F5C6E | #2A2833 / #C9C6D6 |
| Badge « Nouveau » | fill accent / white | fill #5B4CF0 / white |

## 4. Shape, spacing, elevation
- **Radii:** card 22; task row card 20; big buttons 18 (height 56); segmented track 16 with 12-radius segments; emoji tile 18 (56 pt) or 22 (64 pt); chips are capsules; avatars are circles.
- **Page margins:** 20 (16 for dense lists). Gaps between cards: 10–16. Inner card padding: 14–18.
- **Elevation:** in light mode, cards use `shadow(color: .black.opacity(0.06), radius: 12, y: 6)` plus a 1 px 4 % shadow; in dark mode, no shadow and a 1 px `hairline` stroke.
- **Motion:** spring animations for selection changes, checklist checks and progress (`.snappy`). Respect Reduce Motion.

## 5. Components (shared, one implementation each)
- **Card:** the `card` background, radius 22, elevation as in §4.
- **GroupTile:** an emoji centered on the group's fill (rounded square). With no emoji, the group's initials in white.
- **AvatarView:** a circle with the person's fill, showing the emoji or the initials (rounded heavy). Sizes 26/32/40/48/116. `AvatarStack` shows up to 3 overlapping avatars, each with a ring the color of the surface behind it, plus « +N ».
- **Chip:** a soft pair from §3, an optional leading SF Symbol and the text.
- **TaskRowCard:**
  - **Leading:** a status control, 44 pt target: a 24 pt ring in the group fill; an « en cours » half-fill in amber; « terminée » is a green filled circle with a check.
  - **Center:** the title (headline), then a meta row of chips: group (in « Mes tâches » only), due date (red when overdue), « Ton tour », checklist `n/m`, status « En cours ».
  - **Trailing:** assignee avatars, or a dashed circle for « Personne ».
  - **Badge:** « Nouveau » after the title when relevant.
- **SegmentedPill:** a `track` background with a white or `card` selected segment and a shadow. Used for Tâches / Activité, the status of a task, the priority, the repetition frequency, and Créer / Rejoindre.
- **PrimaryButton:** the accent fill, white rounded bold text, height 56, radius 18, soft accent shadow in light mode. **SecondaryButton:** plain accent text, 44 pt tall.
- **ProgressRing:** « Ta journée ». **ProgressBar:** 8 pt high, track + fill, used for checklists and group weeks.
- **Podium:** 3 columns in stage order 2nd–1st–3rd. Each column has an avatar (the 1st has a trophy and an amber ring), a first name, and a bar with its count and « 1re / 2e / 3e ». Heights 104/72/52 at default size, scaling with Dynamic Type.
- **StepProgress** (onboarding): 4 capsules plus « 2 sur 4 ».
- **SwatchGrid:** 9 colors in a 3×3 grid (a check on the selected one). **EmojiGrid:** a curated grid; the selected emoji has an accent ring.
- **FloatingAddButton:** a 60 pt rounded square in the accent, bottom trailing above the tab bar, on the group screen.

## 6. Icons (SF Symbols on iOS; Material Symbols Rounded equivalents on Android)

| Meaning | SF Symbol |
|---|---|
| Groupes tab | `person.2.fill` |
| Mes tâches tab | `checkmark.circle.fill` |
| Réglages tab | `gearshape.fill` |
| Répétition / tour de rôle | `arrow.triangle.2.circlepath` |
| Checklist | `checklist` |
| Échéance | `calendar`, `clock` |
| Priorité | `flag.fill` |
| Podium / recap | `trophy.fill` |
| Série (streak) | `flame.fill` |
| Rejoindre avec un code | `key.fill` |
| Inviter | `person.badge.plus` |
| Activité | `bolt.horizontal.circle` (feed rows use `ActivityEvent.Kind.systemImage`) |
| Notifications | `bell.badge.fill` |

## 7. Screens
All data comes from the v2 view models (`D:\mobileApp\_wt\V2-CORE-API.md` and the view-model report).

1. **Onboarding** (new accounts; `AppPhase.onboarding`). Each step shows StepProgress and a back button:
   1. Bienvenue: an illustration made of stacked task cards (plain views, no image), « Bienvenue, <prénom> ! » and the 3 highlights, then « C’est parti ».
   2. Avatar: a 116 pt preview, the SwatchGrid, then the choice between initials and an EmojiGrid, then « Continuer ».
   3. Premier groupe: SegmentedPill Créer / Rejoindre. Créer shows the tile preview, the name field, the EmojiGrid and the SwatchGrid. Rejoindre shows a big monospaced code field and a hint.
   4. Notifications: three sample notification cards (plain views), « Ne rate plus ton tour », « Activer les notifications » and « Plus tard ».

   « Passer » sits in the top trailing corner.
2. **Groupes:**
   - A large title with the header summary (« 3 groupes · 11 tâches à faire »), then « + », which opens a menu with Créer / Rejoindre.
   - Group cards: GroupTile, name, « 3 membres · 4 à faire », AvatarStack, and the week ProgressBar « Cette semaine — 9 faites sur 13 » in the group fill. Show no figures when the overview is nil.
   - Last, a dashed card « Rejoindre un groupe ».
3. **Mes tâches:**
   - The date (« Vendredi 25 septembre »), a large title, then the « Ta journée » card: ProgressRing, subtitle, and chips « n en retard » / « n nouvelle(s) ».
   - Sections: En retard (red), Aujourd’hui, Cette semaine, Plus tard, Sans échéance. Rows are TaskRowCards with the group chip.
   - A « n tâches terminées aujourd’hui » row that expands.
4. **Groupe:**
   - A hero in the group fill, with rounded bottom corners 32 and white text:
     - top row: back, « Inviter » (a white capsule with text in the group's soft-text color), « … »;
     - identity row: a 64 pt tile on white with the emoji, the name in rounded heavy 26, AvatarStack and `membersSummary`.
   - Below the hero, the SegmentedPill Tâches / Activité.
   - Tâches:
     - « À qui le tour ? » horizontal cards: turn holder, next person, due date;
     - filter chips with counts (selected = `textPrimary` fill, white text);
     - TaskRowCards;
     - the FloatingAddButton.
   - Admin « … » menu: « Apparence » (color and emoji editor sheet), plus the v1 items.
5. **Activité:**
   - The recap card: « Cette semaine », the range, the big total (« 14 tâches faites »), the Podium, and the streak line (flame, amber soft background).
   - Below it, « Fil d’activité », grouped by day. Each row has an avatar with the event badge (a 20 pt circle in the kind's color, with its symbol), the text (emphasized names), and the time.
6. **Tâche:**
   - A back capsule, then the group chip, the title in rounded heavy 30, and the status SegmentedPill.
   - An info card with rows, each led by an icon tile: Échéance, Se répète (`recurrenceText` + next dates), À tour de rôle (the avatar chain with the current turn ringed in the accent), Priorité (chip), Assignées.
   - The Checklist card: ProgressBar teal, « n sur m », rows with a 24 pt rounded-square checkbox (a teal fill when checked, with a strikethrough), and « Ajouter un élément ».
   - The description, and the v1 details.
7. **Nouvelle tâche / Modifier** (sheet), with cards:
   - Titre + Notes.
   - Quand: Échéance, then Répéter (SegmentedPill Jamais / Jour / Semaine / Mois), the interval stepper, the weekday circles for weekly (44 pt), and a hint with the next dates.
   - Qui s’en occupe ? The assignee picker, OR « À tour de rôle » (toggle) with the ordered list: number, avatar, name, « Commence » / « C’est ton tour » badge, drag handle.
   - Checklist (creation only).
   - Priorité (SegmentedPill).
8. **Réglages:**
   - The avatar row, which opens the avatar editor, and the name.
   - The notifications section: reminders, ntfy, and « Récap du lundi » (toggle).
   - The account section.
   - Same content as v1, restyled with cards.

## 8. App icon
The three options (A Trio, B Carte cochée, C Monogramme É) are on the design canvas and rendered as 1024 px PNGs, full
bleed, RGB, without alpha. The user picks one. Its SVG becomes the source in `design/`. The iOS `AppIcon` gets the PNG;
the Android adaptive icon is split into a background (gradient) and a foreground (motif).
