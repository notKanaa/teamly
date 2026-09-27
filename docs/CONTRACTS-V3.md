# Contracts v3: six social features, settings, shortcuts

This document extends [CONTRACTS.md](CONTRACTS.md) and [CONTRACTS-V2.md](CONTRACTS-V2.md). The app is now called
« Teamly ». Every rule of those documents stays in force, including the §0 compatibility rules of V2. Changes are
**additive**: the installed v2 iOS app and the v1 Android APK must keep working. The SQL agent and the Swift agent
implement this document in parallel; where they disagree, the pgTAP tests and the shared contract scenarios decide,
and the resolution is written back here.

**Conventions:**
- **Business errors:** `P0001` with a snake_case message.
- **Permission errors:** `42501 forbidden`.
- **Functions:** definer functions with `set search_path = ''`; explicit grants.
- **Strings:** French strings follow French typography.
- **Unknown values:** v2 clients skip unknown activity kinds and ignore unknown columns.

## 1. Relancer (nudge)

**Table** `task_nudges`:
- `id uuid pk default gen_random_uuid()`, `task_id uuid not null`, `group_id uuid not null`;
- `from_user uuid not null → profiles on delete cascade`, `to_user uuid not null → profiles on delete cascade`;
- `created_at timestamptz not null default now()`;
- fk `(task_id, group_id) → tasks(id, group_id) on delete cascade`.

**RLS:** SELECT when `from_user = me or to_user = me`, and the row's group is one of mine. No direct writes.

**RPC** `nudge_task(p_task_id uuid) returns integer`: the number of people nudged.
- **Caller:** any member of the task's group, not only editors. Otherwise `task_not_found`.
- **Task state:** the task must not be done: `task_done`.
- **Recipients:** the current assignees except the caller. None gives `nudge_no_recipient`.
- **Rate limit:** at most one nudge per (task, caller) in the last 20 hours: `nudge_rate_limited`. A refused call writes nothing.
- **Writes:**
  - one row per recipient;
  - one activity event per recipient, `task_nudged` (actor = caller, subject = recipient, `task_title` snapshot);
  - a bump of the group.
- **Push:** ntfy push to each recipient with a subscription. The message is « <prénom de l’expéditeur> te relance dans « <groupe> » ». No task title is sent, as with v1 pushes.

**Realtime:** `task_nudges` joins the publication. Clients listen to INSERT with filter `to_user=eq.<me>` and show a local notification:
- title « <Prénom> te relance »;
- body « « <titre> » » (looked up by the client);
- identifier `nudge-<id>`.

**Resolved (SQL, pgTAP `18_v3_nudges`):**
- **Order of the errors:** `task_not_found` → `task_done` → `nudge_no_recipient` → `nudge_rate_limited`.
- **Rate limit window:** inclusive, like the v1 windows: a nudge exactly 20 hours old still counts.
- **Rows and events:** in recipient id order (uuid order), one row then one event per recipient.
- **Push:**
  - Exact message: `<prénom> te relance dans « <groupe> »`, with no-break spaces (U+00A0) inside the guillemets, as the rotation push of V2 §11.
  - « Prénom » is the first word of the display name, as `FrenchText.firstName`: the trimmed name up to its first Unicode White_Space character (« Jean-Pierre Durand » → « Jean-Pierre »).
  - JSON `{topic, title: "Teamly", message, click: "equipe://task/<groupId>/<taskId>"}`, like the assignment push.
  - At most one nudge push per (recipient, task) per hour. Every push kind counts in `push_max_per_hour` (30 per user per hour). `private.push_log` gains `kind` (`assignment`, `nudge`, `mention`).
  - An earlier assignment push does not stop a nudge push. The assignment push keeps its v1 rule unchanged: no assignment push to a user already pushed about that task within the hour, whatever the kind.

## 2. Mode absent

**Profile columns** `away_from date null`, `away_until date null`: both NULL or both set, with `away_until >= away_from`. They are returned by the profile and member reads.

