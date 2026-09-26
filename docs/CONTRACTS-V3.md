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

## 7. Activity kinds added
`task_nudged`, `member_away`, `turn_swapped`, `comment_added`, `photo_added`. The `group_activity` kind check is dropped
and recreated with the full list.

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

## 11. Realtime bindings (one channel)
The v1 and v2 bindings, plus:
- `task_nudges` INSERT, `to_user=eq.<me>`;
- `turn_swaps` INSERT, `to_user=eq.<me>`;
- `turn_swaps` UPDATE, `from_user=eq.<me>`;
- `activity_reactions` INSERT, `target_user=eq.<me>`;
- `task_comments` INSERT, `group_id=in.(<my groups>)`.

DELETE is never published.
