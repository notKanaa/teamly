-- Équipe — task RPCs (docs/CONTRACTS.md §2, §4.1).
-- `create_task`, `update_task`, `set_task_status` and `delete_task` run as the caller (security invoker):
-- RLS, column grants and the BEFORE UPDATE trigger apply. Assignees are written by the definer RPC
-- `set_task_assignees`, which enforces the same permission rules itself.
-- `task_not_found` = the task does not exist or is not visible to the caller; `forbidden` = visible but
-- not allowed.

-- set_task_assignees ------------------------------------------------------------------------------------
-- Admin or creator (still member). Replaces the assignee set: rows of users still listed are kept with
-- their assigned_at / assigned_by; new rows get assigned_by = caller.
create function public.set_task_assignees(p_task_id uuid, p_user_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_task public.tasks;
  v_ids uuid[];
begin
  select * into v_task from public.tasks t where t.id = p_task_id;
  if not found or not private.is_group_member(v_task.group_id) then
    raise exception using errcode = 'P0001', message = 'task_not_found';
  end if;
  if not (private.is_group_admin(v_task.group_id) or v_task.created_by = v_uid) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  -- Serializes concurrent edits of the same task's assignees.
  perform 1 from public.tasks t where t.id = p_task_id for update;

  select coalesce(array_agg(distinct u.id), '{}')
  into v_ids
  from unnest(coalesce(p_user_ids, '{}'::uuid[])) as u (id)
  where u.id is not null;

  if cardinality(v_ids) > 20 then
    raise exception using errcode = 'P0001', message = 'too_many_assignees';
  end if;

  if exists (
    select 1
    from unnest(v_ids) as u (id)
    where not exists (
      select 1
      from public.group_members gm
      where gm.group_id = v_task.group_id
        and gm.user_id = u.id
    )
  ) then
    raise exception using errcode = 'P0001', message = 'assignee_not_member';
  end if;

  delete from public.task_assignees ta
  where ta.task_id = p_task_id
    and ta.user_id <> all (v_ids);

  insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
  select p_task_id, v_task.group_id, u.id, v_uid
  from unnest(v_ids) as u (id)
  on conflict (task_id, user_id) do nothing;
end;
$$;

-- create_task -----------------------------------------------------------------------------------------
create function public.create_task(
  p_group_id uuid,
  p_title text,
  p_details text default null,
  p_priority public.task_priority default 'medium',
  p_due_at timestamptz default null,
  p_assignee_ids uuid[] default '{}'
)
returns public.tasks
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_task public.tasks;
begin
  if v_uid is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  if not exists (
    select 1
    from public.group_members gm
    where gm.group_id = p_group_id
      and gm.user_id = v_uid
  ) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  -- Title/details are normalized and validated by the tasks_before_insert trigger.
  insert into public.tasks (group_id, title, details, priority, due_at)
  values (p_group_id, p_title, p_details, coalesce(p_priority, 'medium'), p_due_at)
  returning * into v_task;

  if cardinality(coalesce(p_assignee_ids, '{}'::uuid[])) > 0 then
    perform public.set_task_assignees(v_task.id, p_assignee_ids);
  end if;

  return v_task;
end;
$$;

-- update_task -----------------------------------------------------------------------------------------
-- Full edit, atomic. NULL p_due_at clears the due date; NULL p_assignee_ids leaves the assignees as is.
create function public.update_task(
  p_task_id uuid,
  p_title text,
  p_details text,
  p_priority public.task_priority,
  p_due_at timestamptz,
  p_assignee_ids uuid[]
)
returns public.tasks
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_task public.tasks;
begin
  if v_uid is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  select * into v_task from public.tasks t where t.id = p_task_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'task_not_found';
  end if;

  if not (
    v_task.created_by = v_uid
    or exists (
      select 1
      from public.group_members gm
      where gm.group_id = v_task.group_id
        and gm.user_id = v_uid
        and gm.role = 'admin'
    )
  ) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  update public.tasks t
  set title = p_title,
      details = p_details,
      priority = coalesce(p_priority, t.priority),
      due_at = p_due_at
  where t.id = p_task_id;
  if not found then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  if p_assignee_ids is not null then
    perform public.set_task_assignees(p_task_id, p_assignee_ids);
  end if;

  select * into v_task from public.tasks t where t.id = p_task_id;
  return v_task;
end;
$$;

-- set_task_status -------------------------------------------------------------------------------------
-- Admin, creator (still member) or assignee (RLS UPDATE policy); completed_at maintained by trigger.
create function public.set_task_status(p_task_id uuid, p_status public.task_status)
returns public.tasks
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_task public.tasks;
begin
  if auth.uid() is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  update public.tasks t
  set status = p_status
  where t.id = p_task_id
  returning * into v_task;

  if found then
    return v_task;
  end if;

  -- 0 rows: RLS hid the row (pitfall 3). Distinguish "not visible" from "not allowed".
  if exists (select 1 from public.tasks t where t.id = p_task_id) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;
  raise exception using errcode = 'P0001', message = 'task_not_found';
end;
$$;

-- delete_task -----------------------------------------------------------------------------------------
-- Admin or creator (still member), through the RLS DELETE policy.
create function public.delete_task(p_task_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;

  delete from public.tasks t where t.id = p_task_id;
  if found then
    return;
  end if;

  if exists (select 1 from public.tasks t where t.id = p_task_id) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;
  raise exception using errcode = 'P0001', message = 'task_not_found';
end;
$$;

-- Privileges ------------------------------------------------------------------------------------------

revoke all on function public.set_task_assignees(uuid, uuid[]) from public, anon;
revoke all on function public.create_task(uuid, text, text, public.task_priority, timestamptz, uuid[]) from public, anon;
revoke all on function public.update_task(uuid, text, text, public.task_priority, timestamptz, uuid[]) from public, anon;
revoke all on function public.set_task_status(uuid, public.task_status) from public, anon;
revoke all on function public.delete_task(uuid) from public, anon;

grant execute on function public.set_task_assignees(uuid, uuid[]) to authenticated;
grant execute on function public.create_task(uuid, text, text, public.task_priority, timestamptz, uuid[]) to authenticated;
grant execute on function public.update_task(uuid, text, text, public.task_priority, timestamptz, uuid[]) to authenticated;
grant execute on function public.set_task_status(uuid, public.task_status) to authenticated;
grant execute on function public.delete_task(uuid) to authenticated;
