# Contracts v2 (additions, in progress)

Extends [CONTRACTS.md](CONTRACTS.md) for the « Équipe » v2 features:
- a color and an emoji per group, and an avatar color and emoji per person;
- onboarding for new accounts;
- recurring tasks, with an optional rotation (« à tour de rôle »);
- checklists;
- a group activity feed and a weekly recap.

Everything in CONTRACTS.md stays valid unless a section below says otherwise. When v2 ships everywhere, this file is
merged into CONTRACTS.md.

## 0. Compatibility rules (hard requirements)

The hosted database serves v1 clients that cannot be updated at once: the installed iOS app, and Android v1 APKs
already given to friends. So every change is **additive**:
- **Columns and tables:** only new nullable (or defaulted) columns and new tables. v1 decoders ignore unknown columns (Swift `Codable`, Android `Rows.kt` read named fields).
- **Enums:** no value is added to an existing enum.
- **v1 RPCs:** keep working with their v1 arguments. New parameters are appended **with defaults** that mean « unchanged » or « none ». A function whose signature grows is dropped and recreated, never overloaded: PostgREST rejects ambiguous overloads (`PGRST203`).
- **v1 edits:** a v1 client editing a v2 task never loses v2 data. `update_task` without the v2 parameters keeps the recurrence, the rotation and the checklist.
  - Exception: a v1 edit that clears the due date of a recurring task (`p_recurrence` NULL, `p_due_at` NULL) turns it into a plain task (§5). The recurrence and the rotation are cleared, the assignees and the checklist are kept, and `p_assignee_ids` then applies as for any plain task.
  - A v1 `set_task_assignees` on a rotating task is refused (`invalid_rotation`); a v1 `update_task` on it keeps the turn holder as the only assignee (§5).
  - v1 clients map `invalid_rotation`, a code they do not know, to their generic error.
- **v1 signals and assignments:** v2 adds signals and assignments that v1 clients already handle.
  - A display-name change also bumps the user's groups (§2), so co-members get `.groupActivity` and reload.
  - When a turn holder leaves, the next member of the rotation is assigned with `assigned_by` NULL (§6); a v1 client shows it as a new assignment.
- **Server-side behaviour:** recurrence spawning, rotation, activity and `completed_by` happen on the server. They also work for tasks completed by v1 clients, which simply see the next occurrence appear as a new task.
- **Signatures:** `create_group`, `create_task` and `update_task` were dropped and recreated with the v2 parameters appended (§5), then granted again; `set_task_assignees` keeps its signature. The `groups`, `profiles` and `tasks` rows returned by the RPCs carry the new columns.

## 1. Palette and emoji

`ColorKey` (SQL `text`, check constraint): `indigo`, `violet`, `blue`, `teal`, `green`, `amber`, `orange`, `coral`,
`pink`. Hex values are a client design matter (light and dark variants, white text ≥ 4.5:1 on the fill).
Keys are exact and case sensitive: `'Coral'` and `''` raise `invalid_color` (only NULL means automatic).

**Automatic color.** NULL means automatic:
- **Formula:** `ColorKey.automatic(for: id) = [blue, indigo, violet, pink, orange, teal, green, coral, amber][djb2(id) % 9]`.
- **djb2:** `h = 5381; for byte in utf8(uppercase uuid string): h = h &* 33 &+ byte` (UInt64, wrapping). It is the hash already used by the v1 avatars, and this order keeps their hues.
- **Where it lives:** in TeamTasksCore (ported as is to Kotlin), for groups and people.

**Emoji validation.** Applies to `groups.emoji` and `profiles.avatar_emoji`:
- **Normalization:** NULL, or `clean_text` then `''` → NULL.
- **Rule:** 1–16 code points, with no code point from the trim set and no C0/C1 control (U+0000–001F, U+007F–009F).
  - The forbidden code points are therefore U+0001–0020, U+007F–00A0, U+1680, U+2000–200B, U+2028, U+2029, U+202F, U+205F and U+3000.
  - ZWJ sequences (U+200D), variation selectors, keycaps and flags are allowed, e.g. `👨‍👩‍👧‍👦` (7 code points).
- **Error:** anything else raises `invalid_emoji`.
- **Storage:** the same rule is a check constraint on both columns (`groups_emoji_format`, `profiles_avatar_emoji_format`), behind the triggers that normalize and raise the business errors.
- **Clients:** they only offer a curated emoji grid; this validation is the server's safety net.

## 2. Schema additions

