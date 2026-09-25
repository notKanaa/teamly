-- Équipe v2 — schema additions (docs/CONTRACTS-V2.md §2): appearance, onboarding, recurrence and rotation,
-- completed_by, checklists and the group activity feed.
--
-- Additive only (docs/CONTRACTS-V2.md §0): new nullable or defaulted columns and new tables. v1 clients ignore the
-- new columns, and nothing new is published to Realtime. The business rules live in the following migrations
-- (helpers, triggers, RPCs); the check constraints below are the last line of defense behind them.

-- Appearance ---------------------------------------------------------------------------------------------
-- ColorKey (§1): NULL = automatic color, computed by the clients from the id.
-- Emoji (§1): 1–16 code points, none from the trim set of private.clean_text nor a C0/C1 control. The triggers
-- normalize the value and raise `invalid_color` / `invalid_emoji` first.

alter table public.groups
  add column color text
    constraint groups_color_key
    check (color in ('indigo', 'violet', 'blue', 'teal', 'green', 'amber', 'orange', 'coral', 'pink')),
  add column emoji text
    constraint groups_emoji_format
    check (emoji ~ '^[^\u0001- \u007f-   -​    　]{1,16}$');

alter table public.profiles
  add column avatar_color text
    constraint profiles_avatar_color_key
    check (avatar_color in ('indigo', 'violet', 'blue', 'teal', 'green', 'amber', 'orange', 'coral', 'pink')),
  add column avatar_emoji text
    constraint profiles_avatar_emoji_format
    check (avatar_emoji ~ '^[^\u0001- \u007f-   -​    　]{1,16}$'),
  -- Onboarding (§9): NULL until complete_onboarding(). Accounts that exist before v2 are backfilled below.
  add column onboarded_at timestamptz;

-- Recurrence, rotation, completed_by (§2, §6) --------------------------------------------------------------
-- Server-maintained: repeat_month_day, series_id, next_occurrence_id, turn_user_id, completed_by.

alter table public.tasks
  add column repeat_freq text
    constraint tasks_repeat_freq_check check (repeat_freq in ('daily', 'weekly', 'monthly')),
  add column repeat_interval smallint not null default 1
    constraint tasks_repeat_interval_range check (repeat_interval between 1 and 52),
  -- Weekly rules only: ISO weekdays (1 = Monday … 7 = Sunday), distinct and ascending; NULL = the due date's weekday.
  add column repeat_weekdays smallint[],
  -- Monthly rules only: the day of month of the series (1–31), from the local due date.
  add column repeat_month_day smallint
    constraint tasks_repeat_month_day_range check (repeat_month_day between 1 and 31),
  -- IANA time zone of the rule, set iff the task repeats.
  add column repeat_tz text,
  -- Id of the first occurrence of the series, set iff the task repeats.
  add column series_id uuid,
  -- The occurrence spawned when this one was completed (no foreign key: it may be deleted).
  add column next_occurrence_id uuid,
  -- « À tour de rôle »: 2–20 distinct user ids, in turn order (recurring tasks only).
  add column rotation uuid[],
  -- Whose turn this occurrence is.
  add column turn_user_id uuid references public.profiles (id) on delete set null,
  -- Who completed the task (auth.uid() when the status became done).
  add column completed_by uuid references public.profiles (id) on delete set null,
  add constraint tasks_repeat_tz_iff_repeating check ((repeat_freq is null) = (repeat_tz is null)),
  add constraint tasks_series_id_iff_repeating check ((repeat_freq is null) = (series_id is null)),
  add constraint tasks_repeat_interval_default check (repeat_freq is not null or repeat_interval = 1),
  add constraint tasks_repeat_needs_due_at check (repeat_freq is null or due_at is not null),
  add constraint tasks_repeat_weekdays_check check (
    repeat_weekdays is null
    or (
      repeat_freq = 'weekly'
      and array_ndims(repeat_weekdays) = 1
      and array_position(repeat_weekdays, null) is null
      -- A non-empty, strictly ascending subset of 1…7.
      and (array_to_string(repeat_weekdays, ',') || ',') ~ '^(1,)?(2,)?(3,)?(4,)?(5,)?(6,)?(7,)?$'
      and cardinality(repeat_weekdays) >= 1
    )
  ),
  add constraint tasks_repeat_month_day_iff_monthly
    check ((repeat_freq is not distinct from 'monthly') = (repeat_month_day is not null)),
  add constraint tasks_rotation_check check (
    rotation is null
    or (
      repeat_freq is not null
      and array_ndims(rotation) = 1
      and cardinality(rotation) between 2 and 20
      and array_position(rotation, null) is null
    )
  ),
  add constraint tasks_turn_user_in_rotation
    check (turn_user_id is null or (rotation is not null and turn_user_id = any (rotation))),
  add constraint tasks_completed_by_when_done check (completed_by is null or status = 'done');

