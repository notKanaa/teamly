-- Équipe v2 — RPCs (docs/CONTRACTS-V2.md §5).
-- v1 RPCs keep working with their v1 arguments (§0): a function whose signature grows is dropped and recreated with
-- the new parameters appended with defaults (never overloaded: PostgREST rejects ambiguous overloads, PGRST203),
-- then granted again. Business errors: P0001 with the error code as message. Permission errors: 42501 `forbidden`.

-- create_group -----------------------------------------------------------------------------------------------------
-- v1 + appearance: color and emoji are validated by groups_before_write (name → color → emoji), before the quota.

drop function public.create_group(text);

create function public.create_group(p_name text, p_color text default null, p_emoji text default null)
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

  insert into public.groups (name, created_by, color, emoji)
  values (v_name, v_uid, p_color, p_emoji)
  returning * into v_group;

  insert into public.group_members (group_id, user_id, role)
  values (v_group.id, v_uid, 'admin');

  insert into public.group_invites (group_id, code, created_by)
  values (v_group.id, private.generate_invite_code(), v_uid);

  select * into v_group from public.groups g where g.id = v_group.id;
  return v_group;
end;
$$;

-- set_group_appearance ------------------------------------------------------------------------------------------------
-- Admin only. NULL = automatic color / no emoji. Also bumps last_activity_at (one Realtime UPDATE, like rename_group).
-- Order: group_not_found → forbidden → invalid_color → invalid_emoji.
create function public.set_group_appearance(p_group_id uuid, p_color text, p_emoji text)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group public.groups;
begin
  perform private.require_uid();

  if not exists (select 1 from public.groups g where g.id = p_group_id) then
    raise exception using errcode = 'P0001', message = 'group_not_found';
  end if;
  if not private.is_group_admin(p_group_id) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  update public.groups
  set color = p_color,
      emoji = p_emoji,
      last_activity_at = now()
  where id = p_group_id
  returning * into v_group;

  return v_group;
end;
$$;

-- complete_onboarding ------------------------------------------------------------------------------------------------
-- onboarded_at = coalesce(onboarded_at, now()) for the caller: no write when already set.
create function public.complete_onboarding()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  update public.profiles p
  set onboarded_at = now()
  where p.id = v_uid
    and p.onboarded_at is null;
end;
$$;

-- set_task_assignees ---------------------------------------------------------------------------------------------------
-- v1 + v2: refuses a rotating task (`invalid_rotation`, after the permission check): its assignee is the turn holder.
create or replace function public.set_task_assignees(p_task_id uuid, p_user_ids uuid[])
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
  select * into v_task from public.tasks t where t.id = p_task_id for update;

  if v_task.rotation is not null then
    raise exception using errcode = 'P0001', message = 'invalid_rotation';
  end if;

  v_ids := private.clean_assignee_ids(v_task.group_id, p_user_ids);

  delete from public.task_assignees ta
  where ta.task_id = p_task_id
    and ta.user_id <> all (v_ids);

  insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
  select p_task_id, v_task.group_id, u.id, v_uid
  from unnest(v_ids) as u (id)
  on conflict (task_id, user_id) do nothing;
end;
$$;

-- create_task --------------------------------------------------------------------------------------------------------
-- v1 + recurrence, rotation and checklist. Still security invoker (RLS, column grants and the task triggers apply):
-- the v2 arguments go to the definer triggers through the transaction-local draft (private.task_draft), which
-- validate them in the contract order — permission → title → details → due date → recurrence (shape, then due
-- date) → rotation → assignees count → assignees membership → checklist items (each title, then count) — before
-- the write quota, and write the rotation's first turn and the checklist. With a rotation, p_assignee_ids is
-- ignored: the assignee is rotation[1], assigned by the creator.
drop function public.create_task(uuid, text, text, public.task_priority, timestamptz, uuid[]);