| Table | New columns / definition |
|---|---|
| `groups` | `color text null` (ColorKey), `emoji text null` |
| `profiles` | `avatar_color text null` (ColorKey), `avatar_emoji text null`, `onboarded_at timestamptz null` — the migration backfills `onboarded_at = created_at` for every existing profile (`private.backfill_onboarded_at()`, kept for pgTAP, not callable by API roles); new profiles start NULL |
| `tasks` | `repeat_freq text null` (`daily`, `weekly`, `monthly`), `repeat_interval smallint not null default 1` (1–52), `repeat_weekdays smallint[] null` (weekly only; ISO 1 = Monday … 7 = Sunday, distinct, ascending; NULL = the due date's weekday), `repeat_month_day smallint null` (monthly only, 1–31, server-set from the local due date), `repeat_tz text null` (IANA zone, set iff `repeat_freq` is set), `series_id uuid null` (id of the series' first occurrence; set iff recurring), `next_occurrence_id uuid null` (no FK; set once the next occurrence exists), `rotation uuid[] null` (2–20 distinct user ids, ordered; only on recurring tasks), `turn_user_id uuid null → profiles on delete set null` (whose turn this occurrence is), `completed_by uuid null → profiles on delete set null` |
| `task_checklist_items` | `id uuid pk default gen_random_uuid()`, `task_id uuid not null`, `group_id uuid not null`, `title text not null` (1–200), `position integer not null`, `done boolean not null default false`, `done_at timestamptz null`, `done_by uuid null → profiles on delete set null`, `created_at timestamptz not null default now()`; fk `(task_id, group_id) → tasks(id, group_id) on delete cascade`; check `done = (done_at is not null)`; check `position >= 1`; **unique** `(task_id, position)` (it is the `(task_id, position)` index); index `done_by` |
| `group_activity` | `id bigint generated always as identity pk`, `group_id uuid not null → groups on delete cascade`, `kind text not null` (§7), `actor_id uuid null → profiles on delete set null`, `subject_id uuid null → profiles on delete set null`, `task_id uuid null` (no FK: the task may be deleted), `task_title text null` (snapshot), `item_title text null` (snapshot), `created_at timestamptz not null default now()`; check `kind` ∈ the §7 kinds; index `(group_id, id desc)`; also indexes `(group_id, created_at)` (retention), `actor_id`, `subject_id` |

**Task check constraints** (the last line of defense behind the triggers, which raise the business errors first):
- `repeat_tz`, `series_id` set iff `repeat_freq` is set; a task without rule keeps `repeat_interval = 1`;
- a recurring task has a due date;
- `repeat_weekdays`: only on weekly rules, 1–7 values, strictly ascending within 1…7;
- `repeat_month_day` set iff the rule is monthly;
- `rotation`: only on recurring tasks, 2–20 non-NULL ids (distinctness and membership are checked when it is written);
- `turn_user_id` NULL or an element of `rotation`;
- `completed_by` NULL unless `status = done`.

Beyond the constraints, the triggers keep the turn holder of every pending (`status ≠ done`) rotating occurrence a
member of the group (§6 « Turn holder leaving »).

Indexes on `turn_user_id` and `completed_by` serve the `on delete set null` of their foreign keys.

**Server-maintained fields** (end users cannot set them):
- all `repeat_month_day`, `series_id`, `next_occurrence_id`, `turn_user_id`;
- `completed_by`: `auth.uid()` when the status **becomes** `done` (an UPDATE; an end user cannot insert a done task), kept on `done` → `done`, NULL when leaving `done`; explicit values allowed in trusted contexts, also on INSERT;
- the checklist fields `position`, `done_at`, `done_by` (`done_at` / `done_by` follow `done` like `completed_at` / `completed_by`);
- every `group_activity` column.

`tasks.updated_at` rules are unchanged: v2 columns do not move it (a rule-only `update_task` keeps it).
`profiles.updated_at` moves when `display_name`, `avatar_color` or `avatar_emoji` actually changes; `onboarded_at` does not move it.

**Grants and RLS:**
- `profiles`: the self `UPDATE` column grant becomes `(display_name, avatar_color, avatar_emoji)`. The `profiles` BEFORE trigger validates both, raising `invalid_color` and `invalid_emoji`.
  - Order: display name, then color, then emoji.
  - An avatar `PATCH` (like `complete_onboarding`) is a `profiles` UPDATE: the user's own devices get `.membershipsChanged`.
  - **Group signal:** a change of `display_name`, `avatar_color` or `avatar_emoji` also sets `last_activity_at = now()` on every group of the user, at most once per group per transaction (`private.bump_group_activity`). Co-members get `.groupActivity` and reload the members and their avatars.
  - Nothing else bumps groups: identical values, `onboarded_at` (`complete_onboarding`) and `memberships_changed_at`.
  - The v1 rule stands: a display-name change does not move `memberships_changed_at`.
- `task_checklist_items` and `group_activity`:
  - SELECT for members of the group;
  - no INSERT/UPDATE/DELETE privilege: writes go through RPCs and triggers;
  - explicit grants, as in CONTRACTS.md §5 pitfall 9 (`group_activity_id_seq` included: nothing for `anon` / `authenticated`).
- `tasks`: the column grants are unchanged. The v2 columns are written by the definer triggers only (§5 « Transport »).
- Nothing new is published to Realtime.

## 3. Validation and errors

