-- Équipe — group and membership RPCs (docs/CONTRACTS.md §2, §4.1).
-- Business errors: P0001 with the error code as message. Permission errors: 42501 `forbidden`.

-- create_group --------------------------------------------------------------------------------------
-- Must be an RPC: INSERT … RETURNING on `groups` would be checked against the SELECT policy before the
-- creator's membership exists.
create function public.create_group(p_name text)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_name text := private.clean_text(p_name);
  v_group public.groups;
begin
  if v_name is null or char_length(v_name) not between 1 and 60 then
    raise exception using errcode = 'P0001', message = 'invalid_name';
  end if;

  insert into public.groups (name, created_by)
  values (v_name, v_uid)
  returning * into v_group;

  insert into public.group_members (group_id, user_id, role)
  values (v_group.id, v_uid, 'admin');

  insert into public.group_invites (group_id, code, created_by)
  values (v_group.id, private.generate_invite_code(), v_uid);

  select * into v_group from public.groups g where g.id = v_group.id;
  return v_group;
end;
$$;

-- join_group_by_code ----------------------------------------------------------------------------------
-- Normalizes the code (uppercase, drop every non-[A-Z0-9] char), logs the attempt and returns
-- {status, group_id, group_name}; status ∈ joined | already_member | invalid_code.
-- An invalid code is RETURNED (not raised) so that the attempt log survives. After 10 failed attempts
-- within the last hour, further attempts raise `rate_limited`.
create function public.join_group_by_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_code text := regexp_replace(upper(coalesce(p_code, '')), '[^A-Z0-9]', '', 'g');
  v_failures integer;
  v_group_id uuid;
  v_group_name text;
begin
  -- Serializes the attempts of one user so that concurrent calls cannot bypass the limit.
  perform pg_advisory_xact_lock(hashtextextended('join_group_by_code:' || v_uid::text, 0));

  -- Attempts older than the rate-limit window are useless: forget them.
  delete from private.join_attempts ja
  where ja.user_id = v_uid
    and ja.attempted_at < now() - interval '1 hour';

  select count(*) into v_failures
  from private.join_attempts ja
  where ja.user_id = v_uid
    and not ja.succeeded
    and ja.attempted_at >= now() - interval '1 hour';

  if v_failures >= 10 then
    raise exception using errcode = 'P0001', message = 'rate_limited';
  end if;

  if v_code ~ '^[A-HJ-NP-Z2-9]{8}$' then
    select g.id, g.name into v_group_id, v_group_name
    from public.group_invites gi
    join public.groups g on g.id = gi.group_id
    where gi.code = v_code;
  end if;

  insert into private.join_attempts (user_id, succeeded)
  values (v_uid, v_group_id is not null);

  if v_group_id is null then
    return jsonb_build_object('status', 'invalid_code', 'group_id', null, 'group_name', null);
  end if;

  insert into public.group_members (group_id, user_id, role)
  values (v_group_id, v_uid, 'member')
  on conflict (group_id, user_id) do nothing;

  return jsonb_build_object(
    'status', case when found then 'joined' else 'already_member' end,
    'group_id', v_group_id,
    'group_name', v_group_name
  );
end;
$$;

