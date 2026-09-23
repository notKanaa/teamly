-- Équipe — RLS helper functions (docs/CONTRACTS.md §5).
-- `security definer` so that policies never query `group_members` under RLS themselves (no 42P17
-- infinite recursion). They only ever describe the calling user's own memberships.

create function private.my_group_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select gm.group_id
  from public.group_members gm
  where gm.user_id = (select auth.uid());
$$;

create function private.my_admin_group_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select gm.group_id
  from public.group_members gm
  where gm.user_id = (select auth.uid())
    and gm.role = 'admin';
$$;

create function private.my_assigned_task_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select ta.task_id
  from public.task_assignees ta
  where ta.user_id = (select auth.uid());
$$;

-- Every user sharing at least one group with the caller (the caller included when they have a group).
create function private.co_member_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct other.user_id
  from public.group_members mine
  join public.group_members other on other.group_id = mine.group_id
  where mine.user_id = (select auth.uid());
$$;

create function private.is_group_member(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.group_members gm
    where gm.group_id = p_group_id
      and gm.user_id = (select auth.uid())
  );
$$;

create function private.is_group_admin(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.group_members gm
    where gm.group_id = p_group_id
      and gm.user_id = (select auth.uid())
      and gm.role = 'admin'
  );
$$;

-- Policies are evaluated with the privileges of the querying role: it needs EXECUTE on the helpers it
-- triggers, but still no USAGE on schema `private`, so the helpers cannot be called by name.
revoke all on function private.my_group_ids() from public, anon;
revoke all on function private.my_admin_group_ids() from public, anon;
revoke all on function private.my_assigned_task_ids() from public, anon;
revoke all on function private.co_member_ids() from public, anon;
revoke all on function private.is_group_member(uuid) from public, anon;
revoke all on function private.is_group_admin(uuid) from public, anon;

grant execute on function private.my_group_ids() to authenticated;
grant execute on function private.my_admin_group_ids() to authenticated;
grant execute on function private.my_assigned_task_ids() to authenticated;
grant execute on function private.co_member_ids() to authenticated;
grant execute on function private.is_group_member(uuid) to authenticated;
grant execute on function private.is_group_admin(uuid) to authenticated;