| Message code | When | `AppError` (new cases in **bold**) | French message |
|---|---|---|---|
| `invalid_color` | color not a ColorKey | **`.invalidAppearance`** | « Couleur ou emoji invalide. » |
| `invalid_emoji` | §1 | **`.invalidAppearance`** | idem |
| `invalid_recurrence` | bad JSON shape, unknown key, unknown `freq`, `interval` ∉ 1–52, `weekdays` invalid or given for a non-weekly rule, `tz` missing or unknown (exact rules in §5) | **`.invalidRecurrence`** | « Répétition invalide. » |
| `recurrence_requires_due_date` | a recurrence on a task without due date: `create_task`, `update_task` with an explicit rule and a NULL due date, or a direct `PATCH` that clears the due date of a recurring task (`update_task` with `p_recurrence` NULL clears the rule instead, §5) | **`.recurrenceNeedsDueDate`** | « Choisissez une échéance pour répéter la tâche. » |
| `invalid_rotation` | rotation without recurrence, < 2 or > 20 ids, a NULL id, duplicates, a non-member, or `set_task_assignees` on a rotating task | **`.invalidRotation`** | « Le tour de rôle demande de 2 à 20 membres du groupe. » |
| `invalid_item_title` | checklist item title not 1–200 chars after trim | **`.invalidChecklistItem`** | « Un élément doit contenir entre 1 et 200 caractères. » |
| `too_many_items` | more than 30 items on a task | **`.tooManyChecklistItems`** | « 30 éléments au maximum. » |
| `item_not_found` | item missing or not visible | `.notFound` | – |

`Limits` gains: `checklistItemsMax = 30`, `checklistItemTitleMax = 200`, `rotationMin = 2`, `rotationMax = 20`,
`repeatIntervalMax = 52`, `emojiCodePointsMax = 16`.

`set_checklist_item_done` with a NULL `p_done` raises `23502 invalid_input` → `.invalidInput` (as `set_member_role`).

**Check order:**
- **create/update task:** permission → title → details → due date → recurrence (shape, then due-date requirement) → rotation → assignees count → assignees membership → checklist items (each title, then count).
  - With a rotation, the assignee ids are ignored, so never validated.
  - `create_task` raises all of them before the write quota (`rate_limited`), assignee errors included (in v1 the quota came first for those).
  - `update_task` has no checklist parameter; its assignees are still validated by `set_task_assignees`, after the task row.
- **set_task_assignees:** `task_not_found` → `forbidden` → `invalid_rotation` → `too_many_assignees` → `assignee_not_member`.
- **appearance:** color before emoji.
  - `create_group`: name → color → emoji → `rate_limited`.
  - `set_group_appearance`: `group_not_found` → `forbidden` → `invalid_color` → `invalid_emoji`.
  - avatar `PATCH`: display name → color → emoji.
- **checklist RPCs:** `task_not_found` / `item_not_found` (missing or not visible) → `forbidden` → `invalid_item_title` → `too_many_items`; `set_checklist_item_done`: `item_not_found` → `forbidden` → `invalid_input`.

## 4. Permissions (additions to CONTRACTS.md §2)

| Action | Admin | Creator (member) | Assignee (member) | Other member | Non-member |
|---|:-:|:-:|:-:|:-:|:-:|
| Set group color / emoji | ✓ | ✗ | ✗ | ✗ | ✗ |
| Edit recurrence / rotation (part of « edit task fields ») | ✓ | ✓ | ✗ | ✗ | ✗ |
| Add, rename, delete, check or uncheck checklist items (same rights as « change status ») | ✓ | ✓ | ✓ | ✗ | ✗ |
| See the activity feed | ✓ | ✓ | ✓ | ✓ | ✗ |

On a spawned occurrence, the « creator » is the series creator: `created_by` is copied, not the user who completed the
previous occurrence.

## 5. RPCs (new or extended)