-- regenerate_invite_code --------------------------------------------------------------------------------
create function public.regenerate_invite_code(p_group_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_code text;
begin
  if not private.is_group_admin(p_group_id) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  v_code := private.generate_invite_code();

  insert into public.group_invites (group_id, code, created_by)
  values (p_group_id, v_code, v_uid)
  on conflict (group_id) do update
    set code = excluded.code,
        created_by = excluded.created_by,
        created_at = now();

  return v_code;
end;
$$;

-- rename_group ----------------------------------------------------------------------------------------
create function public.rename_group(p_group_id uuid, p_name text)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := private.clean_text(p_name);
  v_group public.groups;
begin
  perform private.require_uid();

  if not exists (select 1 from public.groups g where g.id = p_group_id) then
    raise exception using errcode = 'P0001', message = 'group_not_found';
  end if;
  if not private.is_group_admin(p_group_id) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;
  if v_name is null or char_length(v_name) not between 1 and 60 then
    raise exception using errcode = 'P0001', message = 'invalid_name';
  end if;

  update public.groups
  set name = v_name,
      last_activity_at = now()
  where id = p_group_id
  returning * into v_group;

  return v_group;
end;
$$;

-- delete_group ----------------------------------------------------------------------------------------
create function public.delete_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_uid();

  if not exists (select 1 from public.groups g where g.id = p_group_id) then
    raise exception using errcode = 'P0001', message = 'group_not_found';
  end if;
  if not private.is_group_admin(p_group_id) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  delete from public.groups g where g.id = p_group_id;
end;
$$;

-- set_member_role -------------------------------------------------------------------------------------
create function public.set_member_role(p_group_id uuid, p_user_id uuid, p_role public.member_role)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current public.member_role;
  v_admins integer;
begin
  perform private.require_uid();

  -- Serializes membership changes of this group.
  perform 1 from public.groups g where g.id = p_group_id for update;

  if not private.is_group_admin(p_group_id) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;
  if p_role is null then
    raise exception using errcode = '23502', message = 'invalid_input';
  end if;

  select gm.role into v_current
  from public.group_members gm
  where gm.group_id = p_group_id
    and gm.user_id = p_user_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'not_member';
  end if;

  if v_current = p_role then
    return;
  end if;

  if v_current = 'admin' then
    select count(*) into v_admins
    from public.group_members gm
    where gm.group_id = p_group_id
      and gm.role = 'admin';
    if v_admins <= 1 then
      raise exception using errcode = 'P0001', message = 'last_admin';
    end if;
  end if;

  update public.group_members
  set role = p_role
  where group_id = p_group_id
    and user_id = p_user_id;
end;
$$;

-- remove_member ---------------------------------------------------------------------------------------
-- Deleting the membership cascades to the user's assignments in the group; their tasks stay.
create function public.remove_member(p_group_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  perform 1 from public.groups g where g.id = p_group_id for update;

  if not private.is_group_admin(p_group_id) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;
  if p_user_id = v_uid then
    raise exception using errcode = 'P0001', message = 'cannot_remove_self';
  end if;

  delete from public.group_members gm
  where gm.group_id = p_group_id
    and gm.user_id = p_user_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'not_member';
  end if;
end;
$$;

-- leave_group -----------------------------------------------------------------------------------------
-- The only admin cannot leave while other members remain (`last_admin`); the last member leaving
-- deletes the group.
create function public.leave_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_role public.member_role;
  v_members integer;
  v_admins integer;
begin
  perform 1 from public.groups g where g.id = p_group_id for update;

  select gm.role into v_role
  from public.group_members gm
  where gm.group_id = p_group_id
    and gm.user_id = v_uid;
  if not found then
    raise exception using errcode = 'P0001', message = 'not_member';
  end if;

  select count(*), count(*) filter (where gm.role = 'admin')
  into v_members, v_admins
  from public.group_members gm
  where gm.group_id = p_group_id;

  if v_members = 1 then
    delete from public.groups g where g.id = p_group_id;
    return;
  end if;

  if v_role = 'admin' and v_admins = 1 then
    raise exception using errcode = 'P0001', message = 'last_admin';
  end if;

  delete from public.group_members gm
  where gm.group_id = p_group_id
    and gm.user_id = v_uid;
end;
$$;

-- Privileges ------------------------------------------------------------------------------------------

revoke all on function public.create_group(text) from public, anon;
revoke all on function public.join_group_by_code(text) from public, anon;
revoke all on function public.regenerate_invite_code(uuid) from public, anon;
revoke all on function public.rename_group(uuid, text) from public, anon;
revoke all on function public.delete_group(uuid) from public, anon;
revoke all on function public.set_member_role(uuid, uuid, public.member_role) from public, anon;
revoke all on function public.remove_member(uuid, uuid) from public, anon;
revoke all on function public.leave_group(uuid) from public, anon;

grant execute on function public.create_group(text) to authenticated;
grant execute on function public.join_group_by_code(text) to authenticated;
grant execute on function public.regenerate_invite_code(uuid) to authenticated;
grant execute on function public.rename_group(uuid, text) to authenticated;
grant execute on function public.delete_group(uuid) to authenticated;
grant execute on function public.set_member_role(uuid, uuid, public.member_role) to authenticated;
grant execute on function public.remove_member(uuid, uuid) to authenticated;
grant execute on function public.leave_group(uuid) to authenticated;
