# Design v2: the SwiftUI components

This is the API of the v2 design system (« Moderne & coloré », `docs/DESIGN-V2.md`) as implemented in
`App/Sources/DesignSystem/`. Screens use these tokens and components. They do not redefine colors, radii or shadows.

- Every color is dynamic: it has a light and a dark value, resolved by the view that draws it. Use the tokens as they
  are and never test `colorScheme` to pick one.
- Every text uses a Dynamic Type text style. Layouts wrap instead of clipping.
- Every control is at least 44 pt. Decorative views are hidden from VoiceOver.

| File | Contents |
|---|---|
| `Theme.swift` | `Theme` (neutral tokens, `Radius`, `Spacing`), `SoftTone`, `ColorKey.fill/tone/accent`, `TaskStatus.tone`, `TaskPriority.tone`, `UIColor(rgb:)` |
| `Typography.swift` | `Font.rounded(_:weight:)`, `Font.roundedNumber(_:weight:)`, `Font.chip`, `SectionTitle` |
| `Elevation.swift` | `Elevation`, `.cardSurface()`, `.surface(_:)`, `.screenBackground()`, `.accessibilityIdentifierIfPresent(_:)` |
| `Card.swift` | `Card`, `IconTile` |
| `AvatarView.swift` | `AvatarView`, `AvatarStack`, `UnassignedAvatar`, `GroupTile` |
| `Chip.swift` | `Chip`, `NewBadge`, `FilterChipButton` |
| `StatusControl.swift` | `StatusGlyph`, `StatusControl` |
| `TaskRowCard.swift` | `TaskRowCard` |
| `FlowLayout.swift` | `FlowLayout` |
| `SegmentedPill.swift` | `SegmentedPill`, `SegmentTone` |
| `Buttons.swift` | `PrimaryButtonStyle` (`.primary`), `PrimaryButton`, `SecondaryButtonStyle` (`.secondary`), `PressableButtonStyle` (`.pressable`), `CircleIconButton` |
| `Progress.swift` | `ProgressRing`, `ProgressBar`, `StepProgress` |
| `Pickers.swift` | `SwatchGrid`, `EmojiGrid`, `PickerSection` |
| `FloatingAddButton.swift` | `FloatingAddButton`, `.floatingAddButton(_:identifier:systemImage:action:)` |
| `Podium.swift` | `PodiumView` |
| `NavigationBarAppearance.swift` | the rounded navigation titles (applied once by `AppDelegate`) |
| `DesignGallery.swift` | `DesignGalleryView`: every component with sample data (UI tests only, see §10) |

The avatar editor is also reusable: `AvatarEditorContent`, `AvatarPreview` and `AvatarEditorSheet`, in
`Features/Settings/AvatarEditorSheet.swift`.

## 1. Tokens

### Neutrals: `Theme`

All of these are `static var … : Color`.

| Token | Light / dark | Use |
|---|---|---|
| `Theme.background` | #F4F3F8 / #0F0E17 | the ground of every screen (`.screenBackground()`) |
| `Theme.card` | #FFFFFF / #1C1A27 | cards, rows, list rows (`.listRowBackground(Theme.card)`) |
| `Theme.track` | #E9E7F0 / #2B2840 | tracks of pills and progress bars |
| `Theme.trackStrong` | #DDDAE8 / #3A3656 | inactive onboarding steps, dashed borders, outlines of idle filter chips |
| `Theme.hairline` | #F1EFF6 / #2B2840 | separators inside cards; the edge of cards in dark mode |
| `Theme.textPrimary` | #16141F / #F4F3F8 | titles, body |
| `Theme.textSecondary` | #5F5C6E / #ABA8BD | meta, captions, idle segments |
| `Theme.textTertiary` | #A8A4B8 / #6E6A85 | decorative glyphs only (drag handle, « Personne » circle), never text |
| `Theme.accent` | #4B3BE6 / #9D93FF | links, icons, tints, selection rings, the tab bar tint |
| `Theme.accentFill` | #4B3BE6 / #5B4CF0 | behind white text: primary buttons, « Nouveau », selected fills |
| `Theme.accentSoft` / `Theme.accentSoftText` | #ECEAFD / #2A2650, #4B3BE6 / #B7B0FF | the soft accent pair |
| `Theme.onFill` | white | text on any fill |
| `Theme.danger` | #BE123C / #FF8B8B | overdue dates, errors, « En retard » |
| `Theme.shadow` | #161428 | shadow color (with a low opacity, light mode only) |

