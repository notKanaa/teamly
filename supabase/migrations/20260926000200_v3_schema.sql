-- Teamly v3 — schema additions (docs/CONTRACTS-V3.md): nudges, away mode, turn swaps, reactions, comments, task photos,
-- the new activity kinds and the kind of each queued ntfy push.
--
-- Additive only (docs/CONTRACTS-V2.md §0): new nullable columns, new tables, and the group_activity kind check dropped and
-- recreated with the full list. v1 and v2 clients ignore the new columns and skip the unknown activity kinds. The business
-- rules live in the following migrations (helpers, turns, RPCs, storage and Realtime); the check constraints below are
-- the last line of defense behind them.

-- Away mode (§2) --------------------------------------------------------------------------------------------------------
-- Both NULL or both set, away_until >= away_from. Written by set_away / clear_away only (no column grant).

alter table public.profiles
  add column away_from date,
  add column away_until date,
  add constraint profiles_away_range check (
    (away_from is null) = (away_until is null)
    and (away_until is null or away_until >= away_from)
  );

-- Activity feed (§7) ------------------------------------------------------------------------------------------------------
-- member_away carries its range in starts_on / ends_on (NULL for every other kind).

alter table public.group_activity
  add column starts_on date,
  add column ends_on date,
  add constraint group_activity_away_range check (
    (starts_on is null) = (ends_on is null)
    and (starts_on is null or (kind = 'member_away' and ends_on >= starts_on))
  );

alter table public.group_activity
  drop constraint group_activity_kind_check,
  add constraint group_activity_kind_check check (kind in (
    'task_created', 'task_completed', 'turn_started', 'checklist_item_done', 'member_joined', 'member_left',
    'task_nudged', 'member_away', 'turn_swapped', 'comment_added', 'photo_added'
  ));

-- Relancer (§1) -----------------------------------------------------------------------------------------------------------
-- One row per nudged person. Written by nudge_task only.

create table public.task_nudges (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null,
  group_id uuid not null,
  from_user uuid not null references public.profiles (id) on delete cascade,
  to_user uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint task_nudges_task_fkey foreign key (task_id, group_id)
    references public.tasks (id, group_id) on delete cascade,
  constraint task_nudges_distinct_users check (from_user <> to_user)
);

-- The rate limit (one nudge per task and caller in 20 hours) and the task cascade.
create index task_nudges_task_from_user_created_at_idx on public.task_nudges (task_id, from_user, created_at);
create index task_nudges_from_user_idx on public.task_nudges (from_user);
create index task_nudges_to_user_idx on public.task_nudges (to_user);

-- Échanger mon tour (§3) --------------------------------------------------------------------------------------------------
-- Written by the swap RPCs, the spawn (repaid_at) and the triggers that cancel a pending swap.
-- responded_at is set by every status change (accepted, declined, cancelled); repaid_at only on an accepted swap.

create table public.turn_swaps (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null,
  group_id uuid not null,
  series_id uuid not null,
  from_user uuid not null references public.profiles (id) on delete cascade,
  to_user uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending'
    constraint turn_swaps_status_check check (status in ('pending', 'accepted', 'declined', 'cancelled')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  repaid_at timestamptz,
  constraint turn_swaps_task_fkey foreign key (task_id, group_id)
    references public.tasks (id, group_id) on delete cascade,
  constraint turn_swaps_distinct_users check (from_user <> to_user),
  constraint turn_swaps_responded_at_matches_status check ((status = 'pending') = (responded_at is null)),
  constraint turn_swaps_repaid_when_accepted check (repaid_at is null or status = 'accepted')
);

-- At most one pending swap per occurrence.
create unique index turn_swaps_one_pending_per_task_idx on public.turn_swaps (task_id) where status = 'pending';
create index turn_swaps_task_id_group_id_idx on public.turn_swaps (task_id, group_id);
-- The repayment lookup of the spawn.
create index turn_swaps_repayment_idx on public.turn_swaps (series_id, to_user, created_at)
  where status = 'accepted' and repaid_at is null;
create index turn_swaps_from_user_idx on public.turn_swaps (from_user);
create index turn_swaps_to_user_idx on public.turn_swaps (to_user);
create index turn_swaps_group_id_idx on public.turn_swaps (group_id);

-- Bravo (§4) --------------------------------------------------------------------------------------------------------------
-- The five emojis, exactly (no normalization): 👏 U+1F44F, 🔥 U+1F525, 💪 U+1F4AA, ❤️ U+2764 U+FE0F, 😂 U+1F602.
-- target_user = the event's actor when the reaction is made. Written by toggle_reaction only.

create table public.activity_reactions (
  activity_id bigint not null references public.group_activity (id) on delete cascade,
  group_id uuid not null,
  user_id uuid not null references public.profiles (id) on delete cascade,
  target_user uuid references public.profiles (id) on delete set null,
  emoji text not null
    constraint activity_reactions_emoji_check
    check (emoji in (U&'\+01F44F', U&'\+01F525', U&'\+01F4AA', U&'\2764\FE0F', U&'\+01F602')),
  created_at timestamptz not null default now(),
  primary key (activity_id, user_id, emoji)
);

create index activity_reactions_group_id_idx on public.activity_reactions (group_id);
create index activity_reactions_user_id_idx on public.activity_reactions (user_id);
create index activity_reactions_target_user_idx on public.activity_reactions (target_user);

-- Commentaires (§5) -------------------------------------------------------------------------------------------------------
-- body: trimmed with private.clean_text, 1–1000 code points. mentions: distinct members of the group, at most 20.
-- Written by add_task_comment / delete_task_comment only.

create table public.task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null,
  group_id uuid not null,
  author_id uuid references public.profiles (id) on delete set null,
  body text not null
    constraint task_comments_body_length check (char_length(body) between 1 and 1000),
  mentions uuid[] not null default '{}'
    constraint task_comments_mentions_check check (
      cardinality(mentions) <= 20
      and (cardinality(mentions) = 0 or array_ndims(mentions) = 1)
      and array_position(mentions, null) is null
    ),
  created_at timestamptz not null default now(),
  constraint task_comments_task_fkey foreign key (task_id, group_id)
    references public.tasks (id, group_id) on delete cascade
);

