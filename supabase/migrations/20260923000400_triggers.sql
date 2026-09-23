-- Équipe — triggers: profile creation, normalization/validation, server-maintained fields,
-- realtime change signals and the "group always keeps an admin" safety net.
-- All trigger functions are `security definer` (they must reach `private` and bypass RLS) and are
-- not executable by API roles (triggers do not check EXECUTE when they fire).

-- Profile creation ---------------------------------------------------------------------------------
-- Runs inside GoTrue's sign-up transaction: it must NEVER fail.
-- display_name = trimmed `raw_user_meta_data.display_name` (max 50 chars), else the e-mail local part,
-- else 'Utilisateur'.

create function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  begin
    v_name := private.clean_text(left(private.clean_text(new.raw_user_meta_data ->> 'display_name'), 50));
    if v_name is null or v_name = '' then
      v_name := private.clean_text(left(private.clean_text(split_part(new.email, '@', 1)), 50));
    end if;
  exception when others then
    v_name := null;
  end;

  if v_name is null or v_name = '' then
    v_name := 'Utilisateur';
  end if;

  begin
    insert into public.profiles (id, display_name)
    values (new.id, v_name)
    on conflict (id) do nothing;
  exception when others then
    begin
      insert into public.profiles (id, display_name)
      values (new.id, 'Utilisateur')
      on conflict (id) do nothing;
    exception when others then
      raise warning 'handle_new_user: no profile created for user % (%)', new.id, sqlerrm;
    end;
  end;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- Profiles -----------------------------------------------------------------------------------------

create function private.profiles_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.display_name := private.clean_text(new.display_name);
  if new.display_name is null or char_length(new.display_name) not between 1 and 50 then
    raise exception using errcode = 'P0001', message = 'invalid_display_name';
  end if;

  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.created_at is distinct from old.created_at then
      raise exception using errcode = '42501', message = 'immutable_field';
    end if;
    if new.display_name is distinct from old.display_name then
      new.updated_at := now();
    elsif auth.uid() is not null then
      new.updated_at := old.updated_at;
    end if;
  end if;

  return new;
end;
$$;

create trigger profiles_before_write
  before insert or update on public.profiles
  for each row execute function private.profiles_before_write();

-- Groups -------------------------------------------------------------------------------------------