**RPC** `set_away(p_from date, p_until date, p_announce boolean default true) returns profiles`.
- **Validation:** `p_from <= p_until`, `p_until >= current_date - 1`, and a range of at most 366 days. Otherwise `invalid_away`.
- **Announcement:** when `p_announce` is true, a `member_away` event goes to each of the caller's groups (actor = subject = caller). `group_activity` gains the nullable columns `starts_on date` and `ends_on date` for it.
- **Handover:** every pending (not done) occurrence of a rotating task where the caller holds the turn, and whose local due date (`(due_at at time zone repeat_tz)::date`) falls in the range, is handed over. The rules are those of the V2 leave handover (next member, `assigned_by` NULL, a `turn_started` event), with the absence skip below.

**RPC** `clear_away() returns profiles`: sets both columns to NULL. It writes no event and moves no turn back.

**Absence skip:** whenever the server chooses a turn holder (create with a rotation, spawn, handover, swap repayment), it skips members who are away on the occurrence's local due date.
- If every candidate is away, the normal choice applies.
- Tasks without a rotation are not changed.

**Resolved (SQL, pgTAP `19_v3_away`):**
- **Validation:**
  - « today » is the UTC date, `(now() at time zone 'UTC')::date`: the result does not depend on the session time zone.
  - « at most 366 days » counts both ends: `p_until − p_from <= 365`.
  - A NULL date raises `invalid_away`. A NULL `p_announce` counts as true, the default.
- **Writes, in this order:**
  1. the profile;
  2. one `member_away` event per group of the caller, in group id order;
  3. the handovers, in local due date order, each with its `turn_started`.
- **Handover in `set_away`:**
  - The next member after the caller in the rotation who is not away on that day takes the turn; when every other member is away, the next member.
  - An occurrence whose rotation lists no other member keeps its turn.
  - The new turn holder is assigned with `assigned_by` NULL, so it is pushed and notified « C’est ton tour ».
- **Signals:**
  - A change of `away_from` / `away_until` bumps every group of the user, like an avatar change (V2 §2), so co-members reload the members.
  - The profile UPDATE is the user's own `.membershipsChanged`.
  - `clear_away` writes nothing (no signal) when the caller is not away.
- **Columns:**
  - Not writable directly: no column grant. They are read with the profile and the members, e.g. `profile:profiles(id,display_name,avatar_color,avatar_emoji,away_from,away_until)`.
  - The check constraint `profiles_away_range` enforces both or neither, and `away_until >= away_from`.
- **The choice (`private.pick_turn`):**
  - The candidates are the members of the group listed in the rotation, in rotation order, cyclically after the previous turn holder's position. The previous holder comes last, and the list starts at `rotation[1]` when there is no previous holder.
  - The first candidate not away on the local due date wins. When all of them are away, the first candidate wins (the normal choice).
  - At spawn, the previous turn holder is a candidate too: in a rotation of two, when the other member is away, the completer keeps the turn (assigned by themselves).
  - At create, `rotation[1]` unless away.
- **`update_task`** keeps its V2 rule, without any absence skip: a new rotation that does not list the turn holder gives the turn to `rotation[1]`, in the order the editor chose.

## 3. Échanger mon tour (turn swap: a favour that is paid back)

**Table** `turn_swaps`:
- `id uuid pk default gen_random_uuid()`, `task_id uuid not null`, `group_id uuid not null`, `series_id uuid not null`;
- `from_user uuid not null → profiles cascade`, `to_user uuid not null → profiles cascade`;
- `status text not null check in ('pending','accepted','declined','cancelled')`;
- `created_at`, `responded_at timestamptz null`, `repaid_at timestamptz null`;
- fk `(task_id, group_id) → tasks cascade`;
- at most one `pending` row per task (partial unique index).

**RLS:** SELECT for members of the group. No direct writes.

**RPC** `request_turn_swap(p_task_id uuid, p_to_user uuid) returns turn_swaps`. The caller must hold the turn of a pending rotating occurrence. Errors:
- `task_not_found`;
- `not_your_turn`;
- `invalid_rotation`: the target is not a current member listed in the rotation, or is the caller;
- `swap_pending`.

**RPC** `respond_turn_swap(p_swap_id uuid, p_accept boolean) returns turn_swaps`.
- **Caller:** only `to_user`: `forbidden`; unknown or invisible id: `swap_not_found`.
- **Status:** the swap must be `pending`: `swap_not_pending`.
- **Decline:** sets `declined` and `responded_at`.
- **Accept:**
  - sets `accepted`;
  - the occurrence's turn and its only assignee become `to_user`, with `assigned_by = to_user` (they accepted, so no notification);
  - writes a `turn_swapped` event (actor = to_user, subject = from_user) and bumps the group.