| RPC | Security | Returns | Behaviour | Errors |
|---|---|---|---|---|
| `create_group(p_name text, p_color text default null, p_emoji text default null)` | definer | `groups` row | v1 behaviour + appearance (the emoji is stored normalized) | v1 + `invalid_color`, `invalid_emoji` |
| `set_group_appearance(p_group_id uuid, p_color text, p_emoji text)` | definer | `groups` row | admin only; NULL = automatic color / no emoji (a blank emoji is stored NULL); also sets `last_activity_at = now()` (same Realtime UPDATE). No default: send both keys | `not_authenticated`, `group_not_found`, `forbidden`, `invalid_color`, `invalid_emoji` |
| `complete_onboarding()` | definer | void | `onboarded_at = coalesce(onboarded_at, now())` for the caller; no write (no Realtime event) when already set | `not_authenticated` |
| `create_task(p_group_id uuid, p_title text, p_details text default null, p_priority task_priority default 'medium', p_due_at timestamptz default null, p_assignee_ids uuid[] default '{}', p_recurrence jsonb default null, p_rotation uuid[] default null, p_checklist text[] default null)` | invoker (+ definer triggers) | `tasks` row | v1 + §6; `p_recurrence` NULL or `'{}'` = none; `p_rotation` NULL or `'{}'` = none; with a rotation, `p_assignee_ids` is ignored and the assignee is `rotation[1]` (also `turn_user_id`), assigned by the creator; `p_checklist` NULL or `'{}'` = none, items get positions 1…n | v1 + §3 |
| `update_task(p_task_id uuid, p_title text, p_details text, p_priority task_priority, p_due_at timestamptz, p_assignee_ids uuid[], p_recurrence jsonb default null, p_rotation uuid[] default null)` | invoker (+ definer triggers) | `tasks` row | `p_recurrence` NULL (or JSON `null`) = unchanged, except that with a NULL `p_due_at` on a recurring task it clears the rule and the rotation: the task becomes a plain task, like with `'{}'` (every v1 call that clears the due date; the assignees and the checklist stay, then `p_assignee_ids` applies as for any plain task); `'{}'` = no recurrence (also clears the rotation); an explicit rule with a NULL `p_due_at` raises `recurrence_requires_due_date`. `p_rotation` NULL = unchanged, `'{}'` = no rotation; the stored list sent back as is (same ids, same order) also counts as unchanged, without validation. While the task has a rotation, `p_assignee_ids` is ignored: the turn holder stays the only assignee. A new rotation keeps the current turn holder when they are still listed, otherwise the turn goes to `rotation[1]`; the turn holder then becomes the only assignee (assigned by the editor; an existing row is kept). When the call removes the rotation, `p_assignee_ids` applies as in v1 | v1 + §3 |
| `set_task_assignees` | unchanged | | refuses rotating tasks | v1 + `invalid_rotation` |
| `add_checklist_item(p_task_id uuid, p_title text)` | definer | item row | position = max + 1 (1 for the first item); title trimmed | `not_authenticated`, `task_not_found`, `forbidden`, `invalid_item_title`, `too_many_items` |
| `rename_checklist_item(p_item_id uuid, p_title text)` | definer | item row | title trimmed; always writes the row (and bumps), like `update_task` | `not_authenticated`, `item_not_found`, `forbidden`, `invalid_item_title` |
| `set_checklist_item_done(p_item_id uuid, p_done boolean)` | definer | item row | sets or clears `done_at` / `done_by`; the same value is a no-op (no write) | `not_authenticated`, `item_not_found`, `forbidden`, `invalid_input` (NULL `p_done`) |
| `delete_checklist_item(p_item_id uuid)` | definer | void | positions of the others are kept (gaps allowed) | `not_authenticated`, `item_not_found`, `forbidden` |

