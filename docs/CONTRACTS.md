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

All strings are trimmed (`btrim` / `trimmingCharacters(in: .whitespacesAndNewlines)`) before validation and storage.

| Field | Rule | Error (message code → `AppError`) |
|---|---|---|
| `profiles.display_name` | 1–50 chars | `invalid_display_name` → `.invalidDisplayName` |
| `groups.name` | 1–60 chars | `invalid_name` → `.invalidName` |
| `tasks.title` | 1–200 chars | `invalid_title` → `.invalidTitle` |
| `tasks.details` | ≤ 5000 chars, empty string stored as NULL | `invalid_details` → `.invalidDetails` |
| password | ≥ 8 chars (Supabase Auth `minimum_password_length`) | `.weakPassword` |
| invite code | 8 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`; input normalized by uppercasing and dropping every non-`[A-Z0-9]` char | `invalid_code` → `.invalidCode` |
| assignees | ≤ 20 distinct users, all members of the task's group | `too_many_assignees`, `assignee_not_member` |

`Limits` (Swift) mirrors these numbers.

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
- Account deletion: for each group of the user — if they are the only member, the group is deleted; else if they are the only admin, the **oldest other member** (`joined_at`, then `user_id`) becomes admin. Then the auth user is deleted (cascades to profile, memberships, assignments; `created_by`/`assigned_by` become NULL).
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

Server-maintained fields: `created_by` (= `auth.uid()` on insert), `created_at`, `updated_at`, `completed_at` (set to `now()` when status becomes `done`, NULL otherwise), `last_activity_at`, `memberships_changed_at`.

## 4. API surface

Clients only use: PostgREST reads listed below, the RPCs below, `PATCH profiles` for the display name, Auth, and Realtime.
All RPCs are `POST /rest/v1/rpc/<name>` with named JSON params (`p_…`). Only role `authenticated` may call them (except `ping`).

### 4.1 RPCs

| RPC | Security | Returns | Behaviour | Errors |
|---|---|---|---|---|
| `create_group(p_name text)` | definer | `groups` row | creates group + caller as admin + invite code | `not_authenticated`, `invalid_name` |
| `join_group_by_code(p_code text)` | definer | `jsonb {status, group_id, group_name}` with `status ∈ joined, already_member, invalid_code` | normalizes code; logs attempt; > 10 failed attempts by the caller in the last hour → error | `not_authenticated`, `rate_limited` |
| `regenerate_invite_code(p_group_id uuid)` | definer | `text` (new code) | admin only | `forbidden` |
| `rename_group(p_group_id uuid, p_name text)` | definer | `groups` row | admin only | `forbidden`, `invalid_name`, `group_not_found` |
| `delete_group(p_group_id uuid)` | definer | void | admin only; cascades | `forbidden`, `group_not_found` |
| `set_member_role(p_group_id uuid, p_user_id uuid, p_role member_role)` | definer | void | admin only | `forbidden`, `not_member`, `last_admin` |
| `remove_member(p_group_id uuid, p_user_id uuid)` | definer | void | admin only | `forbidden`, `cannot_remove_self`, `not_member` |
| `leave_group(p_group_id uuid)` | definer | void | see §2 | `not_member`, `last_admin` |
| `create_task(p_group_id uuid, p_title text, p_details text default null, p_priority task_priority default 'medium', p_due_at timestamptz default null, p_assignee_ids uuid[] default '{}')` | invoker (+ definer helper) | `tasks` row | atomic insert + assignees | `forbidden` (not member), `invalid_title`, `invalid_details`, `too_many_assignees`, `assignee_not_member` |
| `update_task(p_task_id uuid, p_title text, p_details text, p_priority task_priority, p_due_at timestamptz, p_assignee_ids uuid[])` | invoker (+ definer helper) | `tasks` row | full edit, atomic; NULL `p_due_at` clears the due date | `task_not_found`, `forbidden`, validation errors |
| `set_task_status(p_task_id uuid, p_status task_status)` | invoker | `tasks` row | admin / creator / assignee | `task_not_found`, `forbidden` |
| `delete_task(p_task_id uuid)` | invoker | void | admin / creator | `task_not_found`, `forbidden` |
| `set_task_assignees(p_task_id uuid, p_user_ids uuid[])` | definer | void | admin or creator; replaces the set; keeps existing rows (and their `assigned_at`/`assigned_by`) for users still listed; new rows get `assigned_by = auth.uid()` | `task_not_found`, `forbidden`, `too_many_assignees`, `assignee_not_member` |
| `delete_my_account()` | definer | void | see §2 | `not_authenticated` |
| `enable_push()` | definer | `text` topic | creates (or returns existing) random topic `equipe-` + 24 chars `[a-z0-9]` | `not_authenticated` |
| `disable_push()` | definer | void | deletes the caller's subscription | `not_authenticated` |
| `ping()` | invoker, **anon allowed** | `text` `'pong'` | keep-alive | – |

`task_not_found` is raised when the task does not exist **or is not visible** to the caller (non-member); `forbidden` when visible but not allowed.

### 4.2 Error convention

- Business errors: `raise exception using errcode = 'P0001', message = '<code>'` → PostgREST HTTP 400 `{"code":"P0001","message":"<code>"}`.
- Permission errors raised by our code: `errcode = '42501', message = 'forbidden' | 'forbidden_fields'` → HTTP 403.
- Swift: `BackendErrorMapper.map(code:message:httpStatus:)` maps by message first, then SQLSTATE, then HTTP status.

### 4.3 Reads (PostgREST)

| Purpose | Request |
|---|---|
| My groups | `GET group_members?select=role,group:groups(*)&user_id=eq.<me>` → sort by `group.last_activity_at desc` client-side |
| Members | `GET group_members?select=user_id,role,joined_at,profile:profiles(id,display_name)&group_id=eq.<g>` |
| Invite code (admin) | `GET group_invites?select=code&group_id=eq.<g>` (0 rows for non-admins → `.forbidden`) |
| Group tasks | `GET tasks?select=*,assignees:task_assignees(user_id)&group_id=eq.<g>` + unless `includeOldDone`: `&or=(status.neq.done,completed_at.gte.<now-30d>)` |
| One task | `GET tasks?select=*,assignees:task_assignees(user_id)&id=eq.<t>` (0 rows → `.notFound`) |
| My tasks | `GET tasks?select=*,assignees:task_assignees(user_id),mine:task_assignees!inner(assigned_at,user_id),group:groups(name)&mine.user_id=eq.<me>` + unless `includeDone`: `&status=neq.done` |
| Assignments since | `GET task_assignees?select=task_id,group_id,assigned_by,assigned_at,task:tasks(title,due_at,group:groups(name))&user_id=eq.<me>&assigned_at=gt.<since>&or=(assigned_by.is.null,assigned_by.neq.<me>)&order=assigned_at.asc` |
| My profile | `GET profiles?select=id,display_name&id=eq.<me>` |
| Push topic | `GET push_subscriptions?select=topic&user_id=eq.<me>` |
| Update display name | `PATCH profiles?id=eq.<me>` body `{"display_name": …}` with `Prefer: return=representation` (0 rows → `.forbidden`) |

Timestamps are ISO-8601 with fractional seconds and offset. Assignee ids are returned sorted by the client (`assigneeIds` is sorted by `uuidString`).

## 5. RLS summary

All tables have RLS enabled; policies are `to authenticated` only; `anon` has no table privilege.
Helpers live in schema `private` (not exposed), are `security definer`, `set search_path = ''`, `stable`:
`my_group_ids()`, `my_admin_group_ids()`, `my_assigned_task_ids()`, `co_member_ids()`, `is_group_member(uuid)`, `is_group_admin(uuid)`.

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

## 6. Realtime (change signals)

Publication `supabase_realtime` contains exactly: `groups`, `profiles`, `task_assignees`.

| Binding | Filter | Meaning → `RealtimeEvent` |
|---|---|---|
| UPDATE `public.groups` | `id=in.(<my group ids>)` (≤ 100) | `.groupActivity(groupId)` |
| UPDATE `public.profiles` | `id=eq.<me>` | `.membershipsChanged` |
| INSERT `public.task_assignees` | `user_id=eq.<me>` | `.assigned(taskId, groupId, assignedBy)` |

Server-side signal bumps (AFTER triggers, at most once per group per transaction):
- any INSERT/UPDATE/DELETE on `tasks`, `task_assignees`, `group_members` of group G, and `rename_group` → `groups.last_activity_at = now()` for G;
- any INSERT/UPDATE/DELETE on `group_members` for user U → `profiles.memberships_changed_at = now()` for U.

Clients never listen to DELETE events (they bypass RLS). On `.connected` they reload everything.

## 7. Notifications

- Local notification ids: `due-<taskId>-<dueEpochSeconds>` (reminders), `assigned-<taskId>` (new assignment), `summary-<epochSeconds>` (grouped).
- `userInfo`: `taskId`, `groupId` (UUID strings).
- Reminders: only tasks assigned to me, not done, with a due date; fire at `dueAt - leadTime` if in the future; at most 60 pending (`ReminderPlanner`).
- Lead time options: at due time, 15 min, 1 h (default), 1 day, off.
- Deep link: `equipe://task/<groupId>/<taskId>` (ntfy `Click` header, notification taps).
- ntfy push (opt-in): on INSERT into `task_assignees` where `assigned_by is distinct from user_id` and the assignee has a `push_subscriptions` row, the DB (pg_net) POSTs to `https://ntfy.sh/<topic>` with title `Équipe`, message `Nouvelle tâche assignée dans « <group name> »`, header `Click: equipe://task/<groupId>/<taskId>`. No task title is sent.

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

Tasks (group « Coloc' rue des Lilas »): « Sortir les poubelles » (U1, high, due today 20:00, todo), « Faire les courses » (U2 + U1, medium, due tomorrow, in_progress), « Payer le loyer » (U3, high, overdue by 1 day, todo), « Réparer la fuite du lavabo » (unassigned, low, no due date, todo), « Nettoyer la cuisine » (U1, medium, done yesterday).
Tasks (group « Projet Asso Sport »): « Réserver le gymnase » (U1, high, due in 3 days, todo), « Créer l'affiche du tournoi » (U2, low, due in 7 days, in_progress).
