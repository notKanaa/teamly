-- Équipe — tables (docs/CONTRACTS.md §3). Privileges and RLS are set in a later migration.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null
    constraint profiles_display_name_length check (char_length(display_name) between 1 and 50),
  memberships_changed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null
    constraint groups_name_length check (char_length(name) between 1 and 60),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  last_activity_at timestamptz not null default now()
);

create index groups_created_by_idx on public.groups (created_by);

create table public.group_invites (
  group_id uuid primary key references public.groups (id) on delete cascade,
  code text not null
    constraint group_invites_code_key unique
    constraint group_invites_code_format check (code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create index group_invites_created_by_idx on public.group_invites (created_by);

create table public.group_members (
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.member_role not null default 'member',
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create index group_members_user_id_idx on public.group_members (user_id);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  title text not null
    constraint tasks_title_length check (char_length(title) between 1 and 200),
  details text
    constraint tasks_details_length check (details is null or char_length(details) between 1 and 5000),
  status public.task_status not null default 'todo',
  priority public.task_priority not null default 'medium',
  due_at timestamptz,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint tasks_completed_at_matches_status check ((status = 'done') = (completed_at is not null)),
  constraint tasks_id_group_id_key unique (id, group_id)
);

create index tasks_group_id_idx on public.tasks (group_id);
create index tasks_created_by_idx on public.tasks (created_by);

create table public.task_assignees (
  task_id uuid not null,
  group_id uuid not null,
  user_id uuid not null,
  assigned_by uuid references public.profiles (id) on delete set null,
  assigned_at timestamptz not null default now(),
  primary key (task_id, user_id),
  -- An assignment lives and dies with its task…
  constraint task_assignees_task_fkey foreign key (task_id, group_id)
    references public.tasks (id, group_id) on delete cascade,
  -- …and with the assignee's membership: an assignee is always a member of the task's group.
  constraint task_assignees_member_fkey foreign key (group_id, user_id)
    references public.group_members (group_id, user_id) on delete cascade
);

create index task_assignees_group_user_idx on public.task_assignees (group_id, user_id);
create index task_assignees_user_assigned_at_idx on public.task_assignees (user_id, assigned_at);
create index task_assignees_task_group_idx on public.task_assignees (task_id, group_id);
create index task_assignees_assigned_by_idx on public.task_assignees (assigned_by);

-- ntfy topic of a user (opt-in push, docs/CONTRACTS.md §7).
create table public.push_subscriptions (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  topic text not null
    constraint push_subscriptions_topic_key unique
    constraint push_subscriptions_topic_format check (topic ~ '^equipe-[a-z0-9]{24}$'),
  created_at timestamptz not null default now()
);

-- Invite-code attempts, for rate limiting `join_group_by_code`.
create table private.join_attempts (
  user_id uuid not null,
  attempted_at timestamptz not null default now(),
  succeeded boolean not null
);

create index join_attempts_user_attempted_at_idx on private.join_attempts (user_id, attempted_at);