`Theme.dynamic(light:dark:)` builds any other dynamic color (`0xRRGGBB`), and `Theme.dynamicUIColor(light:dark:)` gives
its UIKit version.

**Shape and spacing** (`static let … : CGFloat`):
- `Theme.Radius`: `card` 22, `row` 20, `button` 18, `field` 16, `track` 16, `segment` 12.
- `Theme.Spacing`: `page` 20, `pageDense` 16, `cardGap` 12, `cardPadding` 16.

Corners are always continuous: `RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)`.

### Soft pairs: `SoftTone`

```swift
struct SoftTone: Hashable { var background: Color; var foreground: Color; var fill: Color }
```

- `background` / `foreground`: the soft pair of chips, icon tiles and selected segments (≥ 4.5:1).
- `fill`: the solid color of the same hue, with white text on it.

| Tone | Meaning |
|---|---|
| `SoftTone.accent` | the brand accent |
| `SoftTone.todo`, `.inProgress`, `.done` | the statuses (indigo, amber, green) |
| `SoftTone.danger` | « Priorité haute », « en retard », errors |
| `SoftTone.neutral` | « Priorité basse », « +N » circles |
| `SoftTone.ink(_ color:)` | a plain colored text without background (`Chip` style `.plain`) |
| `ColorKey.<key>.tone` | the soft pair of a group or person color |
| `TaskStatus.tone`, `TaskPriority.tone` | high `danger`, medium orange, low `neutral` |

Write the priority type as `TeamTasksCore.TaskPriority`: Swift Concurrency has its own `TaskPriority`.

### The palette: `ColorKey` (TeamTasksCore)

- `key.fill: Color`: the solid color, the same in light and dark mode, with white text on it. Use it for group tiles,
  avatars, the group hero and progress bar fills.
- `key.tone: SoftTone`: the soft pair (chips), with `fill`.
- `key.accent: Color`: the color drawn as a line or a glyph on `card` or `background`. It is the fill in light mode and
  the bright soft text in dark mode, where most fills are too dark. Use it for the ring of a task to do, a group's
  icons, and links in a group's color.
- `key.label`: the French name (« Corail »), in the core.

The appearance of a person or a group is an `AvatarAppearance` (core): its `color` is a `ColorKey`, and it has an
`emoji` or `initials`.

## 2. Typography

```swift
Font.rounded(_ style: Font.TextStyle, weight: Font.Weight = .heavy) -> Font   // SF Pro Rounded, Dynamic Type
Font.roundedNumber(_ style: Font.TextStyle, weight: Font.Weight = .heavy) -> Font   // + monospaced digits
Font.chip                                                                       // footnote semibold
```

| Role | Font |
|---|---|
| screen title in a custom header | `.rounded(.largeTitle)` (navigation bars already get it from `NavigationBarAppearance`) |
| step or hero title | `.rounded(.title)`; group hero name `.rounded(.title2)` |
| block title (« À qui le tour ? », « Checklist ») | `.rounded(.title3, weight: .heavy)`, or `SectionTitle(_, size: .large)` |
| card title | `.headline` (a task); `.rounded(.headline, weight: .heavy)` (a group) |
| meta | `.subheadline`, `.footnote` |
| numbers (rings, podium, totals) | `.roundedNumber(.title2)` |

```swift
SectionTitle(_ title: String, size: SectionTitle.Size = .small, color: Color? = nil, trailing: String? = nil)
```

- `.small`: a title above a list or a card, in subheadline heavy and `textSecondary` (« En retard » passes
  `color: Theme.danger`).
- `.large`: rounded heavy title3 in `textPrimary`.

Both are marked as headers. `trailing` is a text on the other side (« 2 tâches tournantes »).

```swift
SectionTitle("En retard", color: Theme.danger)
SectionTitle("À qui le tour\u{00A0}?", size: .large, trailing: model.turnCardsSubtitle)
```

## 3. Surfaces and elevation

```swift
enum Elevation { case flat, subtle, card, raised }
```

| Level | Light mode | Dark mode |
|---|---|---|
| `.flat` | no shadow | no stroke |
| `.subtle` | 1 pt contact shadow (fields) | 1 pt `hairline` stroke |
| `.card` | 6 %, blur 24, y 8, plus a 1 pt 4 % shadow | 1 pt `hairline` stroke |
| `.raised` | 12 %, blur 28, y 10 (floating illustrations) | 1 pt `hairline` stroke |