**Recurrence JSON:**
- **Shape:** `{"freq": "daily" | "weekly" | "monthly", "interval": 1…52 (default 1), "weekdays": [1…7] (weekly only, optional), "tz": "<IANA>"}`.
- **Unknown keys:** refused (`invalid_recurrence`).
- **JSON null:** a key whose value is `null` counts as absent (`"interval": null` = 1, `"weekdays": null` = the due date's weekday); `"freq": null` and `"tz": null` are refused.
- **interval:** a JSON number with an integral value in 1…52 (`2` and `2.0` are accepted; `1.5`, `"2"`, `true` are refused).
- **weekdays:** 1 to 7 distinct JSON integers in 1…7, in any order; stored ascending (`[5, 1, 3]` → `{1,3,5}`). `[]`, duplicates, `0`, `8`, `null` elements and strings are refused.
- **tz:** a zone name of PostgreSQL's `pg_timezone_names`, exact case, except the `posix/…` and `right/…` copies and `Factory`: IANA names such as `Europe/Paris`, `UTC`, `America/Argentina/Buenos_Aires`. POSIX offsets (`UTC+3`), abbreviations (`CEST`) and other cases (`europe/paris`) are refused.
- **Monthly day:** for a monthly rule, the server stores `repeat_month_day` = the day of the due date in `tz` (the local date, e.g. 31 for `2041-01-30T15:30Z` in `Asia/Tokyo`).
- **When it is recomputed:** when the task becomes monthly, and when `tz` or the local date of the due date (in `tz`) changes. Otherwise it is kept: a new interval, a new time on the same local date, a v1 edit or the same rule sent again keep a « 31st » series at 31 on its February 28 occurrence (no drift). The spawn copies it as is.

**Transport (implementation note).** `create_task` and `update_task` stay security invoker, so RLS, the column grants and
the v1 triggers still apply. They pass their v2 arguments to security definer triggers through a transaction-local
setting (`equipe.task_draft`), reset right after their write. PostgREST clients cannot set custom settings. The
definer triggers validate the arguments, write the v2 columns, the rotation's assignee and the checklist items.

**Checklist writes:**
- They bump the group (AFTER trigger, as `tasks`), so members reload through the existing Realtime signal.
- The write quota does not apply to checklist items.

## 6. Recurrence and rotation (server)

The next occurrence is created **by the server** when an occurrence's status **becomes** `done` and
`next_occurrence_id` is NULL. It is created in the same transaction as the status change, from a trigger, so it
happens whichever client completes the task (`set_task_status`, a direct `PATCH`, a trusted context).
The trigger is a BEFORE UPDATE trigger on the completed row: the row is written once, with `next_occurrence_id`, and
an assignee who is not an editor spawns it too (they only change the status). `now()` is the transaction time.

**Algorithm.** Let `local = due_at at time zone tz`, with date `d` and time of day `t`:
- **step(d):**
  - `daily`: `d + interval` days.
  - `weekly`, no weekdays: `d + 7 × interval` days.
  - `weekly` with weekdays `W`:
    - if some `w ∈ W` has `w > isodow(d)`, take the smallest such `w`: `d + (w − isodow(d))` days;
    - else: `monday(d) + 7 × interval` days `+ (min(W) − 1)` days.
  - `monthly`: `m = first day of (month of d) + interval months`, then `m + (min(repeat_month_day, days in m) − 1)` days.
- **Next due:** `c = step(d)`, then `while (c + t) at time zone tz <= now(): c = step(c)` (at most 10 000 steps). The next due is `(c + t) at time zone tz`. Missed occurrences are skipped, and an early completion does not repeat the same slot.
  - The 10 000 steps count every call of `step`, the first one included. After the 10 000th, `c` is used even if it is still in the past (vector 26).
  - An occurrence due exactly at `now()` is skipped (`<=`, vector 5).
  - `monday(d) = d − (isodow(d) − 1)`: weeks start on Monday, so a Sunday belongs to the week of the Monday before it (vector 12).
  - Only explicit `at time zone tz` conversions are used: the result does not depend on the session time zone (PostgREST clients can set it with `Prefer: timezone`).
- **DST:** local times that do not exist or are ambiguous follow PostgreSQL's rules. Mocks use Foundation's `Calendar` (French Gregorian, `tz`). Scenarios avoid local times between 02:00 and 03:00.
  - A local time that does not exist (spring forward) is read with the offset before the change: `02:30` on 2026-03-29 in Europe/Paris is `01:30Z` (03:30 CEST).
  - An ambiguous local time (fall back) is read as the later instant (standard time): `02:30` on 2026-10-25 in Europe/Paris is `01:30Z` (02:30 CET).

**The new occurrence:**
- **Copied fields:** `group_id`, `title`, `details`, `priority`, every `repeat_*` column, `created_by` (series creator), `series_id = coalesce(series_id, id)`.
  - `repeat_month_day` is copied as is, never recomputed from the new due date (no drift after a clamped month).
  - `created_by` is kept even when the series creator left the group, and stays NULL once their account is deleted.
- **Status:** `status = todo`; `created_at = updated_at = now()`; `completed_at`, `completed_by`, `next_occurrence_id` NULL.
- **Checklist:** the items are copied, unchecked, with the same positions (gaps included).
- **Rotation:**
  - **Cleaned list:** the rotation keeps its order, minus the users no longer in the group. It is the new occurrence's `rotation`.
  - **Next turn:**
    - the next turn holder is the first **member** found cyclically after the previous turn holder's position in the original list (a previous holder who left still has a position);
    - if the previous turn holder is no longer in the list, it is the first member of the cleaned list. This includes `turn_user_id` NULL.
    - Since the handover below, the turn holder of a pending occurrence is always a member. These two cases only matter for data written by trusted contexts.
  - **Too few members left:** a list of < 2 members drops the rotation (and the turn), and the single remaining member, if any, is the assignee. Its `assigned_by` follows the next rule, and no `turn_started` is written.
  - **Assignee:** the turn holder, with `assigned_by = NULL`, or equal to the completer when the completer is the new turn holder.
- **Without rotation:** the same assignees as the completed occurrence, among those still in the group. Each row has `assigned_by = user_id` (a continuation, which notifies no one: no local notification, no ntfy push).
- **Bookkeeping:** the completed occurrence gets `next_occurrence_id`, and a `turn_started` activity event is written (rotation only). Its `task_id` is the new occurrence, and it follows the completion's `task_completed` event.
- **Write quota:** spawning is exempt from the task write quota (`tasks_quota_before_insert`): nothing is counted or logged. A spawn writes no `task_created` event.

**Series lifecycle:**
- Reopening a completed occurrence (`done` → `todo`) spawns nothing more, because `next_occurrence_id` is set. Completing it again (or `done` → `done`) spawns nothing either.
- Deleting the pending occurrence ends the series.
- Clearing the rule (`p_recurrence = '{}'`, or `update_task` clearing the due date with `p_recurrence` NULL) makes the occurrence a plain task.
  - `repeat_*`, `series_id`, `rotation` and `turn_user_id` become NULL, and `repeat_interval` becomes 1.
  - `next_occurrence_id` is kept.
- Editing the rule never spawns; it only affects the edited occurrence.

**Turn holder leaving (handover).** When a user stops being a member of a group (leave, removal, account deletion),
every pending (`status ≠ done`) occurrence of a rotating task of that group whose turn holder they were is handed over
at once, so no pending chore is left without an owner:
- **Next turn:** the next member found cyclically after the departed user's position in `rotation` (the rule of the
  spawn). They become the only assignee with `assigned_by` NULL, so they are notified « C’est ton tour » (§11), and a
  `turn_started` event is written for that occurrence.
- **Fewer than 2 members of the rotation left:** the rotation and the turn are dropped (the rule stays). The remaining
  member, if any, becomes the assignee with `assigned_by` NULL. No `turn_started` is written.
- **The stored rotation:** the departed id stays in `rotation` until the next spawn cleans it; `turn_user_id` always
  points to a member.
