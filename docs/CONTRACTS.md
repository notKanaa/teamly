# Contracts (frozen)

Single source of truth shared by:
- the SQL backend (`supabase/migrations`, tested by `supabase/tests/database`),
- the in-memory mock backend (`TeamTasksMocks`),
- the Supabase adapters (`TeamTasksSupabase`),
- the client-side permission mirror and view models (`TeamTasksCore`).

Swift types referenced here live in `Packages/TeamTasksKit/Sources/TeamTasksCore/{Models,Services,Errors,Permissions,Validation}`.
Changing anything here requires updating **all** implementations and their tests.

---

## 1. Validation

All strings are trimmed before validation and storage. The trim set is pinned code point by code point (it is
neither Postgres `btrim` nor Apple's `.whitespacesAndNewlines`, which differ between platforms):
U+0009–000D, U+0020, U+0085, U+00A0, U+1680, U+2000–200B, U+2028, U+2029, U+202F, U+205F, U+3000.
SQL: `private.clean_text`; Swift: `InputValidation.trimmed` (TeamTasksCore). Lengths count code points (`char_length`).
U+0000 is refused in every text field (Postgres cannot store it) with that field's error.

| Field | Rule | Error (message code → `AppError`) |
|---|---|---|
| `profiles.display_name` | 1–50 chars | `invalid_display_name` → `.invalidDisplayName` |
| `groups.name` | 1–60 chars | `invalid_name` → `.invalidName` |
| `tasks.title` | 1–200 chars | `invalid_title` → `.invalidTitle` |
| `tasks.details` | ≤ 5000 chars, empty string stored as NULL | `invalid_details` → `.invalidDetails` |
| `tasks.due_at` | NULL or in [1970-01-01, 10000-01-01) UTC (no ±infinity, no BC) | `invalid_due_at` → `.invalidInput` |
| password | 8–72 UTF-8 **bytes** (Supabase Auth counts bytes; bcrypt limit 72) | `.weakPassword` (< 8), `.invalidInput` (> 72) |
| e-mail | trimmed + lowercased by the client, then HTML5 e-mail syntax | `.invalidEmail` |
| invite code | 8 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`; input normalized **per Unicode scalar**: uppercase (full case mapping, `ß` → `SS`), then drop every scalar outside `[A-Z0-9]` | `invalid_code` → `.invalidCode` |
| assignees | ≤ 20 distinct users (checked first), all members of the task's group | `too_many_assignees`, `assignee_not_member` |

Check order inside one call: permission → title → details → due date → assignees count → assignees membership.
`Limits` (Swift) mirrors these numbers; `InputValidation` (Swift) implements the rules above and is used by the mocks
and by the Supabase adapters **before** calling the server.

Sign-up: `AuthService.signUp` validates on the client with `InputValidation.signUp(email:password:displayName:)`
(e-mail, then password, then display name) because the server trigger `handle_new_user` never fails (it truncates
long names and falls back to the e-mail local part). Every e-mail sent to Auth is normalized first.

## 2. Roles & permissions

Roles per group: `admin`, `member`. A group always has ≥ 1 admin while it has members.

| Action | Admin | Creator (member) | Assignee (member) | Other member | Non-member |
|---|:-:|:-:|:-:|:-:|:-:|
| See group, members, all tasks | ✓ | ✓ | ✓ | ✓ | ✗ |
| Create task (assign anyone in the group, incl. self) | ✓ | ✓ | ✓ | ✓ | ✗ |
| Edit task fields (title, details, priority, due) + assignees | ✓ | ✓ | ✗ | ✗ | ✗ |
| Change task status | ✓ | ✓ | ✓ | ✗ | ✗ |
| Delete task | ✓ | ✓ | ✗ | ✗ | ✗ |
| Rename / delete group | ✓ | ✗ | ✗ | ✗ | ✗ |
| Read / regenerate invite code | ✓ | ✗ | ✗ | ✗ | ✗ |
| Change a member's role, remove a member | ✓ | ✗ | ✗ | ✗ | ✗ |
| Leave group | ✓ (last-admin rule) | ✓ | ✓ | ✓ | – |

"Creator" = `tasks.created_by = me` **and** still a member of the group. A creator who left has no rights.
Rights are evaluated per group: being admin of group A gives nothing in group B.

Membership rules:
- `set_member_role`: cannot demote the **last admin** (`last_admin`). An admin may demote themselves if another admin exists.
- `remove_member`: admin only, cannot target self (`cannot_remove_self`, use `leave_group`), target must be a member (`not_member`). Admins can remove other admins.
- `leave_group`: if caller is the only admin and other members remain → `last_admin`. If caller is the last member → the group is deleted.
- Removing/leaving deletes that user's assignments in the group (FK cascade). Tasks they created stay (`created_by` kept).
- Account deletion: for each group of the user — if they are the only member, the group is deleted; else if they are the only admin, the **oldest other member** (`joined_at`, then `user_id`) becomes admin. Then the user's Auth audit trail (`auth.audit_log_entries` rows whose `payload ->> 'actor_id'` is the user; best effort: if the platform refuses, only a warning is raised) and the auth user are deleted (cascades to profile, memberships, assignments; `created_by`/`assigned_by` become NULL).
- Safety net trigger: after any membership deletion, a group with members but no admin gets its oldest member promoted.

## 3. Database schema (`public` unless stated)

Enums: `member_role ('admin','member')`, `task_status ('todo','in_progress','done')`, `task_priority ('low','medium','high')`.

| Table | Columns |
|---|---|
| `profiles` | `id uuid pk → auth.users on delete cascade`, `display_name text not null`, `memberships_changed_at timestamptz not null default now()`, `created_at`, `updated_at` |
| `groups` | `id uuid pk default gen_random_uuid()`, `name text not null`, `created_by uuid null → profiles on delete set null`, `created_at timestamptz not null default now()`, `last_activity_at timestamptz not null default now()` |
| `group_invites` | `group_id uuid pk → groups on delete cascade`, `code text not null unique` (check `^[A-HJ-NP-Z2-9]{8}$`), `created_by uuid null → profiles set null`, `created_at` |
| `group_members` | `group_id → groups cascade`, `user_id → profiles cascade`, `role member_role not null default 'member'`, `joined_at timestamptz not null default now()`, pk `(group_id, user_id)` |
| `tasks` | `id uuid pk`, `group_id not null → groups cascade`, `title text not null`, `details text null`, `status task_status not null default 'todo'`, `priority task_priority not null default 'medium'`, `due_at timestamptz null`, `created_by uuid null → profiles set null`, `created_at`, `updated_at`, `completed_at timestamptz null`; check `(status = 'done') = (completed_at is not null)`; unique `(id, group_id)` |
| `task_assignees` | `task_id`, `group_id`, `user_id`, `assigned_by uuid null → profiles set null`, `assigned_at timestamptz not null default now()`; pk `(task_id, user_id)`; fk `(task_id, group_id) → tasks(id, group_id) on delete cascade`; fk `(group_id, user_id) → group_members(group_id, user_id) on delete cascade` |
| `push_subscriptions` | `user_id uuid pk → profiles cascade`, `topic text not null unique`, `created_at` — ntfy topic of the user |
| `private.join_attempts` | `user_id uuid`, `attempted_at timestamptz default now()`, `succeeded boolean` |
| `private.settings` | `key text pk`, `value text` — server settings read by definer functions: `ntfy_base_url`, `push_max_per_hour` (§7), `quota_groups_per_hour`, `quota_tasks_per_hour` (§4.1) |
| `private.push_log` | `user_id uuid not null → profiles on delete cascade`, `task_id uuid not null`, `queued_at timestamptz not null default now()` — ntfy pushes of the last hour (§7) |
| `private.write_log` | `user_id uuid not null → profiles on delete cascade`, `kind text not null` (check `kind in ('group', 'task')`), `created_at timestamptz not null default now()` — creations of the last hour (§4.1 write quotas) |

Server-maintained fields: `created_by` (= `auth.uid()` on insert), `created_at`, `updated_at`, `completed_at` (set to `now()` when status becomes `done`, NULL otherwise), `last_activity_at`, `memberships_changed_at`.

- `tasks.updated_at` moves **only** when `title`, `details`, `status`, `priority` or `due_at` actually changes. It is kept on an assignee-only edit, an edit with identical (trimmed) values, a same-status `set_task_status`, and when `created_by` becomes NULL (account deletion).
- `completed_at` is set when the status **becomes** `done`; `done` → `done` keeps it.
- `id`, `group_id`, `created_at` are immutable; `created_by` can only become NULL (`42501 immutable_field` → `.forbidden`).

## 4. API surface

Clients only use: PostgREST reads listed below, the RPCs below, `PATCH profiles` for the display name, Auth, and Realtime.
All RPCs are `POST /rest/v1/rpc/<name>` with named JSON params (`p_…`). Only role `authenticated` may call them (except `ping`).

### 4.1 RPCs

| RPC | Security | Returns | Behaviour | Errors |
|---|---|---|---|---|
| `create_group(p_name text)` | definer | `groups` row | creates group + caller as admin + invite code | `not_authenticated`, `invalid_name`, `rate_limited` |
| `join_group_by_code(p_code text)` | definer | `jsonb {status, group_id, group_name}` with `status ∈ joined, already_member, invalid_code` | normalizes code; logs attempt; if the caller already has **≥ 10 failed attempts with `attempted_at >= now() - 1 hour`** (inclusive), every further attempt raises `rate_limited` **before** the code lookup, valid codes included, and is not logged (so the 11th attempt after 10 failures is refused); `already_member` counts as a success | `not_authenticated`, `rate_limited` |
| `regenerate_invite_code(p_group_id uuid)` | definer | `text` (new code) | admin only | `forbidden` |
| `rename_group(p_group_id uuid, p_name text)` | definer | `groups` row | admin only | `forbidden`, `invalid_name`, `group_not_found` |
| `delete_group(p_group_id uuid)` | definer | void | admin only; cascades | `forbidden`, `group_not_found` |
| `set_member_role(p_group_id uuid, p_user_id uuid, p_role member_role)` | definer | void | admin only | `forbidden`, `not_member`, `last_admin` |
| `remove_member(p_group_id uuid, p_user_id uuid)` | definer | void | admin only | `forbidden`, `cannot_remove_self`, `not_member` |
| `leave_group(p_group_id uuid)` | definer | void | see §2 | `not_member`, `last_admin` |
| `create_task(p_group_id uuid, p_title text, p_details text default null, p_priority task_priority default 'medium', p_due_at timestamptz default null, p_assignee_ids uuid[] default '{}')` | invoker (+ definer helper) | `tasks` row | atomic insert + assignees | `forbidden` (not member), `invalid_title`, `invalid_details`, `too_many_assignees`, `assignee_not_member`, `rate_limited` |
| `update_task(p_task_id uuid, p_title text, p_details text, p_priority task_priority, p_due_at timestamptz, p_assignee_ids uuid[])` | invoker (+ definer helper) | `tasks` row | full edit, atomic; NULL `p_due_at` clears the due date | `task_not_found`, `forbidden`, validation errors |
| `set_task_status(p_task_id uuid, p_status task_status)` | invoker | `tasks` row | admin / creator / assignee | `task_not_found`, `forbidden` |
| `delete_task(p_task_id uuid)` | invoker | void | admin / creator | `task_not_found`, `forbidden` |
| `set_task_assignees(p_task_id uuid, p_user_ids uuid[])` | definer | void | admin or creator; replaces the set; keeps existing rows (and their `assigned_at`/`assigned_by`) for users still listed; new rows get `assigned_by = auth.uid()` | `task_not_found`, `forbidden`, `too_many_assignees`, `assignee_not_member` |
| `delete_my_account()` | definer | void | see §2 | `not_authenticated` |
| `enable_push()` | definer | `text` topic | creates (or returns existing) random topic `equipe-` + 24 chars `[a-z0-9]` | `not_authenticated` |
| `disable_push()` | definer | void | deletes the caller's subscription | `not_authenticated` |
| `ping()` | invoker, **anon allowed** | `text` `'pong'` | keep-alive | – |

`task_not_found` is raised when the task does not exist **or is not visible** to the caller (non-member); `forbidden` when visible but not allowed.

Write quotas (server only, **not mirrored by the mocks**): a user may create at most **20 groups** and **200 tasks** in the last hour (window inclusive: a creation exactly one hour old still counts; settings `quota_groups_per_hour` / `quota_tasks_per_hour` in `private.settings`), otherwise `rate_limited` → `.rateLimited`. They are enforced by BEFORE INSERT triggers on `groups` and `tasks`, so a direct `POST /rest/v1/tasks` counts too. Permission and validation errors come first; refused writes are not counted. Only end users are limited (`auth.uid()` not NULL: migrations, the seed and service tasks are exempt).

Resolved precedences and edge cases (SQL, mocks and scenarios agree):
- `rename_group` / `delete_group`: unknown group → `group_not_found`; existing group + non-admin (non-members included) → `forbidden`; then name validation.
- `regenerate_invite_code`, `set_member_role`, `remove_member` on an unknown group → `forbidden`.
- `set_member_role` order: `forbidden` → `not_member` → (unchanged role: return, no write, no signal) → `last_admin`. A NULL `p_role` → `23502 invalid_input` → `.invalidInput`.
- `remove_member` order: `forbidden` → `cannot_remove_self` → `not_member`.
- `update_task`: NULL `p_assignee_ids` leaves the assignees unchanged, `'{}'` clears them; NULL `p_priority` keeps the priority; NULL `p_due_at` clears the due date. (The Swift client always sends the full draft.)
- Every RPC raises `not_authenticated` when `auth.uid()` is NULL **or no longer exists** (stale JWT of a deleted account).
- The rows returned by `create_task`, `update_task`, `set_task_status` are bare `tasks` rows: adapters complete the `TaskItem` with its sorted `assigneeIds` so it equals a later `task(id:)` read.

### 4.2 Error convention

- Business errors: `raise exception using errcode = 'P0001', message = '<code>'` → PostgREST HTTP 400 `{"code":"P0001","message":"<code>"}`.
- Permission errors raised by our code: `errcode = '42501', message = 'forbidden' | 'forbidden_fields'` → HTTP 403.
- Swift: `BackendErrorMapper.map(code:message:httpStatus:)` maps by message first, then SQLSTATE, then HTTP status.
- A request without a valid user session is answered by PostgREST with HTTP **401** + `42501` → `.notAuthenticated` (our own `42501` errors are HTTP 403). Adapters also throw `.notAuthenticated` themselves when no local session exists.
- `22P05` (U+0000 in JSON) and `23502 invalid_input` → `.invalidInput`.
- A request whose session is refused (HTTP 401, or `P0001 not_authenticated`) is refreshed once and sent again with the new token; a dead refresh (revoked session, deleted account) removes the local session, which signs the device out (`.notAuthenticated`).
- Temporary failures — HTTP 5xx or 429, PostgREST `PGRST000`–`PGRST003`, `57014` (statement timeout), Auth `unexpected_failure` / `request_timeout` — become `.unknown("le serveur est momentanément indisponible, réessayez dans un instant")`.
- Auth codes without an `AppError` case of their own get a French `.unknown` detail (the server's English messages never reach the user): `email_address_not_authorized` (« l’envoi d’e-mails vers cette adresse n’est pas encore possible »), `signup_disabled` (« les inscriptions sont fermées pour le moment »), `email_provider_disabled` (« la connexion par e-mail est désactivée pour le moment »), `user_banned` (« ce compte est suspendu »), `reauthentication_needed` (« reconnectez-vous, puis réessayez »), `captcha_failed` (« la vérification de sécurité a échoué »), `over_request_rate_limit` (« trop de tentatives, réessayez dans quelques minutes »).

### 4.3 Reads (PostgREST)

| Purpose | Request |
|---|---|
| My groups | `GET group_members?select=role,group:groups(*)&user_id=eq.<me>` → sort by `group.last_activity_at desc` client-side |
| Members | `GET group_members?select=user_id,role,joined_at,profile:profiles(id,display_name)&group_id=eq.<g>` |
| Invite code (admin) | `GET group_invites?select=code&group_id=eq.<g>` (0 rows for non-admins → `.forbidden`) |
| Group tasks | `GET tasks?select=*,assignees:task_assignees(user_id)&group_id=eq.<g>` + unless `includeOldDone`: `&or=(status.neq.done,completed_at.gte.<now-30d>)` |
| One task | `GET tasks?select=*,assignees:task_assignees(user_id)&id=eq.<t>` (0 rows → `.notFound`) |
| My tasks | `GET tasks?select=*,assignees:task_assignees(user_id),mine:task_assignees!inner(assigned_at,assigned_by,user_id),group:groups(name)&mine.user_id=eq.<me>` + unless `includeDone`: `&status=neq.done` |
| Assignments since | `GET task_assignees?select=task_id,group_id,assigned_by,assigned_at,task:tasks(title,due_at,group:groups(name))&user_id=eq.<me>&assigned_at=gt.<since>&or=(assigned_by.is.null,assigned_by.neq.<me>)&order=assigned_at.asc` |
| My profile | `GET profiles?select=id,display_name&id=eq.<me>` |
| Push topic | `GET push_subscriptions?select=topic&user_id=eq.<me>` |
| Update display name | `PATCH profiles?select=id,display_name&id=eq.<me>` body `{"display_name": …}` with `Prefer: return=representation` (0 rows → `.forbidden`) |

Timestamps are ISO-8601 with an offset and **0 to 6** fractional digits (omitted when zero): decoders must accept all of them. Assignee ids are returned sorted by the client (`assigneeIds` is sorted by `uuidString`).

Read details:
- Timestamp **filter values** are sent in UTC with **6 fractional digits** (microseconds; supabase-swift's default `Date` filter value truncates to milliseconds — do not use it) and percent-encoded (`+` would read as a space).
- `assignments(since:)` is **exclusive** (`gt`).
- `TaskItem.myAssignedAt`, `myAssignedBy` (from `mine`) and `groupName` are filled by `myTasks` only (nil in every other read).
- Old done tasks: cutoff = `now − 30 × 86 400 s` (not calendar days), inclusive (`gte`).
- Row order of `tasks` / `myTasks` reads is unspecified: clients sort with `TaskSort`.
- `myGroups`: `last_activity_at` desc, ties by `NameOrder` (fr_FR, case- and diacritic-insensitive, then exact) then `id.uuidString`. `members`: admins first, then `NameOrder` on the display name, then `id.uuidString`. `NameOrder` lives in TeamTasksCore so every implementation sorts identically.

## 5. RLS summary

All tables have RLS enabled; policies are `to authenticated` only; `anon` has no table privilege.
Helpers live in schema `private` (not exposed), are `security definer`, `set search_path = ''`, `stable`:
`my_group_ids()`, `my_admin_group_ids()`, `my_assigned_task_ids()`, `co_member_ids()`, `is_group_member(uuid)`, `is_group_admin(uuid)`.
`authenticated` has EXECUTE on these helpers (policies run with the caller's privileges) but no USAGE on schema
`private`, so they cannot be called by name through the API.
The private tables `private.join_attempts`, `private.settings`, `private.push_log` and `private.write_log` have RLS
enabled **without any policy** and no API privilege: only definer functions and triggers touch them.

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| profiles | self or co-member | – (trigger) | self; column grant `display_name` | – |
| groups | member | – (RPC) | – (RPC) | – (RPC) |
| group_invites | admin of group | – | – | – |
| group_members | member of group | – (RPC) | – (RPC) | – (RPC) |
| tasks | member | member, `created_by = me` (via `create_task`) | admin / creator / assignee, trigger restricts non-editors to `status` | admin / creator |
| task_assignees | member of group | – (RPC) | – | – (RPC) |
| push_subscriptions | self | – (RPC) | – | – (RPC) |

Pitfalls (keep in mind everywhere):
1. A policy on `group_members` must never query `group_members` directly (infinite recursion 42P17) → use the definer helpers.
2. Every `security definer` function has `set search_path = ''` and schema-qualified names.
3. An UPDATE/DELETE denied by RLS affects 0 rows **without error** → RPCs check `found`/row counts and raise; clients never rely on silent PATCH/DELETE.
4. `create_group` must be an RPC (INSERT … RETURNING is checked against the SELECT policy before the membership exists).
5. PostgREST `neq` excludes NULLs → use `or=(col.is.null,col.neq.x)`.
6. PostgREST returns at most 1000 rows → old done tasks hidden by default.
7. `ON DELETE SET NULL` fires UPDATE triggers (the `created_by` immutability check must allow NULL).
8. Raising an exception rolls back everything, including rate-limit logs → `join_group_by_code` *returns* `invalid_code`.
9. Since 2026 new Supabase projects do not auto-grant tables to API roles → every table/function has explicit `grant`s.
10. Never expose schema `net` or `private` (API settings → exposed schemas): Supabase grants `anon`/`authenticated` EXECUTE on `net.http_post` (and USAGE on `net`) when pg_net is created, and `postgres` cannot revoke it; only the fact that `net` is not exposed keeps it out of the API.

## 6. Realtime (change signals)

Publication `supabase_realtime` contains exactly: `groups`, `profiles`, `task_assignees`, with
`publish = 'insert, update'`: DELETE and TRUNCATE events are **not** published (Realtime delivers them to every
subscriber without RLS, leaking primary keys).

| Binding | Filter | Meaning → `RealtimeEvent` |
|---|---|---|
| UPDATE `public.groups` | `id=in.(<my group ids>)`, **at most 60 ids** (the server fails the whole channel at ~70); `in.()` is accepted | `.groupActivity(groupId)` |
| UPDATE `public.profiles` | `id=eq.<me>` | `.membershipsChanged` |
| INSERT `public.task_assignees` | `user_id=eq.<me>` | `.assigned(taskId, groupId, assignedBy)` |

Server-side signal bumps (AFTER triggers, at most once per group per transaction) — "write" means an actual row write:
- any INSERT/UPDATE/DELETE on `tasks`, `task_assignees`, `group_members` of group G, and `rename_group` → `groups.last_activity_at = now()` for G. A same-status `set_task_status` or an identical `update_task` still writes the row, so it bumps;
- any INSERT/UPDATE/DELETE on `group_members` for user U → `profiles.memberships_changed_at = now()` for U;
- **no write, no signal**: `set_member_role` with an unchanged role, a join that returns `already_member`, `regenerate_invite_code`;
- a display-name `PATCH profiles` is also an UPDATE of `profiles` → `.membershipsChanged` for that user.

Client obligations:
- `events(userId:)`: `userId` is the session user; visibility follows the session (a signed-out client receives nothing).
- Emit `.connected` only on the `system` message with status `ok` ("Subscribed to PostgreSQL"), not on the join reply; a `system` error means the subscription failed.
- Changes committed shortly **before** the subscription may still be delivered after `.connected`: scenarios use a barrier event before taking a mark.
- Pass refreshed access tokens to the Realtime client (`setAuth`) so channels survive the JWT expiry (3600 s).
- Never listen to DELETE events. On `.connected`, reload everything.
- The Supabase realtime stream never ends by itself (the client reconnects on its own), so `RealtimeCoordinator` fetches the group ids again on each reconnection (a later `.connected`), while they are stale (a failed fetch is retried after 5 s, the delay doubling up to 60 s) and on return to the foreground (`refreshGroupIds()`); it re-subscribes when they changed.

## 7. Notifications

- Local notification ids: `due-<taskId>-<dueEpochSeconds>` (reminders), `assigned-<taskId>` (new assignment), `summary-<epochSeconds>` (grouped).
- `userInfo`: `taskId`, `groupId` (UUID strings).
- Reminders: only tasks assigned to me, not done, with a due date; fire at `dueAt - leadTime` if in the future; at most 60 pending (`ReminderPlanner`).
- Lead time options: at due time, 15 min, 1 h (default), 1 day, off.
- Deep link: `equipe://task/<groupId>/<taskId>` (ntfy `click` field, notification taps).
- `summary-<epochSeconds>` uses device time; two summaries in the same second replace each other (accepted).
- iOS scheduler adapter: a fire date that has passed between planning and `add()` is skipped (a time-interval trigger ≤ 0 s throws; a calendar trigger in the past never fires).
- App wiring: one `AssignmentNotifier` and one `ReminderSynchronizer` per signed-in user per process (also used by the background refresh), because their serialization is per instance. `synchronize(myTasks:)` is only called with a **successfully loaded** list (an empty list after a network error would remove every reminder). On sign-out: stop the `RealtimeCoordinator`, `removeAll()` reminders, `reset()` the notifier.
- The app injects `Calendar` with the French Gregorian rules and `TimeZone.autoupdatingCurrent`, and refreshes date-dependent UI on significant time changes.
- ntfy push (opt-in): on INSERT into `task_assignees` where `assigned_by is distinct from user_id` and the assignee has a `push_subscriptions` row, trigger `private.notify_assignment_push` queues with pg_net a POST of JSON `{"topic": "<topic>", "title": "Équipe", "message": "Nouvelle tâche assignée dans « <group name> »", "click": "equipe://task/<groupId>/<taskId>"}` to `private.settings.ntfy_base_url` (default `https://ntfy.sh/`; NULL or empty = push off, as in `supabase/seed.sql`). No task title or details are sent. At most 1 push per (user, task) and 30 per user per hour (`push_max_per_hour`; window inclusive, `private.push_log`). The request is queued in the assignment's transaction (nothing is sent if it rolls back); errors never fail the assignment (a preparation error becomes a WARNING, HTTP errors happen later in the pg_net worker).

## 8. Demo data (mocks & `supabase/seed.sql`)

Demo password for every seeded user: `motdepasse123`.

| User | Email | Display name |
|---|---|---|
| U1 (the "me" of mock scenario `populated`) | `camille@example.com` | Camille Martin |
| U2 | `lucas@example.com` | Lucas Bernard |
| U3 | `ines@example.com` | Inès Dubois |

| Group | Members | Invite code |
|---|---|---|
| « Coloc' rue des Lilas » | U1 admin, U2 member, U3 member | `LYLAS234` |
| « Projet Asso Sport » | U2 admin, U1 member | `SPRT5678` |

Tasks (group « Coloc' rue des Lilas »): « Sortir les poubelles » (U1, high, due today 20:00, todo), « Faire les courses » (U2 + U1, medium, due tomorrow, in_progress), « Payer le loyer » (U3, high, overdue: due yesterday, todo), « Réparer la fuite du lavabo » (unassigned, low, no due date, todo), « Nettoyer la cuisine » (U1, medium, done yesterday).
Tasks (group « Projet Asso Sport »): « Réserver le gymnase » (U1, high, due in 3 days, todo), « Créer l'affiche du tournoi » (U2, low, due in 7 days, in_progress).

`supabase/seed.sql` is **canonical** for everything this table leaves open; `TeamTasksMocks/DemoData` copies it:
- ids: users U1 `11111111-1111-4111-8111-111111111111`, U2 `22222222-2222-4222-8222-222222222222`, U3 `33333333-3333-4333-8333-333333333333`; groups `a0000000-0000-4000-8000-00000000000{1,2}`; tasks `b0000000-0000-4000-8000-00000000000{1…7}` in the order above;
- creators (= assigners): poubelles, loyer → U1; courses, cuisine → U2; lavabo → U3; both Asso Sport tasks → U2;
- due times in Europe/Paris: today 20:00, tomorrow 18:00, loyer = yesterday 18:00, +3 days 18:00, +7 days 12:00; cuisine `completed_at` = yesterday 19:00;
- mock scenario `emptyGroups` adds one extra account (not seeded): Alex Moreau, `alex@example.com`, id `c0000000-0000-4000-8000-000000000004`, member of no group.

## 9. Adapter obligations (phase 2B)

- Validate every input with `InputValidation` before calling the server (§1), normalize e-mails.
- `signOut` uses the **local** scope (only this device), like the mocks.
- `updatePassword` with the current password: Supabase Auth answers `422 same_password`; the adapter treats it as success (the requested end state holds).
- `deleteAccount` answered `not_authenticated` with an accepted token (the account no longer exists: an earlier attempt whose answer was lost, or another device) counts as success, followed by the local sign-out.
- List reads leave out rows with an enum value unknown to the client (a value added by a later migration) instead of failing the whole list; a single-row read of such a row is an error. Clients must be tolerant **before** the server adds enum values: ship the tolerant client first.
- View models ignore `CancellationError` (a cancelled SwiftUI `.task` must not surface « annulé »).