```swift
view.cardSurface(radius: CGFloat = Theme.Radius.card, fill: Color = Theme.card, elevation: Elevation = .card)
view.surface(_ shape: some InsettableShape, fill: Color = Theme.card, elevation: Elevation = .card)
view.screenBackground()          // Theme.background behind the screen; lists and forms keep a transparent background
view.accessibilityIdentifierIfPresent(_ identifier: String?)
```

`cardSurface` draws the surface behind the view: the view keeps its own padding. The shadows belong to the shape, never
to the text.

`.screenBackground()` is already applied by `MainTabView` to the root and to every pushed screen of the « Groupes » and
« Mes tâches » tabs. Apply it yourself to sheets and to screens outside the tabs. In a `List` or a `Form`, give the rows
`.listRowBackground(Theme.card)`: it can go on a `Section`.

### `Card`

```swift
Card(padding: CGFloat = 16, spacing: CGFloat = 12, radius: CGFloat = 22, alignment: HorizontalAlignment = .leading) {
    …   // a VStack of the content, full width
}
```

```swift
Card {
    HStack {
        SectionTitle("Checklist", size: .large)
        Text(progress.text).font(.headline).foregroundStyle(ColorKey.teal.accent)
    }
    ProgressBar(value: progress.fraction, tint: ColorKey.teal.fill, track: ColorKey.teal.tone.background)
}
```

### `IconTile`

```swift
IconTile(systemImage: String, tone: SoftTone = .accent, size: CGFloat = 32)
```

A rounded square (radius 31 % of the side) with the symbol in the tone's foreground on its background.
- Sizes: 32 (rows of the info cards), 36 (turn cards), 48 (onboarding highlights), 64 (big headers).
- It grows with Dynamic Type, ×1.5 at most.
- Decorative.

```swift
IconTile(systemImage: "calendar", tone: .accent)
IconTile(systemImage: "arrow.triangle.2.circlepath", tone: group.color.tone, size: 36)
```

## 4. People and groups

### `AvatarView`

```swift
AvatarView(_ appearance: AvatarAppearance, size: CGFloat = 32, ring: Color? = nil, highlight: Color? = nil)
```

A circle in `appearance.color.fill`, showing the emoji, or else the initials in rounded heavy white.
- Sizes 26, 32, 40, 48 and 116. Below 60 pt, the initials keep their first letter only (as on the mockups).
- `ring`: a 2 pt ring outside the frame, the color of the surface behind.
- `highlight`: one more 2 pt ring outside the `ring` gap: the current turn in `Theme.accent`, the podium's first in
  amber.
- Decorative: the text next to it names the person.

```swift
AvatarView(person.appearance, size: 40)
AvatarView(entry.person.appearance, size: 30, ring: Theme.card, highlight: Theme.accent)   // current turn
```

`AvatarView.ringWidth` is 2.

### `AvatarStack`

```swift
AvatarStack(avatars: [AvatarAppearance], overflowText: String? = nil, size: CGFloat = 30, surface: Color = Theme.card)
AvatarStack(people: [PersonBadge], limit: Int = 3, size: CGFloat = 30, surface: Color = Theme.card)
```

Overlapping avatars (overlap 27 % of the size), each ringed in `surface`, then « +N » in a neutral circle.
- The `people:` form shows everyone when they fit in `limit`, else `limit − 1` and « +N ».
- Decorative.

```swift
AvatarStack(avatars: overview.memberAvatars, overflowText: overview.moreMembersText)            // group card
AvatarStack(people: model.memberBadges, size: 26, surface: model.appearance.color.fill)        // on the hero
```

### `UnassignedAvatar`

```swift
UnassignedAvatar(size: CGFloat = 32)   // the dashed circle of « Personne »
```

### `GroupTile`

```swift
GroupTile(_ appearance: AvatarAppearance, size: CGFloat = 56, style: GroupTile.Style = .filled)   // .filled | .onColor
```

A rounded square (radius 33 %) with the emoji on the group's fill, or the initials in white.
- `.onColor` is a white tile, for the group hero drawn in the group's fill: the initials then take the fill.
- Sizes: 56 (group cards), 60 (the create preview), 64 (hero), 40 (the small hero of the activity tab).
- Decorative.

```swift
GroupTile(summary.group.appearance)
GroupTile(model.appearance, size: 64, style: .onColor)
```

