-- Équipe — row level security and table privileges (docs/CONTRACTS.md §5).
-- Policies target `authenticated` only; `anon` has no table privilege at all. Tables are granted
-- explicitly (new projects no longer auto-expose tables to the API roles).

alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_invites enable row level security;
alter table public.group_members enable row level security;
alter table public.tasks enable row level security;
alter table public.task_assignees enable row level security;
alter table public.push_subscriptions enable row level security;
alter table private.join_attempts enable row level security;

-- profiles: self or co-member; the user updates their own display name only (column grant).
create policy profiles_select on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or id in (select private.co_member_ids()));

create policy profiles_update on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- groups: members only; every write goes through RPCs.
create policy groups_select on public.groups
  for select to authenticated
  using (id in (select private.my_group_ids()));

-- group_invites: admins of the group only.
create policy group_invites_select on public.group_invites
  for select to authenticated
  using (group_id in (select private.my_admin_group_ids()));

-- group_members: members of the group (through the definer helper: no 42P17 recursion).
create policy group_members_select on public.group_members
  for select to authenticated
  using (group_id in (select private.my_group_ids()));

-- tasks
create policy tasks_select on public.tasks
  for select to authenticated
  using (group_id in (select private.my_group_ids()));

create policy tasks_insert on public.tasks
  for insert to authenticated
  with check (
    group_id in (select private.my_group_ids())
    and created_by = (select auth.uid())
  );

-- Admin, creator still member, or assignee. The BEFORE UPDATE trigger restricts non-editors to `status`.
create policy tasks_update on public.tasks
  for update to authenticated
  using (
    group_id in (select private.my_admin_group_ids())
    or (created_by = (select auth.uid()) and group_id in (select private.my_group_ids()))
    or id in (select private.my_assigned_task_ids())
  )
  with check (
    group_id in (select private.my_admin_group_ids())
    or (created_by = (select auth.uid()) and group_id in (select private.my_group_ids()))
    or id in (select private.my_assigned_task_ids())
  );

create policy tasks_delete on public.tasks
  for delete to authenticated
  using (
    group_id in (select private.my_admin_group_ids())
    or (created_by = (select auth.uid()) and group_id in (select private.my_group_ids()))
  );

-- task_assignees: members of the group; writes through RPCs.
create policy task_assignees_select on public.task_assignees
  for select to authenticated
  using (group_id in (select private.my_group_ids()));

-- push_subscriptions: self; writes through RPCs.
create policy push_subscriptions_select on public.push_subscriptions
  for select to authenticated
  using (user_id = (select auth.uid()));

-- private.join_attempts: RLS enabled without policy (only definer functions touch it).

-- Privileges ---------------------------------------------------------------------------------------

revoke all on table
  public.profiles,
  public.groups,
  public.group_invites,
  public.group_members,
  public.tasks,
  public.task_assignees,
  public.push_subscriptions
from public, anon, authenticated;

revoke all on table private.join_attempts from public, anon, authenticated;

grant select on table
  public.profiles,
  public.groups,
  public.group_invites,
  public.group_members,
  public.tasks,
  public.task_assignees,
  public.push_subscriptions
to authenticated;

grant update (display_name) on table public.profiles to authenticated;

grant insert (group_id, title, details, priority, due_at) on table public.tasks to authenticated;
grant update (title, details, status, priority, due_at) on table public.tasks to authenticated;
grant delete on table public.tasks to authenticated;

-- Server-side tooling (service role bypasses RLS and is never shipped to clients).
grant select, insert, update, delete on table
  public.profiles,
  public.groups,
  public.group_invites,
  public.group_members,
  public.tasks,
  public.task_assignees,
  public.push_subscriptions
to service_role;