create function private.groups_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.name := private.clean_text(new.name);
  if new.name is null or char_length(new.name) not between 1 and 60 then
    raise exception using errcode = 'P0001', message = 'invalid_name';
  end if;

  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.created_at is distinct from old.created_at then
      raise exception using errcode = '42501', message = 'immutable_field';
    end if;
    -- created_by may only become NULL (ON DELETE SET NULL of the creator's profile).
    if new.created_by is distinct from old.created_by and new.created_by is not null then
      raise exception using errcode = '42501', message = 'immutable_field';
    end if;
  end if;

  return new;
end;
$$;

create trigger groups_before_write
  before insert or update on public.groups
  for each row execute function private.groups_before_write();

-- Tasks: validation and server-maintained fields ----------------------------------------------------

-- Shared validation of the editable text fields (title trimmed 1–200, details trimmed ≤ 5000, '' → NULL).
create function private.normalize_task_fields(inout p_title text, inout p_details text)
language plpgsql
immutable
set search_path = ''
as $$
begin
  p_title := private.clean_text(p_title);
  if p_title is null or char_length(p_title) not between 1 and 200 then
    raise exception using errcode = 'P0001', message = 'invalid_title';
  end if;

  p_details := nullif(private.clean_text(p_details), '');
  if p_details is not null and char_length(p_details) > 5000 then
    raise exception using errcode = 'P0001', message = 'invalid_details';
  end if;
end;
$$;

-- Due date: NULL or within [1970-01-01, 10000-01-01) UTC, which excludes ±infinity and BC dates
-- (business error in front of the tasks_due_at_range check constraint). Validated after title/details.
create function private.check_due_at(p_due_at timestamptz)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_due_at < '1970-01-01 00:00:00+00' or p_due_at >= '10000-01-01 00:00:00+00' then
    raise exception using errcode = 'P0001', message = 'invalid_due_at';
  end if;
end;
$$;

create function private.tasks_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  select n.p_title, n.p_details
  into new.title, new.details
  from private.normalize_task_fields(new.title, new.details) n;
  perform private.check_due_at(new.due_at);

  if v_uid is not null then
    -- Server-maintained fields cannot be chosen by an end user.
    new.created_by := v_uid;
    new.created_at := now();
    new.updated_at := now();
    new.completed_at := case when new.status = 'done' then now() end;
  else
    -- Trusted context (migrations, seed, service tasks): keep explicit values, fill the gaps.
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := coalesce(new.updated_at, new.created_at);
    new.completed_at := case when new.status = 'done' then coalesce(new.completed_at, now()) end;
  end if;

  return new;
end;
$$;

create trigger tasks_before_insert
  before insert on public.tasks
  for each row execute function private.tasks_before_insert();

-- Non-editors (assignees) may only change `status` (42501 `forbidden_fields`); `created_by` is immutable
-- except to NULL (ON DELETE SET NULL); `completed_at` follows `status`; `updated_at` is maintained.
create function private.tasks_before_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_is_editor boolean;
begin
  if new.id is distinct from old.id
     or new.group_id is distinct from old.group_id
     or new.created_at is distinct from old.created_at then
    raise exception using errcode = '42501', message = 'immutable_field';
  end if;
  if new.created_by is distinct from old.created_by and new.created_by is not null then
    raise exception using errcode = '42501', message = 'immutable_field';
  end if;

  select n.p_title, n.p_details
  into new.title, new.details
  from private.normalize_task_fields(new.title, new.details) n;
  perform private.check_due_at(new.due_at);

  if v_uid is not null
     and (new.title, new.details, new.priority, new.due_at)
         is distinct from (old.title, old.details, old.priority, old.due_at) then
    v_is_editor := exists (
      select 1
      from public.group_members gm
      where gm.group_id = old.group_id
        and gm.user_id = v_uid
        and (gm.role = 'admin' or old.created_by = v_uid)
    );
    if not v_is_editor then
      raise exception using errcode = '42501', message = 'forbidden_fields';
    end if;
  end if;

  if new.status = 'done' then
    if v_uid is null and new.completed_at is not null and new.completed_at is distinct from old.completed_at then
      null; -- trusted context explicitly sets the completion date
    elsif old.status = 'done' then
      new.completed_at := old.completed_at;
    else
      new.completed_at := now();
    end if;
  else
    new.completed_at := null;
  end if;

  if (new.title, new.details, new.status, new.priority, new.due_at)
     is distinct from (old.title, old.details, old.status, old.priority, old.due_at) then
    new.updated_at := now();
  elsif v_uid is not null then
    new.updated_at := old.updated_at;
  end if;

  return new;
end;
$$;

create trigger tasks_before_update
  before update on public.tasks
  for each row execute function private.tasks_before_update();

-- Realtime change signals (docs/CONTRACTS.md §6) ------------------------------------------------------
-- `now()` is the transaction start time, so the `< now()` guard bumps each row at most once per
-- transaction (one Realtime UPDATE event). Updating a row deleted by a cascade simply matches nothing.

create function private.bump_group_activity(p_group_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.groups
  set last_activity_at = now()
  where id = p_group_id
    and last_activity_at < now();
$$;

create function private.bump_memberships_changed(p_user_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.profiles
  set memberships_changed_at = now()
  where id = p_user_id
    and memberships_changed_at < now();
$$;

-- AFTER trigger for `tasks` and `task_assignees`: bumps the group's `last_activity_at`.
create function private.on_group_content_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform private.bump_group_activity(new.group_id);
  elsif tg_op = 'DELETE' then
    perform private.bump_group_activity(old.group_id);
  else
    perform private.bump_group_activity(new.group_id);
    if new.group_id is distinct from old.group_id then
      perform private.bump_group_activity(old.group_id);
    end if;
  end if;
  return null;
end;
$$;

create trigger tasks_after_change_signal
  after insert or update or delete on public.tasks
  for each row execute function private.on_group_content_change();

create trigger task_assignees_after_change_signal
  after insert or update or delete on public.task_assignees
  for each row execute function private.on_group_content_change();

-- AFTER trigger for `group_members`: bumps the group's `last_activity_at` and the member's
-- `profiles.memberships_changed_at`.
create function private.on_membership_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform private.bump_group_activity(new.group_id);
    perform private.bump_memberships_changed(new.user_id);
  elsif tg_op = 'DELETE' then
    perform private.bump_group_activity(old.group_id);
    perform private.bump_memberships_changed(old.user_id);
  else
    perform private.bump_group_activity(new.group_id);
    perform private.bump_memberships_changed(new.user_id);
    if new.group_id is distinct from old.group_id then
      perform private.bump_group_activity(old.group_id);
    end if;
    if new.user_id is distinct from old.user_id then
      perform private.bump_memberships_changed(old.user_id);
    end if;
  end if;
  return null;
end;
$$;

create trigger group_members_after_change_signal
  after insert or update or delete on public.group_members
  for each row execute function private.on_membership_change();

-- Safety net: after a membership deletion, a group that still has members but no admin gets its
-- oldest member (joined_at, then user_id) promoted. No-op when the group itself is being deleted.
create function private.heal_group_admins()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_next uuid;
begin
  if not exists (select 1 from public.groups g where g.id = old.group_id) then
    return null;
  end if;
  if exists (
    select 1 from public.group_members gm where gm.group_id = old.group_id and gm.role = 'admin'
  ) then
    return null;
  end if;

  select gm.user_id into v_next
  from public.group_members gm
  where gm.group_id = old.group_id
  order by gm.joined_at, gm.user_id
  limit 1;

  if v_next is not null then
    update public.group_members
    set role = 'admin'
    where group_id = old.group_id
      and user_id = v_next;
  end if;
  return null;
end;
$$;

create trigger group_members_after_delete_heal
  after delete on public.group_members
  for each row execute function private.heal_group_admins();

revoke all on all functions in schema private from public, anon;
revoke execute on function private.handle_new_user() from authenticated;
revoke execute on function private.profiles_before_write() from authenticated;
revoke execute on function private.groups_before_write() from authenticated;
revoke execute on function private.normalize_task_fields(text, text) from authenticated;
revoke execute on function private.check_due_at(timestamptz) from authenticated;
revoke execute on function private.tasks_before_insert() from authenticated;
revoke execute on function private.tasks_before_update() from authenticated;
revoke execute on function private.bump_group_activity(uuid) from authenticated;
revoke execute on function private.bump_memberships_changed(uuid) from authenticated;
revoke execute on function private.on_group_content_change() from authenticated;
revoke execute on function private.on_membership_change() from authenticated;
revoke execute on function private.heal_group_admins() from authenticated;