create index task_comments_task_id_created_at_idx on public.task_comments (task_id, created_at);
create index task_comments_group_id_idx on public.task_comments (group_id);
create index task_comments_author_id_idx on public.task_comments (author_id);

-- Photo preuve (§6) -------------------------------------------------------------------------------------------------------
-- path: the object's name in the private bucket `task-photos`, `<group_id>/<task_id>/<uuid>.<ext>` (lowercase ids).
-- At most 5 per task (attach_task_photo). Written by attach_task_photo / delete_task_photo only.

create table public.task_photos (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null,
  group_id uuid not null,
  path text not null
    constraint task_photos_path_key unique,
  uploaded_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint task_photos_task_fkey foreign key (task_id, group_id)
    references public.tasks (id, group_id) on delete cascade,
  constraint task_photos_path_prefix check (starts_with(path, group_id::text || '/' || task_id::text || '/'))
);

create index task_photos_task_id_group_id_idx on public.task_photos (task_id, group_id);
create index task_photos_group_id_idx on public.task_photos (group_id);
create index task_photos_uploaded_by_idx on public.task_photos (uploaded_by);

-- ntfy push log (§1, §5) --------------------------------------------------------------------------------------------------
-- The kind of each queued push. The v1 assignment trigger inserts without it ('assignment'). Nudge and mention pushes are
-- limited to one per (user, task, kind) per hour; every kind counts in push_max_per_hour.

alter table private.push_log
  add column kind text not null default 'assignment'
    constraint push_log_kind_check check (kind in ('assignment', 'nudge', 'mention'));

-- Row level security ------------------------------------------------------------------------------------------------------
-- SELECT through the definer helpers (no 42P17 recursion); no direct write: RPCs and triggers only.

alter table public.task_nudges enable row level security;
alter table public.turn_swaps enable row level security;
alter table public.activity_reactions enable row level security;
alter table public.task_comments enable row level security;
alter table public.task_photos enable row level security;

-- Nudges: the sender and the recipient, while members of the group.
create policy task_nudges_select on public.task_nudges
  for select to authenticated
  using (
    (from_user = (select auth.uid()) or to_user = (select auth.uid()))
    and group_id in (select private.my_group_ids())
  );

create policy turn_swaps_select on public.turn_swaps
  for select to authenticated
  using (group_id in (select private.my_group_ids()));

create policy activity_reactions_select on public.activity_reactions
  for select to authenticated
  using (group_id in (select private.my_group_ids()));

create policy task_comments_select on public.task_comments
  for select to authenticated
  using (group_id in (select private.my_group_ids()));

create policy task_photos_select on public.task_photos
  for select to authenticated
  using (group_id in (select private.my_group_ids()));

-- Privileges ----------------------------------------------------------------------------------------------------------------

revoke all on table
  public.task_nudges,
  public.turn_swaps,
  public.activity_reactions,
  public.task_comments,
  public.task_photos
from public, anon, authenticated;

grant select on table
  public.task_nudges,
  public.turn_swaps,
  public.activity_reactions,
  public.task_comments,
  public.task_photos
to authenticated;

-- Server-side tooling (service role bypasses RLS and is never shipped to clients).
grant select, insert, update, delete on table
  public.task_nudges,
  public.turn_swaps,
  public.activity_reactions,
  public.task_comments,
  public.task_photos
to service_role;