**RPC** `cancel_turn_swap(p_swap_id uuid) returns turn_swaps`: only by `from_user`, while `pending`.

**Automatic cancellation:** a pending swap becomes `cancelled` when its occurrence becomes done, is deleted, or changes turn holder another way.

**Repayment:** when the spawn picks the next turn holder N (after the absence skip), it checks for the oldest `accepted` swap of the same `series_id` with `to_user = N` and `repaid_at` NULL.
- If one exists and its `from_user` is a member who is not away, the turn goes to `from_user` instead, and the swap gets `repaid_at = now()`.
- In short, whoever did you a favour gets theirs back.

**Realtime:** `turn_swaps` joins the publication. Clients listen to:
- INSERT with filter `to_user=eq.<me>`: the notification « <Prénom> te propose son tour pour « <titre> » », identifier `swap-<id>`;
- UPDATE with filter `from_user=eq.<me>`: accepted or declined.

**Resolved (SQL, pgTAP `20_v3_turn_swaps`):**
- **Order of the errors:**
  - `request_turn_swap`: `task_not_found` → `not_your_turn` (done, no rotation, or another turn holder) → `invalid_rotation` (NULL, the caller, not listed, or listed but no longer a member) → `swap_pending`.
  - `respond_turn_swap`: `swap_not_found` → `forbidden` (not `to_user`, the requester included) → `23502 invalid_input` (NULL `p_accept`, as `set_checklist_item_done`) → `swap_not_pending`.
  - `cancel_turn_swap`: `swap_not_found` → `forbidden` (not `from_user`) → `swap_not_pending`.
- **`responded_at`** is set by every status change: accepted, declined, cancelled (by `from_user` or automatically). Check `(status = 'pending') = (responded_at is null)`.
- **Signals:** every write of `turn_swaps` bumps the group, not only the acceptance: request, answer, cancellation, repayment.
- **Automatic cancellation:** a pending swap becomes `cancelled` as soon as it can no longer be accepted as asked:
  - its occurrence becomes done, loses its rotation, gets another turn holder than `from_user` (handover, `set_away`, `update_task`), or no longer lists `to_user`;
  - `from_user` or `to_user` stops being a member of the group.
  - A deleted occurrence, or a deleted account of `from_user` / `to_user`, deletes the swap (foreign key cascade). There is no UPDATE event then.
  - An `in_progress` occurrence is still pending: its swap stays.
- **Repayment:**
  - The oldest swap is taken by `created_at`, then `id`, among the accepted, unrepaid swaps of the series with `to_user = N` whose `from_user` is still a member listed in the rotation (a swap whose `from_user` left never blocks the others).
  - When that `from_user` is away on the new local due date, nothing is repaid this time.
  - The repaid turn is assigned like any spawned turn: `assigned_by` NULL, or the completer when the completer takes it.
  - The debt is kept on the swap row. If the occurrence it was made on is deleted, the debt goes with it (foreign key cascade).
- **Realtime UPDATE events for `from_user`** are also sent for automatic cancellations and repayments (`repaid_at` set, status still `accepted`). Clients notify only when `status` is `declined`, or `accepted` with `repaid_at` NULL.

## 4. Bravo (reactions)

**Table** `activity_reactions`:
- `activity_id bigint not null → group_activity(id) on delete cascade`;
- `group_id uuid not null`;
- `user_id uuid not null → profiles cascade`;
- `target_user uuid null → profiles set null`: the event's actor when the reaction is made;
- `emoji text not null check in ('👏','🔥','💪','❤️','😂')`;
- `created_at`;
- pk `(activity_id, user_id, emoji)`.

**RLS:** SELECT for members.

**RPC** `toggle_reaction(p_activity_id bigint, p_emoji text) returns boolean` (true = added, false = removed).
- The caller must be a member of the event's group: otherwise `activity_not_found`.
- The emoji must be in the set: `invalid_reaction`.
- It bumps the group.

**Read:** the activity feed embeds `reactions:activity_reactions(user_id,emoji)`.

**Realtime:** INSERT with filter `target_user=eq.<me>` gives the notification « <Prénom> a réagi <emoji> à « <titre> » », which clients throttle to one per event.