- **Untouched:** done occurrences, tasks without rotation (the departed user's assignments are simply deleted, as in
  v1), and occurrences where the departed user is listed but it is not their turn.
- **Account deletion:** `member_left` (actor and subject NULL) comes first, then `turn_started`. The server handles
  both orders of the cascade (`turn_user_id` set to NULL before or after the membership is deleted).
- **Group deletion:** nothing to hand over, the tasks go with the group.

**Test vectors.** Computed with the server function (`private.next_due_at`, pgTAP `13_v2_recurrence.test.sql` checks
every row). The Swift and Kotlin ports test against this table.
- **Rule:** the JSON sent by the clients.
- **Month day:** the stored `repeat_month_day` (monthly only); `–` = the local day of `due_at`, as when the task is created.
- **Times:** `due_at`, `now` and the next `due_at` are UTC instants.

| # | Rule | Month day | `due_at` | `now` | Next `due_at` | Case |
|---:|---|:-:|---|---|---|---|
| 1 | `{"freq":"daily","tz":"Europe/Paris"}` | – | 2026-09-24T18:00:00Z | 2026-09-24T19:00:00Z | 2026-09-25T18:00:00Z | daily, 20:00 CEST |
| 2 | `{"freq":"daily","tz":"Europe/Paris"}` | – | 2026-09-26T18:00:00Z | 2026-09-24T10:00:00Z | 2026-09-27T18:00:00Z | completed early: the slot after the due date, not after now |
| 3 | `{"freq":"daily","interval":3,"tz":"Europe/Paris"}` | – | 2026-09-24T06:00:00Z | 2026-09-24T07:00:00Z | 2026-09-27T06:00:00Z | every 3 days |
| 4 | `{"freq":"daily","tz":"Europe/Paris"}` | – | 2026-09-20T06:00:00Z | 2026-09-24T12:00:00Z | 2026-09-25T06:00:00Z | missed occurrences (21–24) skipped |
| 5 | `{"freq":"daily","tz":"Europe/Paris"}` | – | 2026-09-22T06:00:00Z | 2026-09-24T06:00:00Z | 2026-09-25T06:00:00Z | a slot due exactly now is skipped (`<=`) |
| 6 | `{"freq":"weekly","tz":"Europe/Paris"}` | – | 2026-09-21T07:00:00Z | 2026-09-21T08:00:00Z | 2026-09-28T07:00:00Z | weekly, the due date's weekday (Monday 09:00) |
| 7 | `{"freq":"weekly","interval":2,"tz":"Europe/Paris"}` | – | 2026-09-21T07:00:00Z | 2026-09-21T08:00:00Z | 2026-10-05T07:00:00Z | every 2 weeks |
| 8 | `{"freq":"weekly","weekdays":[1,3,5],"tz":"Europe/Paris"}` | – | 2026-09-23T16:00:00Z | 2026-09-23T17:00:00Z | 2026-09-25T16:00:00Z | Mon/Wed/Fri, from a Wednesday |
| 9 | `{"freq":"weekly","weekdays":[1,3,5],"tz":"Europe/Paris"}` | – | 2026-09-25T16:00:00Z | 2026-09-25T17:00:00Z | 2026-09-28T16:00:00Z | Mon/Wed/Fri, from a Friday |
| 10 | `{"freq":"weekly","interval":2,"weekdays":[2,4],"tz":"Europe/Paris"}` | – | 2026-09-22T16:00:00Z | 2026-09-22T17:00:00Z | 2026-09-24T16:00:00Z | Tue/Thu every 2 weeks, from a Tuesday: same week |
| 11 | `{"freq":"weekly","interval":2,"weekdays":[2,4],"tz":"Europe/Paris"}` | – | 2026-09-24T16:00:00Z | 2026-09-24T17:00:00Z | 2026-10-06T16:00:00Z | … from a Thursday: 2 weeks later |
| 12 | `{"freq":"weekly","interval":2,"weekdays":[1,3],"tz":"Europe/Paris"}` | – | 2026-09-27T08:00:00Z | 2026-09-27T09:00:00Z | 2026-10-05T08:00:00Z | due on a Sunday, outside the weekdays |
| 13 | `{"freq":"weekly","weekdays":[1,3,5],"tz":"Europe/Paris"}` | – | 2026-09-14T16:00:00Z | 2026-09-24T12:00:00Z | 2026-09-25T16:00:00Z | weekdays, missed occurrences skipped |
| 14 | `{"freq":"monthly","tz":"Europe/Paris"}` | – | 2026-01-31T17:00:00Z | 2026-01-31T18:00:00Z | 2026-02-28T17:00:00Z | the 31st → February 28 |
| 15 | `{"freq":"monthly","tz":"Europe/Paris"}` | 31 | 2026-02-28T17:00:00Z | 2026-02-28T18:00:00Z | 2026-03-31T16:00:00Z | … → back to March 31 (after the DST change) |
| 16 | `{"freq":"monthly","tz":"Europe/Paris"}` | 31 | 2026-03-31T16:00:00Z | 2026-03-31T17:00:00Z | 2026-04-30T16:00:00Z | … → April 30 |
| 17 | `{"freq":"monthly","tz":"Europe/Paris"}` | 31 | 2026-04-30T16:00:00Z | 2026-04-30T17:00:00Z | 2026-05-31T16:00:00Z | … → May 31, no drift |
| 18 | `{"freq":"monthly","tz":"Europe/Paris"}` | 31 | 2028-01-31T17:00:00Z | 2028-01-31T18:00:00Z | 2028-02-29T17:00:00Z | leap year |
| 19 | `{"freq":"monthly","interval":3,"tz":"Europe/Paris"}` | – | 2026-01-15T08:00:00Z | 2026-01-15T09:00:00Z | 2026-04-15T07:00:00Z | every 3 months |
| 20 | `{"freq":"monthly","tz":"Europe/Paris"}` | – | 2026-05-15T07:00:00Z | 2026-09-24T12:00:00Z | 2026-10-15T07:00:00Z | monthly, missed occurrences skipped |
| 21 | `{"freq":"daily","tz":"Europe/Paris"}` | – | 2026-03-28T07:00:00Z | 2026-03-28T08:00:00Z | 2026-03-29T06:00:00Z | Europe/Paris spring DST change: 08:00 CET → 08:00 CEST |
| 22 | `{"freq":"weekly","tz":"Europe/Paris"}` | – | 2026-10-19T16:30:00Z | 2026-10-19T17:00:00Z | 2026-10-26T17:30:00Z | Europe/Paris autumn DST change: 18:30 CEST → 18:30 CET |
| 23 | `{"freq":"daily","tz":"America/New_York"}` | – | 2026-03-07T14:00:00Z | 2026-03-07T15:00:00Z | 2026-03-08T13:00:00Z | another zone: 09:00 EST → 09:00 EDT |
| 24 | `{"freq":"monthly","tz":"Asia/Tokyo"}` | – | 2026-01-30T15:30:00Z | 2026-01-30T16:00:00Z | 2026-02-27T15:30:00Z | the local date counts: Jan 31 00:30 → Feb 28 00:30 JST |
| 25 | `{"freq":"weekly","weekdays":[7],"tz":"UTC"}` | – | 2026-09-27T20:00:00Z | 2026-09-27T21:00:00Z | 2026-10-04T20:00:00Z | Sunday only |
| 26 | `{"freq":"daily","tz":"Europe/Paris"}` | – | 1990-01-01T08:00:00Z | 2026-09-24T12:00:00Z | 2017-05-19T07:00:00Z | 10 000 steps at most: the result stays in the past |
| 27 | `{"freq":"monthly","interval":12,"tz":"Europe/Paris"}` | 29 | 2027-02-28T09:00:00Z | 2027-02-28T10:00:00Z | 2028-02-29T09:00:00Z | yearly on February 29 |