## 5. Chips and badges

### `Chip`

```swift
Chip(_ text: String, systemImage: String? = nil, tone: SoftTone = .accent,
     style: Chip.Style = .soft, weight: Font.Weight = .semibold)   // style: .soft | .plain | .filled
```

| Style | Look | Examples |
|---|---|---|
| `.soft` | the tone's background and foreground | a group, « En cours », « Basse », « 1 en retard » |
| `.plain` | the foreground only, no background | a due date, « Ton tour », « 3/6 » |
| `.filled` | white on the tone's fill | |

- The text is footnote, and wraps rather than being cut.
- The symbol is decorative. VoiceOver reads the chip as one text.

```swift
Chip("\(emoji) \(row.groupShortName ?? "")", tone: appearance.color.tone)
Chip(dueText, systemImage: "clock", tone: .ink(row.isOverdue ? Theme.danger : Theme.textSecondary), style: .plain,
     weight: row.isOverdue ? .bold : .semibold)
Chip(TaskStatus.inProgress.label, tone: TaskStatus.inProgress.tone)
if let overdue = summary.overdueText { Chip(overdue, tone: .danger) }   // « Ta journée »
```

### `NewBadge`

```swift
NewBadge(_ text: String? = nil)   // « Nouveau »: white on accentFill, never truncated
```

### `FilterChipButton`

```swift
FilterChipButton(_ title: String, isSelected: Bool, action: @escaping () -> Void)
```

A 44 pt filter chip of the group screen.
- Selected: `textPrimary` fill with `background`-colored text.
- Idle: `card` with a `trackStrong` outline.
- It carries the selected trait.
- Its title is `TaskFilterChip.countedLabel`. Put your identifier on it: `AccessibilityID.Groups.filterChip(key)`.

```swift
ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 8) {
        ForEach(model.filterChips) { chip in
            FilterChipButton(chip.countedLabel, isSelected: chip.isSelected) { model.toggleFilterChip(chip.kind) }
        }
    }
}
```

## 6. Tasks

### `StatusGlyph` and `StatusControl`

```swift
StatusGlyph(_ status: TaskStatus, tint: Color = Theme.accent, size: CGFloat = 24)   // decorative
StatusControl(status: TaskStatus, tint: Color = Theme.accent, isBusy: Bool = false, isEnabled: Bool = true,
              action: @escaping () -> Void)
```