**Resolved (SQL, pgTAP `21_v3_reactions`):**
- **Order of the errors:** `activity_not_found` (unknown event, or the caller is not a member of its group) → `invalid_reaction`.
- **The emojis** are compared exactly, without normalization: 👏 U+1F44F, 🔥 U+1F525, 💪 U+1F4AA, ❤️ U+2764 U+FE0F (the variation selector is required: a bare U+2764 is refused), 😂 U+1F602. NULL and `''` are refused.
- **`target_user`** is NULL for an event without actor (`turn_started`, trusted writes). It becomes NULL when the actor's account is deleted.
- **Signals:** adding and removing both bump the group.
- **Cascades:** the reactions go with their event (the 90-day retention included) and with the reacting account.

## 5. Commentaires

**Table** `task_comments`:
- `id uuid pk`, `task_id`, `group_id`;
- `author_id uuid null → profiles set null`;
- `body text not null`: `clean_text`, 1–1000 characters;
- `mentions uuid[] not null default '{}'`: distinct, at most 20, members of the group;
- `created_at`;
- fk `(task_id, group_id) → tasks cascade`.

**RLS:** SELECT for members.

**RPC** `add_task_comment(p_task_id uuid, p_body text, p_mentions uuid[] default '{}') returns task_comments`. Any member may comment. Errors:
- `task_not_found`;
- `invalid_comment`;
- `invalid_mentions`.

It writes a `comment_added` event (actor = author, `task_title` snapshot, `item_title` = the first 80 characters of the body) and bumps the group.

**RPC** `delete_task_comment(p_comment_id uuid)`: the author or a group admin. Errors: `comment_not_found`, `forbidden`.

**Reads:**
- `task_comments?select=*&task_id=eq.<t>&order=created_at.asc`.
- Task reads (group, one task, mine) add `comments:task_comments(count)` to show the count on rows.

**Push:** ntfy push to mentioned users with a subscription: « <Prénom> t’a mentionné dans « <groupe> » ».

**Realtime:** `task_comments` joins the publication. Clients listen to INSERT with filter `group_id=in.(<my groups>)`, the same 60-id limit as groups. They show a notification when they are mentioned or when they are assigned to the task, and never for their own comments.

**Resolved (SQL, pgTAP `22_v3_comments`):**
- **Order of the errors:**
  - `add_task_comment`: `task_not_found` → `invalid_comment` → `invalid_mentions`.
  - `delete_task_comment`: `comment_not_found` (missing, or the caller is not a member of its group, the author included) → `forbidden`.
- **Body:** trimmed with `clean_text` and stored trimmed. A NULL or blank body raises `invalid_comment`. Lengths count code points.
- **Mentions:**
  - NULL means none.
  - Refused with `invalid_mentions`: a NULL element, a multi-dimensional array, more than 20 distinct ids, a non-member.
  - Duplicates are dropped; the first occurrence and the order are kept.
  - Mentioning yourself is allowed; it is stored but not pushed.
- **Event:** `item_title` holds the first 80 code points of the stored (trimmed) body.
- **Delete:** a comment whose author's account was deleted (`author_id` NULL) can only be deleted by an admin. The `comment_added` event stays.
- **Signals:** every write (add, delete) bumps the group.
- **Push:**
  - Exact message: `<prénom> t’a mentionné dans « <groupe> »`, with U+2019 and no-break spaces, title « Teamly », the task's deep link. No comment text is sent.
  - Never to the author.
  - At most one mention push per (user, task) per hour; it counts in `push_max_per_hour`.
- **The count read** `comments:task_comments(count)` works without PostgREST aggregates (checked on v14.5) and returns `"comments": [{"count": 3}]`, a one-element array.

## 6. Photo preuve

**Storage:** private bucket `task-photos`, created by migration in `storage.buckets`.
- **Limits:** 5 MB, `image/jpeg` / `image/png` / `image/heic`.
- **Object path:** `<group_id>/<task_id>/<uuid>.<ext>`.
- **Policies on `storage.objects`, for that bucket:**
  - select and insert when the first path segment is one of my groups;
  - delete by the owner or an admin of that group.
- **Local stack:** enable storage in `supabase/config.toml`.