create function public.create_task(
  p_group_id uuid,
  p_title text,
  p_details text default null,
  p_priority public.task_priority default 'medium',
  p_due_at timestamptz default null,
  p_assignee_ids uuid[] default '{}',
  p_recurrence jsonb default null,
  p_rotation uuid[] default null,
  p_checklist text[] default null
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
  -- Same rule as private.require_uid() (a deleted account's JWT is not authenticated).
  if v_uid is null or not exists (select 1 from public.profiles p where p.id = v_uid) then
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

  perform set_config('equipe.task_draft', jsonb_build_object(
    'op', 'create',
    'group_id', p_group_id,
    'recurrence', p_recurrence,
    'rotation', to_jsonb(p_rotation),
    'assignee_ids', to_jsonb(p_assignee_ids),
    'checklist', to_jsonb(p_checklist)
  )::text, true);

  -- Title/details/due date and the v2 arguments are normalized and validated by the tasks triggers.
  insert into public.tasks (group_id, title, details, priority, due_at)
  values (p_group_id, p_title, p_details, coalesce(p_priority, 'medium'), p_due_at)
  returning * into v_task;

  perform set_config('equipe.task_draft', '', true);

  if v_task.rotation is null and cardinality(coalesce(p_assignee_ids, '{}'::uuid[])) > 0 then
    perform public.set_task_assignees(v_task.id, p_assignee_ids);
  end if;

  return v_task;
end;
$$;

-- update_task --------------------------------------------------------------------------------------------------------
-- v1 + recurrence and rotation (security invoker, v2 arguments through the draft like create_task).
-- p_recurrence: NULL = unchanged, '{}' = no recurrence (also clears the rotation), else a rule.
-- p_rotation: NULL = unchanged, '{}' = no rotation, else 2–20 distinct members; the stored list sent back as is also
-- counts as unchanged. A new rotation keeps the current turn holder when still listed, else rotation[1], who becomes
-- the only assignee. While the task has a rotation, p_assignee_ids is ignored.
-- A v1 call (no v2 argument) keeps the recurrence, the rotation and the checklist.
drop function public.update_task(uuid, text, text, public.task_priority, timestamptz, uuid[]);

create function public.update_task(
  p_task_id uuid,
  p_title text,
  p_details text,
  p_priority public.task_priority,
  p_due_at timestamptz,
  p_assignee_ids uuid[],
  p_recurrence jsonb default null,
  p_rotation uuid[] default null
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
  if v_uid is null or not exists (select 1 from public.profiles p where p.id = v_uid) then
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

  perform set_config('equipe.task_draft', jsonb_build_object(
    'op', 'update',
    'task_id', p_task_id,
    'recurrence', p_recurrence,
    'rotation', to_jsonb(p_rotation)
  )::text, true);

  update public.tasks t
  set title = p_title,
      details = p_details,
      priority = coalesce(p_priority, t.priority),
      due_at = p_due_at
  where t.id = p_task_id;
  if not found then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  perform set_config('equipe.task_draft', '', true);

  select * into v_task from public.tasks t where t.id = p_task_id;
  if p_assignee_ids is not null and v_task.rotation is null then
    perform public.set_task_assignees(p_task_id, p_assignee_ids);
  end if;

  select * into v_task from public.tasks t where t.id = p_task_id;
  return v_task;
end;
$$;

-- Checklist RPCs -------------------------------------------------------------------------------------------------------
-- Same rights as « change status »: admin, creator (still member) or assignee of the task. item_not_found /
-- task_not_found = missing or not visible (non-member). Writes bump the group (AFTER trigger); no write quota.

-- position = max + 1. Order: task_not_found → forbidden → invalid_item_title → too_many_items.
create function public.add_checklist_item(p_task_id uuid, p_title text)
returns public.task_checklist_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.tasks;
  v_title text;
  v_item public.task_checklist_items;
begin
  perform private.require_uid();

  select * into v_task from public.tasks t where t.id = p_task_id;
  if not found or not private.is_group_member(v_task.group_id) then
    raise exception using errcode = 'P0001', message = 'task_not_found';
  end if;
  if not private.can_change_task_status(v_task.id, v_task.group_id, v_task.created_by) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;
  v_title := private.normalize_item_title(p_title);

  -- Serializes the additions to this task (count and position).
  perform 1 from public.tasks t where t.id = p_task_id for update;

  if (select count(*) from public.task_checklist_items i where i.task_id = p_task_id) >= 30 then
    raise exception using errcode = 'P0001', message = 'too_many_items';
  end if;

  insert into public.task_checklist_items (task_id, group_id, title, position)
  values (
    p_task_id,
    v_task.group_id,
    v_title,
    coalesce((select max(i.position) from public.task_checklist_items i where i.task_id = p_task_id), 0) + 1
  )
  returning * into v_item;

  return v_item;
end;
$$;

-- Order: item_not_found → forbidden → invalid_item_title. Always writes the row (like update_task).
create function public.rename_checklist_item(p_item_id uuid, p_title text)
returns public.task_checklist_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.task_checklist_items;
  v_task public.tasks;
  v_title text;
begin
  perform private.require_uid();

  select * into v_item from public.task_checklist_items i where i.id = p_item_id;
  if not found or not private.is_group_member(v_item.group_id) then
    raise exception using errcode = 'P0001', message = 'item_not_found';
  end if;
  select * into v_task from public.tasks t where t.id = v_item.task_id;
  if not private.can_change_task_status(v_task.id, v_task.group_id, v_task.created_by) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;
  v_title := private.normalize_item_title(p_title);

  update public.task_checklist_items i
  set title = v_title
  where i.id = p_item_id
  returning * into v_item;

  return v_item;
end;
$$;

-- Sets or clears done_at / done_by (trigger). The same value is a no-op (no write, no signal).
-- Order: item_not_found → forbidden → invalid_input (NULL p_done, 23502).
create function public.set_checklist_item_done(p_item_id uuid, p_done boolean)
returns public.task_checklist_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.task_checklist_items;
  v_task public.tasks;
begin
  perform private.require_uid();

  select * into v_item from public.task_checklist_items i where i.id = p_item_id;
  if not found or not private.is_group_member(v_item.group_id) then
    raise exception using errcode = 'P0001', message = 'item_not_found';
  end if;
  select * into v_task from public.tasks t where t.id = v_item.task_id;
  if not private.can_change_task_status(v_task.id, v_task.group_id, v_task.created_by) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;
  if p_done is null then
    raise exception using errcode = '23502', message = 'invalid_input';
  end if;

  if v_item.done = p_done then
    return v_item;
  end if;

  update public.task_checklist_items i
  set done = p_done
  where i.id = p_item_id
  returning * into v_item;

  return v_item;
end;
$$;

-- The positions of the other items are kept (gaps allowed). Order: item_not_found → forbidden.
create function public.delete_checklist_item(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.task_checklist_items;
  v_task public.tasks;
begin
  perform private.require_uid();

  select * into v_item from public.task_checklist_items i where i.id = p_item_id;
  if not found or not private.is_group_member(v_item.group_id) then
    raise exception using errcode = 'P0001', message = 'item_not_found';
  end if;
  select * into v_task from public.tasks t where t.id = v_item.task_id;
  if not private.can_change_task_status(v_task.id, v_task.group_id, v_task.created_by) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  delete from public.task_checklist_items i where i.id = p_item_id;
end;
$$;

-- Privileges -----------------------------------------------------------------------------------------------------------

revoke all on function public.create_group(text, text, text) from public, anon;
revoke all on function public.set_group_appearance(uuid, text, text) from public, anon;
revoke all on function public.complete_onboarding() from public, anon;
revoke all on function public.create_task(uuid, text, text, public.task_priority, timestamptz, uuid[], jsonb, uuid[], text[])
  from public, anon;
revoke all on function public.update_task(uuid, text, text, public.task_priority, timestamptz, uuid[], jsonb, uuid[])
  from public, anon;
revoke all on function public.add_checklist_item(uuid, text) from public, anon;
revoke all on function public.rename_checklist_item(uuid, text) from public, anon;
revoke all on function public.set_checklist_item_done(uuid, boolean) from public, anon;
revoke all on function public.delete_checklist_item(uuid) from public, anon;

grant execute on function public.create_group(text, text, text) to authenticated;
grant execute on function public.set_group_appearance(uuid, text, text) to authenticated;
grant execute on function public.complete_onboarding() to authenticated;
grant execute on function public.create_task(uuid, text, text, public.task_priority, timestamptz, uuid[], jsonb, uuid[], text[])
  to authenticated;
grant execute on function public.update_task(uuid, text, text, public.task_priority, timestamptz, uuid[], jsonb, uuid[])
  to authenticated;
grant execute on function public.add_checklist_item(uuid, text) to authenticated;
grant execute on function public.rename_checklist_item(uuid, text) to authenticated;
grant execute on function public.set_checklist_item_done(uuid, boolean) to authenticated;
grant execute on function public.delete_checklist_item(uuid) to authenticated;