## 7. Activity feed

| `kind` | Written when | `actor_id` | `subject_id` | Snapshots |
|---|---|---|---|---|
| `task_created` | an end user inserts a task (`create_task` or a direct INSERT), not a spawn; trusted inserts (seed, service tasks) write nothing | creator | – | `task_title` |
| `task_completed` | a status **becomes** `done` (an UPDATE, including `done` → other → `done` again; `done` → `done` writes nothing; a trusted INSERT of a done task writes nothing) | `auth.uid()` (NULL in trusted contexts) | – | `task_title` |
| `turn_started` | a spawn with a turn holder, or a handover when the turn holder stops being a member (§6) | NULL | turn holder | `task_title` |
| `checklist_item_done` | an item **becomes** done (not a no-op, not an uncheck) | `auth.uid()` | – | `task_title`, `item_title` |
| `member_joined` | a `group_members` insert, except the first member of a group: its creator, whose membership `create_group` inserts alone. `already_member` inserts nothing | the member | the member | – |
| `member_left` | a `group_members` delete while the group still exists (leave, removal, account deletion) | `auth.uid()` | the member | – |

**Ids and snapshots:**
- **task_id:** the created or completed task; for `turn_started`, the new occurrence (spawn) or the pending occurrence (handover); for `checklist_item_done`, the item's task.
- **Order:** a completion writes `task_completed` before the spawn's `turn_started`; a departure writes `member_left` before the handover's `turn_started`.
- **Snapshots:** titles are copied when the event is written. They survive a later rename or deletion, and `task_id` stays (no foreign key).
- **Deleted profiles:** an actor or subject whose profile no longer exists is stored as NULL. For an account deletion, `member_left` has `actor_id` and `subject_id` NULL, and earlier events of that account become NULL (`on delete set null`).
- **Deleted groups:** no event is written for a group being deleted (`delete_group`, last member leaving, sole-member account deletion), and its events are deleted with it.

**Storage:**
- **Retention:** events older than 90 days of the same group (`created_at < now() − 90 days`: an event exactly 90 days old is kept) are deleted when a new event is written.
- **Signals:** writing an event does not bump the group; the triggering write already does.