**Table** `task_photos`:
- `id uuid pk`, `task_id`, `group_id`;
- `path text not null unique`;
- `uploaded_by uuid null → profiles set null`;
- `created_at`;
- fk `(task_id, group_id) → tasks cascade`;
- at most 5 per task.

**RPC** `attach_task_photo(p_task_id uuid, p_path text) returns task_photos`.
- **Permission:** the rights of « change status » (admin, creator, assignee).
- **Path:** it must start with `<group_id>/<task_id>/`, and the object must exist in the bucket.
- **Errors:** `task_not_found`, `forbidden`, `invalid_photo`, `photo_limit`.
- **Writes:** a `photo_added` event and a bump of the group.

**RPC** `delete_task_photo(p_photo_id uuid)`: the uploader or an admin. It deletes the row; the client then deletes the object. Error: `photo_not_found`.

**Reads:** task reads add `photos:task_photos(id,path,uploaded_by,created_at)`. Clients display photos through signed URLs valid for 1 hour.

**Client upload:** resize to 1600 px on the longest side, JPEG quality 0.7.

**Orphans:** objects of deleted tasks are left behind; cleanup is a later task.

**Resolved (SQL, pgTAP `23_v3_photos`):**
- **Bucket:** the 5 MB limit is 5 MiB, i.e. 5 242 880 bytes.
- **Path, exactly:** `<group_id>/<task_id>/<uuid>.<ext>`.
  - The three ids are **lowercase**: Postgres `uuid::text`. Swift must use `uuidString.lowercased()`: an uppercase path is refused by the storage policies and by `attach_task_photo`.
  - `<ext>` is `jpg`, `jpeg`, `png` or `heic`, in lowercase.
  - Nothing else is accepted: no subfolder, no other file name.
- **Policies on `storage.objects`:**
  - `task_photos_objects_select` and `task_photos_objects_insert`: the first segment, as text, is one of my groups. A malformed first segment is simply refused, without an error.
  - `task_photos_objects_delete`: while a member of that group, the object's owner (`owner_id` = my id) or an admin of the group.
  - There is no UPDATE policy: clients upload without upsert (`x-upsert: false`), and objects are never moved.
- **`attach_task_photo`:**
  - Order of the errors: `task_not_found` → `forbidden` → `invalid_photo` → `photo_limit`.
  - `invalid_photo` also covers a NULL path, a path of another task's folder, a missing object, and a path already attached.