create index tasks_turn_user_id_idx on public.tasks (turn_user_id);
create index tasks_completed_by_idx on public.tasks (completed_by);

-- Checklists (§2) ----------------------------------------------------------------------------------------
-- Written by the checklist RPCs and the spawn only. position: 1…n at creation, max + 1 on add, gaps allowed.

create table public.task_checklist_items (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null,
  group_id uuid not null,
  title text not null
    constraint task_checklist_items_title_length check (char_length(title) between 1 and 200),
  position integer not null
    constraint task_checklist_items_position_positive check (position >= 1),
  done boolean not null default false,
  done_at timestamptz,
  done_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint task_checklist_items_task_fkey foreign key (task_id, group_id)
    references public.tasks (id, group_id) on delete cascade,
  constraint task_checklist_items_done_at_matches_done check (done = (done_at is not null)),
  -- Also the (task_id, position) index of the contract.
  constraint task_checklist_items_task_position_key unique (task_id, position)
);

create index task_checklist_items_done_by_idx on public.task_checklist_items (done_by);

-- Activity feed (§7) ---------------------------------------------------------------------------------------
-- Written by triggers only. task_id has no foreign key (the task may be deleted); the titles are snapshots.

create table public.group_activity (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.groups (id) on delete cascade,
  kind text not null
    constraint group_activity_kind_check check (kind in (
      'task_created', 'task_completed', 'turn_started', 'checklist_item_done', 'member_joined', 'member_left'
    )),
  actor_id uuid references public.profiles (id) on delete set null,
  subject_id uuid references public.profiles (id) on delete set null,
  task_id uuid,
  task_title text,
  item_title text,
  created_at timestamptz not null default now()
);

create index group_activity_group_id_id_idx on public.group_activity (group_id, id desc);
-- Retention: every event write deletes the group's events older than 90 days.
create index group_activity_group_id_created_at_idx on public.group_activity (group_id, created_at);
create index group_activity_actor_id_idx on public.group_activity (actor_id);
create index group_activity_subject_id_idx on public.group_activity (subject_id);

-- Row level security (§2 « Grants and RLS »): members of the group read; writes go through RPCs and triggers.

alter table public.task_checklist_items enable row level security;
alter table public.group_activity enable row level security;

create policy task_checklist_items_select on public.task_checklist_items
  for select to authenticated
  using (group_id in (select private.my_group_ids()));

create policy group_activity_select on public.group_activity
  for select to authenticated
  using (group_id in (select private.my_group_ids()));

-- Privileges -------------------------------------------------------------------------------------------------

revoke all on table public.task_checklist_items, public.group_activity from public, anon, authenticated;
revoke all on sequence public.group_activity_id_seq from public, anon, authenticated;

grant select on table public.task_checklist_items, public.group_activity to authenticated;

-- The self UPDATE column grant of profiles becomes (display_name, avatar_color, avatar_emoji).
grant update (avatar_color, avatar_emoji) on table public.profiles to authenticated;

-- Server-side tooling (service role bypasses RLS and is never shipped to clients).
grant select, insert, update, delete on table public.task_checklist_items, public.group_activity to service_role;
grant usage, select on sequence public.group_activity_id_seq to service_role;

-- Onboarding backfill (§2) -------------------------------------------------------------------------------------
-- Accounts created before v2 skip the onboarding: onboarded_at = created_at. Kept as a function so that pgTAP can
-- check it; API roles cannot execute it.

create function private.backfill_onboarded_at()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.profiles p
  set onboarded_at = p.created_at
  where p.onboarded_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function private.backfill_onboarded_at() from public, anon, authenticated;

select private.backfill_onboarded_at();