- The glyph:
  - « à faire »: a ring in `tint` (the group's `ColorKey.accent`);
  - « en cours »: an amber ring half filled;
  - « terminée »: a green disc with a check.
- The control is a borderless button with a target of 44 pt or more, growing with Dynamic Type. It keeps its own tap
  inside a `NavigationLink`.
  - `isBusy` shows a spinner. The action asks for the next status: call `row.status.next` yourself.
  - It gives a success haptic when a task becomes « terminée ».
  - Accessibility: « Statut : À faire », hint « Passer à « En cours » », identifier `AccessibilityID.Tasks.statusButton`.

### `TaskRowCard`

```swift
TaskRowCard(row: TaskRow, tint: Color? = nil, isBusy: Bool = false, onToggleStatus: (() -> Void)? = nil)
```

A task as a card (radius 20, card elevation), drawn from a `TaskRow`.

**Leading:** a `StatusControl`. `tint` is the ring color: pass the group's `appearance.color.accent` on the group
screen. When it is nil, the card uses the row's group (« Mes tâches ») or the accent.

**Center:** the title (headline, struck through when done), « Nouveau » when `row.isNew`, then a wrapping line of chips:
- the group (only when `row.groupAppearance` is set: « Mes tâches »);
- the due date (red and bold when overdue);
- « Ton tour », or « À tour de rôle », or the repetition;
- the checklist « 2/5 » (green when complete);
- « En cours »;
- the priority when it is not « Moyenne ».

**Trailing, on the group screen only** (`row.assigneesText != nil`): `AvatarStack(people: row.assignees)`, or the
dashed circle when nobody is assigned. At accessibility text sizes the avatars move under the chips.

**VoiceOver:** the card is one element. Its label starts with the title and the status (« Payer le loyer, En cours,
priorité haute, en retard, échéance hier à 18:00, assignée à Inès Dubois »), and it has a « Passer à « … » » action.
The status control stays a separate element.

Wrap it in the screen's `NavigationLink`, and put the row identifier on the link:

```swift
LazyVStack(spacing: 10) {
    ForEach(section.rows) { row in
        NavigationLink(value: AppRoute.task(groupId: row.task.groupId, taskId: row.id)) {
            TaskRowCard(row: row, tint: model.appearance.color.accent, isBusy: model.busyTaskIds.contains(row.id)) {
                setStatus(row.status.next, for: row)
            }
        }
        .buttonStyle(.pressable)   // or .plain: no system highlight on a card
        .accessibilityIdentifier(AccessibilityID.Tasks.row(row.title))
    }
}
```

Inside a `List`, clear the row chrome instead:
`.listRowBackground(Color.clear)`, `.listRowSeparator(.hidden)` and
`.listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))`.

### `FlowLayout`

```swift
FlowLayout(spacing: CGFloat = 8, lineSpacing: CGFloat = 6) { … }
```

Lays items out in lines and wraps to the next line. Items are centered vertically in their line. An item wider than the
line is proposed the full width, so it wraps.

## 7. Controls

### `SegmentedPill`

```swift
SegmentedPill(_ options: [Option], selection: Option, title: @escaping (Option) -> String,
              tone: @escaping (Option) -> SegmentTone = { _ in .standard },
              identifier: @escaping (Option) -> String? = { _ in nil },
              track: Color = Theme.track, onSelect: @escaping (Option) -> Void)

SegmentedPill(_ options: [Option], selection: Binding<Option>, tone: …, identifier: …, track: …,
              title: @escaping (Option) -> String)

enum SegmentTone { case standard; case soft(SoftTone); case filled(Color) }
```

A `track` holding 44 pt segments.

**Selected segment**, by `SegmentTone`:
- `.standard`: a `card` segment with a shadow (Tâches / Activité, Créer / Rejoindre).
- `.soft(tone)`: the status or priority pair (« En cours » amber, « Moyenne » orange).
- `.filled(color)`: white on the color (repetition: `.filled(Theme.accentFill)`).

**Behavior:**
- The selection slides with a spring, or crossfades with Reduce Motion.
- At accessibility text sizes the segments stack vertically.
- Each segment is a button with the selected trait and its identifier.
- `onSelect` only receives options other than the selected one. With an asynchronous change, the pill moves once the
  model changes.

**Track:** `Theme.track` on the ground (default). Inside a card, use `Theme.hairline`. On the ground with a card look
(the priority of the editor), use `Theme.card` and give the pill `.cardSurface(radius: Theme.Radius.track)` yourself.

```swift
SegmentedPill(GroupDetailViewModel.Tab.allCases, selection: $model.tab) { $0.label }

SegmentedPill(TaskStatus.allCases, selection: model.task.status, title: \.label, tone: { .soft($0.tone) },
              identifier: { AccessibilityID.Tasks.statusOption($0.rawValue) }) { status in
    Task { await model.setStatus(status) }
}

SegmentedPill(model.repeatFrequencyOptions, selection: $model.repeatFrequency,
              tone: { _ in .filled(Theme.accentFill) }, track: Theme.hairline) { $0.label }
```

### Buttons

```swift
.buttonStyle(.primary)          // PrimaryButtonStyle(fill: Color = Theme.accentFill, isLoading: Bool = false)
.buttonStyle(.secondary)        // SecondaryButtonStyle(tint: Color = Theme.accent, isFullWidth: Bool = true,
                                //                      font: Font = .body.weight(.bold))
.buttonStyle(.pressable)        // a light scale on press, for custom tappable surfaces

PrimaryButton(_ title: String, systemImage: String? = nil, iconPlacement: PrimaryButton.IconPlacement = .leading,
              isLoading: Bool = false, action: @escaping () -> Void)   // .leading | .trailing

CircleIconButton(systemImage: String, accessibilityLabel: String, style: CircleIconButton.Style = .card,
                 action: @escaping () -> Void)   // .card | .translucent
```

- **Primary:** white rounded bold text on `accentFill`.
  - Size: at least 56 pt tall, full width, radius 18.
  - Light mode: a soft accent shadow.
  - Disabled: `track` fill with `textSecondary` text. While `isLoading`, the fill stays with a white spinner, and
    VoiceOver says « En cours ».
  - Disable it with `.disabled(_:)`. Its identifier goes on it.
- **Secondary:** accent text, 44 pt tall (« Plus tard », « Créer un compte »).
- **CircleIconButton:** a round 44 pt icon button.
  - `.card`: a `card` circle with a `textPrimary` symbol (the onboarding's back button).
  - `.translucent`: white 22 % with a white symbol (the group hero's back and « … »).

```swift
PrimaryButton("C’est parti", systemImage: "arrow.right", iconPlacement: .trailing, isLoading: model.isBusy, action: next)
    .disabled(!model.canAdvance)
Button("Plus tard", action: later).buttonStyle(.secondary)
CircleIconButton(systemImage: "chevron.left", accessibilityLabel: "Retour aux groupes", style: .translucent) { dismiss() }
```

### `FloatingAddButton`

```swift
FloatingAddButton(accessibilityLabel: String, systemImage: String = "plus", action: @escaping () -> Void)
view.floatingAddButton(_ accessibilityLabel: String, identifier: String? = nil, systemImage: String = "plus",
                       action: @escaping () -> Void)
```

A 60 pt rounded square (radius 20) in `accentFill`, with a soft accent shadow in light mode. The modifier places it at
the bottom trailing corner, 20 pt from the edge and above the tab bar. It uses a bottom safe-area inset, so lists end
above it.

```swift
ScrollView { … }
    .floatingAddButton("Nouvelle tâche", identifier: AccessibilityID.Tasks.addButton) { isShowingEditor = true }
```

The UI tests find « + » by `AccessibilityID.Tasks.addButton` or by the label « Nouvelle tâche »: keep both.

### Progress

```swift
ProgressRing(progress: Double, text: String, size: CGFloat = 68, lineWidth: CGFloat = 8, tint: Color = Theme.accent,
             track: Color = Theme.accentSoft, accessibilityLabel: String? = nil)
ProgressRing(progress:size:lineWidth:tint:track:accessibilityLabel:) { center }   // any view in the middle
ProgressBar(value: Double, tint: Color = Theme.accentFill, track: Color = Theme.track, height: CGFloat = 8,
            accessibilityLabel: String? = nil)
StepProgress(current: Int, total: Int, text: String? = nil)   // 1-based; text « 2 sur 4 »
```

- **Ring:** the arc starts at 12 o'clock with round caps. The ring grows with Dynamic Type (×1.4 at most), and the
  figure shrinks to fit. The value animates with a spring.
- **Bar:** a `track` capsule with a `tint` capsule. The fill is never thinner than a dot when the value is above 0.
- **Accessibility, ring and bar:** with an `accessibilityLabel`, each is one element whose value is the percentage.
  Without one, it is hidden, because the text next to it gives the same information.
- **StepProgress:** capsules in `accentFill` for the done and current steps, `trackStrong` for the others. VoiceOver
  reads « Étape 2 sur 4 ».

```swift
ProgressRing(progress: summary.fraction, text: summary.ringText, accessibilityLabel: summary.title)
ProgressBar(value: overview.weekProgress, tint: group.color.fill, track: Theme.hairline)
ProgressBar(value: progress.fraction, tint: ColorKey.teal.fill, track: ColorKey.teal.tone.background)
```

### Pickers

```swift
SwatchGrid(options: [ColorKey] = ColorKey.allCases, columns: Int = 3,
           isSelected: @escaping (ColorKey) -> Bool, onSelect: @escaping (ColorKey) -> Void)
EmojiGrid(options: [String], selection: String?, initials: String? = nil, columns: Int = 6,
          onSelect: @escaping (String?) -> Void)
PickerSection(_ title: String) { … }   // « Couleur », « Emoji »: a subheadline bold header above the content
```

- **SwatchGrid:** the 9 colors in a 3 × 3 grid of 44 pt swatches. The selected one has a white check and a ring in its
  `accent`. Each swatch is a button named after its color (« Corail »), with the selected trait and the identifier
  `AccessibilityID.Picker.color(key.rawValue)`.
- **EmojiGrid:** 48 pt cells (6 columns). The selected cell is on `accentSoft` with an accent ring.
  - With `initials`, a first cell shows them and stands for `nil`: the avatar picker.
  - Tapping the selected emoji again passes it again; `CreateGroupViewModel.selectEmoji(_:)` then clears it.
  - Identifiers: `AccessibilityID.Picker.emoji(emoji)`, and `.initials` for the initials cell.

```swift
PickerSection("Emoji") {
    EmojiGrid(options: model.emojiOptions, selection: model.emoji) { model.selectEmoji($0) }
}
PickerSection("Couleur") {
    SwatchGrid(options: model.colorOptions, isSelected: { model.isSelected($0) }, onSelect: { model.selectColor($0) })
}
```

These pickers make the group appearance sheet (`GroupAppearanceViewModel`), with a `GroupTile` preview:

```swift
GroupTile(model.preview, size: 64)
PickerSection("Emoji") { EmojiGrid(options: model.emojiOptions, selection: model.emoji) { model.selectEmoji($0) } }
PickerSection("Couleur") {
    SwatchGrid(options: model.colorOptions, isSelected: { model.isSelected($0) }, onSelect: { model.selectColor($0) })
}
```

### `PodiumView`

```swift
PodiumView(entries: [PodiumEntry])   // pass GroupActivityViewModel.podiumStageOrder (2nd, 1st, 3rd)
```

Up to 3 columns, in the order given. Each column shows:
- the avatar: 48 pt for the first place, with a trophy above it and an amber ring; 40 pt for the others;
- the short name;
- a bar with the count (`.roundedNumber`) and « 1re / 2e / 3e ». Its height tells the place: 104, 72 and 52 pt at the
  default size, growing with Dynamic Type, and never shorter than its text. The first place's bar is amber; the others
  take the person's soft color.

VoiceOver reads one element per column (« Inès, 1re, 6 tâches »).

```swift
Card {
    HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading) {
            Text(GroupActivityViewModel.recapTitle).font(.rounded(.title2))
            Text(model.recapRangeText).font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        Spacer()
        Text("\(model.recapTotal)").font(.roundedNumber(.largeTitle)).foregroundStyle(Theme.accent)
    }
    PodiumView(entries: model.podiumStageOrder)
}
```

## 8. Shell

- **Tab bar:** the native `TabView`, tinted with `Theme.accent`, with the symbols of docs/DESIGN-V2.md §6
  (`AppTab.tabSymbol`). It is Liquid Glass on iOS 26.
- **Background:** `MainTabView` applies `.screenBackground()` to the tab roots and to their pushed screens.
- **Navigation titles:** SF Pro Rounded, heavy for large titles and bold for inline ones, in `textPrimary`
  (`NavigationBarAppearance`). Use `.navigationTitle` as usual.
- **App tint:** the `AccentColor` asset is the v2 accent. The v1 `ShellPalette.accentFill` is `Theme.accentFill`.
- **Weekly recap:** a tap on its notification opens « Groupes » (`DeepLink.groups`).
- **UI tests:** a screen that pins buttons at its bottom, over scrolling content, puts
  `.accessibilityElement(children: .contain)` and `.accessibilityIdentifier(AccessibilityID.Shell.pinnedBottomBar)` on
  them. The helpers then treat that area like the tab bar: they scroll instead of tapping what lies under it.

## 9. Notes for the groups and tasks screens

- **v1 components.** These are still used by the screens not redone yet: `Components/Groups/*`, `Components/Tasks/*`,
  `ShellPrimaryButtonLabel` and `.shellProminentButtonStyle()`. Delete each one when its last user is gone.
- **Scenario.** Use `showcase` for the v2 screenshots (`UITestScenario.showcase`, `-mockScenario showcase`). It has the
  rotation, the checklist, the feed and the podium.
- **Memberwise initializers.** A view with a `private` `@State` or `@ScaledMetric` property that has an initial value
  may lose its internal memberwise initializer. Write an explicit `init` for components built from other files.
- **Wording.** « vous » remains in `CreateGroupSheet`, `GroupDetailView` (use `membersSummary`), `InviteCodeSheet`,
  `JoinGroupSheet`, `MembersView`, `MyTasksView`, `TaskDetailView` and `TaskEditorView`: see the end of the v2
  view-model API report.

## 10. Checking a screen

- **The gallery.** `DesignGalleryView` shows every component with sample data on four pages (Base, Tâches, Contrôles,
  Groupes). It opens instead of the app with the mock backend and `-uiTestDesignGallery`.
  `DesignCheckTests.testComponentGallery` captures each page, top and bottom, in light and dark mode. The captures are
  published under `debug/` on the screenshots branch (`…DesignCheckTests_testComponentGallery--galerie-2-haut-sombre.png`).
- **Dark mode and large text.** `EquipeApp.launch(_:appearance:)` takes `.dark` (the app reads `-uiTestColorScheme`) or
  `.largestText` (AX5). Capture your screens that way too, in `DesignCheckTests`, and look at them.