- **`delete_task_photo`:** `photo_not_found` → `42501 forbidden` (a member who is neither the uploader nor an admin, the task's creator included).
- **Signals:** attaching and deleting bump the group.
- **Realtime:** `task_photos` is not published; members reload through the group signal.
- **Account deletion:** a deleted uploader leaves `uploaded_by` NULL; after that, only admins may delete the photo.

## 7. Activity kinds added
`task_nudged`, `member_away`, `turn_swapped`, `comment_added`, `photo_added`. The `group_activity` kind check is dropped
and recreated with the full list.

**Resolved (SQL, pgTAP `24_v3_activity_realtime`):**

| `kind` | `actor_id` | `subject_id` | `task_id`, `task_title` | `item_title` | `starts_on`, `ends_on` |
|---|---|---|---|---|---|
| `task_nudged` | the caller | the nudged person (one event each) | the task | – | – |
| `member_away` | the caller | the caller | – | – | the range |
| `turn_swapped` | `to_user` | `from_user` | the occurrence | – | – |
| `comment_added` | the author | – | the task | the first 80 code points of the body | – |
| `photo_added` | the caller | – | the task | – | – |

- **Dates:** `starts_on` and `ends_on` are both set or both NULL, only on `member_away`, with `ends_on >= starts_on` (check `group_activity_away_range`).
- **Feed read:** `GET group_activity?select=id,kind,actor_id,subject_id,task_id,task_title,item_title,created_at,starts_on,ends_on,reactions:activity_reactions(user_id,emoji)&group_id=eq.<g>&order=id.desc&limit=50`.
- **Signals:** writing an event still does not bump by itself. The 90-day retention deletes the reactions of the events it removes, and that deletion bumps the group, which the triggering write has already done in the same transaction.

## 8. Personal stats (Réglages)
**Read:** `tasks?select=id,group_id,completed_at&completed_by=eq.<me>&completed_at=gte.<since>`.

**Figures:**
- « tâches ce mois »: tasks completed since the 1st of the month at 00:00 local time.
- « semaines de série »: consecutive Monday-to-Sunday weeks, counted back from the current week, with at least one completion. If the current week has none yet, the count starts from the previous week. The read covers the last 12 weeks.

## 9. Client-only settings (no server change)
- **Theme:** Auto, Clair or Sombre.
- **Alternate app icon:** A « Trio », B « Carte cochée » (default), C « Monogramme ».
- **Toggles:** confetti on completion, haptics.
- **Quiet hours:** default 22:00 → 08:00, off by default. During the window:
  - scheduled reminders move to the end of the window;
  - live notifications are delivered without sound.

  ntfy pushes are not affected, and the help text says so.

All these values are stored per device.

## 10. Errors (French messages)

| Code | Message |
|---|---|
| `task_done` | « Cette tâche est déjà terminée. » |
| `nudge_no_recipient` | « Personne d’autre n’est assigné à cette tâche. » |
| `nudge_rate_limited` | « Tu as déjà relancé cette tâche aujourd’hui. » |
| `invalid_away` | « Dates d’absence invalides. » |
| `not_your_turn` | « Ce n’est pas ton tour. » |
| `swap_pending` | « Une proposition est déjà en attente pour cette tâche. » |
| `swap_not_pending` | « Cette proposition n’est plus en attente. » |
| `swap_not_found` | `.notFound` |
| `activity_not_found` | `.notFound` |
| `invalid_reaction` | « Réaction invalide. » |
| `invalid_comment` | « Un commentaire doit contenir entre 1 et 1000 caractères. » |
| `invalid_mentions` | « Une personne mentionnée ne fait pas partie du groupe. » |
| `comment_not_found` | `.notFound` |
| `invalid_photo` | « Photo invalide. » |
| `photo_limit` | « 5 photos au maximum par tâche. » |
| `photo_not_found` | `.notFound` |

Also raised by the v3 RPCs, with their existing mapping:
- `not_authenticated`: every v3 RPC, without a JWT or with the JWT of a deleted account.
- `42501 forbidden`:
  - `respond_turn_swap` and `cancel_turn_swap`, when the caller is not the right party;
  - `delete_task_comment`;
  - `attach_task_photo`;
  - `delete_task_photo`.
- `23502 invalid_input` → `.invalidInput`: a NULL `p_accept` in `respond_turn_swap`.

## 11. Realtime bindings (one channel)
The v1 and v2 bindings, plus:
- `task_nudges` INSERT, `to_user=eq.<me>`;
- `turn_swaps` INSERT, `to_user=eq.<me>`;
- `turn_swaps` UPDATE, `from_user=eq.<me>`;
- `activity_reactions` INSERT, `target_user=eq.<me>`;
- `task_comments` INSERT, `group_id=in.(<my groups>)`.

DELETE is never published.

**Resolved (SQL):** the publication is exactly `groups`, `profiles`, `task_assignees`, `task_nudges`, `turn_swaps`,
`activity_reactions` and `task_comments`, with `publish = 'insert, update'`. Realtime applies the SELECT policy of each
table to every subscriber:
- **Nudges:** a nudge reaches only its sender and its recipient, while they are members.
- **Others:** the other tables reach the members of the group.

## 12. Backend implementation (migrations `20260926000200`–`20260926000600`)

- **`…200_v3_schema`:** the columns, the tables, the kind check, `private.push_log.kind`, RLS and grants.
- **`…300_v3_helpers`:** the private helpers:
  - `is_away`, `pick_turn`, `first_name`;
  - `write_activity`, which `log_activity` now calls;
  - `queue_push`, `push_message`.
- **`…400_v3_turns`:**
  - the absence skip at create (trigger `tasks_before_insert_v3`);
  - `spawn_next_occurrence` and `hand_over_turns`, replaced with their v2 body plus the absence skip and the repayment;
  - the automatic cancellation of swaps;
  - the away signal.
- **`…500_v3_rpcs`:** the eleven RPCs, the group signal of the new tables, and the nudge and mention pushes.
- **`…600_v3_storage_realtime`:** the bucket, the `storage.objects` policies and the publication.
- **Compatibility:** without anyone away and without swaps, every v1 and v2 behaviour is unchanged. No v1 or v2 signature changes.