**Read:** `GET group_activity?select=id,kind,actor_id,subject_id,task_id,task_title,item_title,created_at&group_id=eq.<g>&order=id.desc&limit=50`.
- **Names:** clients resolve them from the members list; an id outside it is « Un ancien membre ». A NULL `actor_id` / `subject_id` means no known person: a deleted account, or a server action (`turn_started`, trusted contexts).
- **Unknown kinds:** rows with an unknown `kind` are skipped, as for unknown enum values.

## 8. Weekly recap (client-side)

**Read:** `GET tasks?select=id,completed_by,completed_at&group_id=eq.<g>&status=eq.done&completed_at=gte.<monday 00:00 local, 3 weeks before the current week>`.

**Weeks** run from Monday 00:00 to Monday 00:00, in the local French calendar.

**The current week:**
- **Total:** all tasks done in the week.
- **Podium:** the top 3 `completed_by` among current members, by count descending, ties broken by `NameOrder` on the display name.
- **Streak:** the number of consecutive weeks, ending with the current week, in which the same person was the **sole** leader. It is shown when ≥ 2.
- **Excluded:** tasks completed by non-members or with a NULL `completed_by` count in the total only.

**Notification:** a local, repeating one every Monday at 09:00, « Le récap de la semaine est prêt ». It is scheduled on each device while a user is signed in, and can be switched off in Réglages.

## 9. Onboarding

**When:** after sign-in, the app shows the onboarding iff `profile.onboardedAt == nil` **and** `profile.createdAt` is less than 7 days old. The age condition covers accounts created with a v1 app.

**Steps:**
1. **Bienvenue.**
2. **Avatar** (color + initials or emoji; optional).
3. **Premier groupe:** create with a name, emoji and color, or join by code. Skipped when the user already has a group.
4. **Notifications:** skipped when the permission was already decided.

**Leaving:** finishing, or « Passer », calls `complete_onboarding()`.

**Profile read:** becomes `GET profiles?select=id,display_name,avatar_color,avatar_emoji,onboarded_at,created_at&id=eq.<me>`.

## 10. Reads (changes to CONTRACTS.md §4.3)

- **Members:** `profile:profiles(id,display_name,avatar_color,avatar_emoji)`.
- **Group tasks, one task, my tasks:** add `checklist:task_checklist_items(id,title,position,done,done_at,done_by)`. Clients sort by `(position, id)`.
- **My tasks:** the embedded group becomes `group:groups(name,color,emoji)`.
- **Assignments since:** the embedded task becomes `task:tasks(title,due_at,rotation,group:groups(name))`. Clients word rotation turns « C’est ton tour ».
- **Groups:** `groups(*)` already returns `color` and `emoji`.
- **Activity:** §7. **Recap:** §8.

## 11. Notifications

**Local assignment notification:**
- **Rotation turn:** when the assignment has `assigned_by = NULL` and the task has a rotation, the title becomes « C’est ton tour » and the body « « <title> » dans « <group> » ».
- **Continuations:** `assigned_by = me`, so they are already excluded by the v1 read.

**ntfy push:**
- **Rotation turn:** the message becomes « C’est ton tour dans « <group name> » ».
  - Exact string: `C’est ton tour dans « <group name> »`: U+2019 apostrophe, and the two spaces inside the guillemets are no-break spaces (U+00A0). The v1 message keeps its plain spaces.
  - Condition: `assigned_by` NULL on a task that has a rotation, i.e. a turn handed out by a spawn or by a handover (§6). The same deep link as v1, to the occurrence.
  - Other assignments keep the v1 message: a rotation's first turn at `create_task` or a new turn holder after `update_task` (both assigned by the editor), and the remaining member of a dropped rotation (spawn or handover).
- **Continuations:** they are not pushed (`assigned_by = user_id`). Neither is a turn taken by the completer (`assigned_by` = self).

## 12. Mocks and demo data

**Mocks.** `InMemoryBackend` mirrors every rule above: spawning (with `MockClock` as `now()`), rotation and the turn handover, checklist, activity, `completed_by`, onboarding, and the group signal of a profile change. It is not exempt from the contract scenarios. The rules that stay unmirrored are the same as in v1: quotas and push.

**Demo data (decided in the backend phase).**
- **Constraint:** the demo data must not break the v1 scenarios, including the Android port, which runs the scenarios against `supabase/seed.sql` until Android parity lands.
- **Groups:** v2 decorations on the existing groups: « Coloc’ rue des Lilas » `coral` `🏠`, « Projet Asso Sport » `green` `⚽` (U+26BD, no variation selector).
- **Rules:** no change to the v1 task rows that a scenario completes; new v2 rows only where no v1 scenario counts them.
- **Profiles:** every demo profile has `onboarded_at` set, to its `created_at` (the seed time, as the migration backfill does).
- **Decided:**
  - The decorations are separate `update` statements after the v1 inserts. The v1 rows keep their exact text, which the Android seed parity test reads.
  - No v2 task, rotation, checklist item or activity row is seeded. « Nettoyer la cuisine » keeps `completed_by` NULL: the recap counts it in the total only.
  - The fixture membership inserts write `member_joined` events, which the seed deletes: the demo feed starts empty.
  - `DemoData` mirrors this: colors and emojis, `onboardedAt = createdAt`, an empty feed.
