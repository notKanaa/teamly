-- Équipe — account deletion, ntfy push subscription, keep-alive ping and the Realtime publication
-- (docs/CONTRACTS.md §2, §4.1, §6).

-- delete_my_account -------------------------------------------------------------------------------------
-- For each group of the caller: sole member → the group is deleted; only admin → the oldest other
-- member (joined_at, then user_id) becomes admin. Then the auth user is deleted, which cascades to the
-- profile, memberships, assignments and push subscription; created_by / assigned_by become NULL.
create function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_group_id uuid;
  v_role public.member_role;
  v_members integer;
  v_admins integer;
  v_next uuid;
begin
  for v_group_id, v_role in
    select gm.group_id, gm.role
    from public.group_members gm
    where gm.user_id = v_uid
    order by gm.group_id
  loop
    perform 1 from public.groups g where g.id = v_group_id for update;

    select count(*), count(*) filter (where gm.role = 'admin')
    into v_members, v_admins
    from public.group_members gm
    where gm.group_id = v_group_id;

    if v_members = 1 then
      delete from public.groups g where g.id = v_group_id;
    elsif v_role = 'admin' and v_admins = 1 then
      select gm.user_id into v_next
      from public.group_members gm
      where gm.group_id = v_group_id
        and gm.user_id <> v_uid
      order by gm.joined_at, gm.user_id
      limit 1;

      update public.group_members
      set role = 'admin'
      where group_id = v_group_id
        and user_id = v_next;
    end if;
  end loop;

  delete from private.join_attempts ja where ja.user_id = v_uid;
  delete from auth.users u where u.id = v_uid;
end;
$$;

-- Push (ntfy) -------------------------------------------------------------------------------------------

-- Creates (or returns the existing) private topic of the caller: `equipe-` + 24 chars [a-z0-9].
create function public.enable_push()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_topic text;
begin
  select ps.topic into v_topic
  from public.push_subscriptions ps
  where ps.user_id = v_uid;
  if found then
    return v_topic;
  end if;

  insert into public.push_subscriptions (user_id, topic)
  values (v_uid, 'equipe-' || private.random_string('abcdefghijklmnopqrstuvwxyz0123456789', 24))
  on conflict (user_id) do nothing;

  select ps.topic into v_topic
  from public.push_subscriptions ps
  where ps.user_id = v_uid;
  return v_topic;
end;
$$;

create function public.disable_push()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  delete from public.push_subscriptions ps where ps.user_id = v_uid;
end;
$$;

-- Keep-alive ------------------------------------------------------------------------------------------

create function public.ping()
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select 'pong'::text;
$$;

-- Privileges ------------------------------------------------------------------------------------------

revoke all on function public.delete_my_account() from public, anon;
revoke all on function public.enable_push() from public, anon;
revoke all on function public.disable_push() from public, anon;
revoke all on function public.ping() from public;

grant execute on function public.delete_my_account() to authenticated;
grant execute on function public.enable_push() to authenticated;
grant execute on function public.disable_push() to authenticated;
grant execute on function public.ping() to anon, authenticated;

-- Catch-all: private functions are never executable by PUBLIC/anon (RLS helpers keep their explicit
-- `authenticated` grant from the helpers migration).
revoke all on all functions in schema private from public, anon;

-- Realtime publication (change signals only) ------------------------------------------------------------
-- INSERT and UPDATE only: Realtime cannot apply RLS to DELETE (or TRUNCATE) events, so publishing them would
-- send the primary keys of other groups' rows to any authenticated subscriber. Clients never consume them.
-- (`set table` keeps the publish list, which defaults to every action: set it explicitly.)

do $$
begin
  if exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime set table public.groups, public.profiles, public.task_assignees;
  else
    create publication supabase_realtime for table public.groups, public.profiles, public.task_assignees;
  end if;
  alter publication supabase_realtime set (publish = 'insert, update');
end;
$$;
