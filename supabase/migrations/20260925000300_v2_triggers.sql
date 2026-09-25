-- Équipe v2 — triggers (docs/CONTRACTS-V2.md): appearance validation, completed_by, recurrence and rotation
-- (including the server-side spawn of the next occurrence), checklist bookkeeping, the activity feed, the write
-- quota exemption of spawns and the ntfy wording of rotation turns.
--
-- The v1 trigger functions are replaced in place (`create or replace`: same triggers, same privileges) with their v1
-- body unchanged plus the v2 additions. New triggers are named to fire after the v1 ones of the same event (BEFORE
-- and AFTER triggers of one event fire in name order):
--   BEFORE INSERT on tasks: tasks_before_insert → tasks_before_insert_v2 → tasks_quota_before_insert
--   BEFORE UPDATE on tasks: tasks_before_update → tasks_before_update_v2
-- All trigger functions are security definer and not executable by API roles.

-- Profiles: avatar color and emoji ------------------------------------------------------------------------------

create or replace function private.profiles_before_write()
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
  -- v2: color before emoji (docs/CONTRACTS-V2.md §3).
  perform private.check_color(new.avatar_color);
  new.avatar_emoji := private.normalize_emoji(new.avatar_emoji);

  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.created_at is distinct from old.created_at then
      raise exception using errcode = '42501', message = 'immutable_field';
    end if;
    if (new.display_name, new.avatar_color, new.avatar_emoji)
       is distinct from (old.display_name, old.avatar_color, old.avatar_emoji) then
      new.updated_at := now();
    elsif auth.uid() is not null then
      new.updated_at := old.updated_at;
    end if;
  end if;

  return new;
end;
$$;

-- Groups: color and emoji ----------------------------------------------------------------------------------------

create or replace function private.groups_before_write()
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
  -- v2: color before emoji (docs/CONTRACTS-V2.md §3).
  perform private.check_color(new.color);
  new.emoji := private.normalize_emoji(new.emoji);

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

-- Tasks: INSERT --------------------------------------------------------------------------------------------------

-- v1 + v2: a spawned occurrence keeps the series creator (created_by is not forced to the user who completed the
-- previous occurrence); completed_by follows the status like completed_at.
create or replace function private.tasks_before_insert()
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

  if v_uid is not null and not private.is_spawning() then
    -- Server-maintained fields cannot be chosen by an end user.
    new.created_by := v_uid;
    new.created_at := now();
    new.updated_at := now();
    new.completed_at := case when new.status = 'done' then now() end;
    new.completed_by := case when new.status = 'done' then v_uid end;
  else
    -- Trusted context (migrations, seed, service tasks) or spawn: keep explicit values, fill the gaps.
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := coalesce(new.updated_at, new.created_at);
    new.completed_at := case when new.status = 'done' then coalesce(new.completed_at, now()) end;
    new.completed_by := case when new.status = 'done' then new.completed_by end;
  end if;

  return new;
end;
$$;

-- create_task (draft `op` = create, docs/CONTRACTS-V2.md §3): validates the v2 arguments in the contract order,
-- after tasks_before_insert (title → details → due date) and before tasks_quota_before_insert: recurrence (shape,
-- then the due-date requirement) → rotation → assignees (count, then membership; ignored with a rotation) →
-- checklist (each title, then the count). Then every insert gets its server-maintained v2 fields. A spawned
-- occurrence is written as is by private.spawn_next_occurrence.
create function private.tasks_before_insert_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft jsonb := private.task_draft();
  v_rule record;
  v_rotation uuid[];
  v_titles text[];
  v_title text;
begin
  if private.is_spawning() then
    return new;
  end if;

  if v_draft ->> 'op' = 'create' and (v_draft ->> 'group_id')::uuid = new.group_id then
    -- Recurrence: NULL or '{}' = none.
    if nullif(v_draft -> 'recurrence', 'null'::jsonb) is not null and v_draft -> 'recurrence' <> '{}'::jsonb then
      select * into v_rule from private.parse_recurrence(v_draft -> 'recurrence');
      new.repeat_freq := v_rule.r_freq;
      new.repeat_interval := v_rule.r_interval;
      new.repeat_weekdays := v_rule.r_weekdays;
      new.repeat_tz := v_rule.r_tz;
      if new.due_at is null then
        raise exception using errcode = 'P0001', message = 'recurrence_requires_due_date';
      end if;
    end if;

    -- Rotation: NULL or '{}' = none. A rotating task is assigned to rotation[1] only (the assignee ids are ignored).
    v_rotation := private.jsonb_uuid_array(v_draft -> 'rotation');
    if cardinality(v_rotation) > 0 then
      if new.repeat_freq is null then
        raise exception using errcode = 'P0001', message = 'invalid_rotation';
      end if;
      perform private.check_rotation(new.group_id, v_rotation);
      new.rotation := v_rotation;
      new.turn_user_id := v_rotation[1];
    else
      perform private.clean_assignee_ids(new.group_id, private.jsonb_uuid_array(v_draft -> 'assignee_ids'));
    end if;

    -- Checklist: every title, then the count.
    v_titles := private.jsonb_text_array(v_draft -> 'checklist');
    if v_titles is not null then
      foreach v_title in array v_titles loop
        perform private.normalize_item_title(v_title);
      end loop;
      if cardinality(v_titles) > 30 then
        raise exception using errcode = 'P0001', message = 'too_many_items';
      end if;
    end if;
  end if;

  -- Server-maintained fields.
  if new.repeat_freq is null then
    new.series_id := null;
    new.repeat_month_day := null;
    new.turn_user_id := null;
  else
    if new.due_at is null then
      raise exception using errcode = 'P0001', message = 'recurrence_requires_due_date';
    end if;
    new.series_id := coalesce(new.series_id, new.id);
    if new.repeat_freq = 'monthly' then
      new.repeat_month_day := coalesce(new.repeat_month_day, extract(day from new.due_at at time zone new.repeat_tz));
    else
      new.repeat_month_day := null;
    end if;
    if new.rotation is null then
      new.turn_user_id := null;
    else
      new.turn_user_id := coalesce(new.turn_user_id, new.rotation[1]);
    end if;
  end if;

  return new;
end;
$$;

create trigger tasks_before_insert_v2
  before insert on public.tasks
  for each row execute function private.tasks_before_insert_v2();

-- v1 + v2: a spawned occurrence is exempt from the task write quota (docs/CONTRACTS-V2.md §6).
create or replace function private.tasks_quota_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.is_spawning() then
    return new;
  end if;
  perform private.enforce_write_quota('task', private.setting_int('quota_tasks_per_hour', 200));
  return new;
end;
$$;

-- task_created (an end user inserts a task, not a spawn); for create_task, the rotation's first turn (assigned by
-- the creator) and the checklist items, positions 1…n. The other assignees of create_task are written by
-- set_task_assignees, as in v1.
create function private.tasks_after_insert_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_draft jsonb;
  v_title text;
  v_position integer := 0;
begin
  if private.is_spawning() then
    return null;
  end if;

  if v_uid is not null then
    perform private.log_activity(new.group_id, 'task_created', new.created_by, null, new.id, new.title, null);
  end if;

  v_draft := private.task_draft();
  if v_draft ->> 'op' = 'create' and (v_draft ->> 'group_id')::uuid = new.group_id then
    if new.turn_user_id is not null then
      insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
      values (new.id, new.group_id, new.turn_user_id, v_uid);
    end if;
    foreach v_title in array coalesce(private.jsonb_text_array(v_draft -> 'checklist'), '{}'::text[]) loop
      v_position := v_position + 1;
      insert into public.task_checklist_items (task_id, group_id, title, position)
      values (new.id, new.group_id, v_title, v_position);
    end loop;
  end if;

  return null;
end;
$$;

create trigger tasks_after_insert_v2
  after insert on public.tasks
  for each row execute function private.tasks_after_insert_v2();

-- Tasks: UPDATE --------------------------------------------------------------------------------------------------

-- v1 + v2: completed_by is the user whose change made the status `done`, kept on done → done (it may still become
-- NULL: ON DELETE SET NULL of the profile), NULL when leaving done. Trusted contexts may set it explicitly.
create or replace function private.tasks_before_update()
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

  if new.status = 'done' then
    if old.status is distinct from 'done' then
      if not (v_uid is null and new.completed_by is distinct from old.completed_by) then
        new.completed_by := v_uid;
      end if;
    elsif new.completed_by is not null and v_uid is not null then
      new.completed_by := old.completed_by;
    end if;
  else
    new.completed_by := null;
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

-- Creates the next occurrence of p_task, a recurring occurrence whose status just became done, and returns its id
-- (docs/CONTRACTS-V2.md §6):
-- - due date: private.next_due_at from the completed occurrence's due date, now() being the completion time;
-- - copied: group, title, details, priority, every repeat_* column (repeat_month_day as is: no drift after a
--   clamped month), created_by (the series creator), series_id; status todo; the checklist, unchecked, same positions;
-- - rotation: the listed users still members, in order; the turn goes to the first member found cyclically after
--   the previous turn holder's position in the original list (the first member when that holder is not listed);
--   fewer than 2 members left drop the rotation, the remaining member (if any) being the assignee. The assignee has
--   assigned_by NULL, or the completer when the completer is the assignee;
-- - without rotation: the same assignees (all still members), each with assigned_by = user_id (a continuation);
-- - activity: turn_started when the new occurrence has a turn holder.
-- The insert runs with `equipe.spawning` on: tasks_before_insert keeps created_by, the quota and the
-- task_created event are skipped.
create function private.spawn_next_occurrence(p_task public.tasks)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid := gen_random_uuid();
  v_due timestamptz;
  v_members uuid[];
  v_rotation uuid[];
  v_turn uuid;
  v_assignee uuid;
  v_count integer;
  v_position integer;
begin
  v_due := private.next_due_at(
    p_task.repeat_freq, p_task.repeat_interval, p_task.repeat_weekdays, p_task.repeat_month_day,
    p_task.repeat_tz, p_task.due_at, now()
  );

  if p_task.rotation is not null then
    select coalesce(array_agg(r.user_id order by r.ord), '{}')
    into v_members
    from unnest(p_task.rotation) with ordinality as r (user_id, ord)
    where exists (
      select 1
      from public.group_members gm
      where gm.group_id = p_task.group_id
        and gm.user_id = r.user_id
    );

    v_count := cardinality(p_task.rotation);
    v_position := array_position(p_task.rotation, p_task.turn_user_id);
    if v_position is null then
      v_turn := v_members[1];
    else
      for v_step in 1 .. v_count loop
        v_turn := p_task.rotation[(v_position - 1 + v_step) % v_count + 1];
        exit when v_turn = any (v_members);
        v_turn := null;
      end loop;
    end if;

    if cardinality(v_members) >= 2 then
      v_rotation := v_members;
      v_assignee := v_turn;
    else
      v_rotation := null;
      v_turn := null;
      v_assignee := v_members[1];
    end if;
  end if;

  perform set_config('equipe.spawning', 'on', true);

  insert into public.tasks (
    id, group_id, title, details, status, priority, due_at, created_by,
    repeat_freq, repeat_interval, repeat_weekdays, repeat_month_day, repeat_tz, series_id, rotation, turn_user_id
  )
  values (
    v_id, p_task.group_id, p_task.title, p_task.details, 'todo', p_task.priority, v_due, p_task.created_by,
    p_task.repeat_freq, p_task.repeat_interval, p_task.repeat_weekdays, p_task.repeat_month_day, p_task.repeat_tz,
    coalesce(p_task.series_id, p_task.id), v_rotation, v_turn
  );

  insert into public.task_checklist_items (task_id, group_id, title, position)
  select v_id, i.group_id, i.title, i.position
  from public.task_checklist_items i
  where i.task_id = p_task.id
  order by i.position;

  if p_task.rotation is not null then
    if v_assignee is not null then
      insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
      values (v_id, p_task.group_id, v_assignee, case when v_assignee = v_uid then v_uid end);
    end if;
  else
    insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
    select v_id, ta.group_id, ta.user_id, ta.user_id
    from public.task_assignees ta
    where ta.task_id = p_task.id;
  end if;

  if v_turn is not null then
    perform private.log_activity(p_task.group_id, 'turn_started', null, v_turn, v_id, p_task.title, null);
  end if;

  perform set_config('equipe.spawning', '', true);
  return v_id;
end;
$$;

-- After tasks_before_update (v1 rules and completed_by):
-- 1. update_task (draft `op` = update for this task): recurrence (NULL = unchanged, '{}' = none and no rotation,
--    else a rule; then the due-date requirement) → rotation (NULL or the stored list sent back as is = unchanged,
--    '{}' = none, else 2–20 distinct members, recurring tasks only);
-- 2. every update: a recurring task keeps a due date; server-maintained fields (series_id; repeat_month_day,
--    recomputed when the task becomes monthly, or when tz or the local date of the due date changes; the turn,
--    kept by a new rotation when still listed, else rotation[1]);
-- 3. status becoming done: task_completed, then the next occurrence of a recurring task not spawned yet (the spawn
--    runs here, so the completed row is written once, with next_occurrence_id). Reopening and completing again
--    spawns nothing more. Assignees completing a task spawn it too: they change the status only.
create function private.tasks_before_update_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft jsonb := private.task_draft();
  v_rule record;
  v_rotation uuid[];
begin
  if v_draft ->> 'op' = 'update' and (v_draft ->> 'task_id')::uuid = new.id then
    if v_draft -> 'recurrence' = '{}'::jsonb then
      new.repeat_freq := null;
      new.repeat_interval := 1;
      new.repeat_weekdays := null;
      new.repeat_tz := null;
      new.rotation := null;
    elsif nullif(v_draft -> 'recurrence', 'null'::jsonb) is not null then
      select * into v_rule from private.parse_recurrence(v_draft -> 'recurrence');
      new.repeat_freq := v_rule.r_freq;
      new.repeat_interval := v_rule.r_interval;
      new.repeat_weekdays := v_rule.r_weekdays;
      new.repeat_tz := v_rule.r_tz;
    end if;
    if new.repeat_freq is not null and new.due_at is null then
      raise exception using errcode = 'P0001', message = 'recurrence_requires_due_date';
    end if;

    v_rotation := private.jsonb_uuid_array(v_draft -> 'rotation');
    if v_rotation is not null and v_rotation is distinct from old.rotation then
      if cardinality(v_rotation) = 0 then
        new.rotation := null;
      else
        if new.repeat_freq is null then
          raise exception using errcode = 'P0001', message = 'invalid_rotation';
        end if;
        perform private.check_rotation(new.group_id, v_rotation);
        new.rotation := v_rotation;
      end if;
    end if;
  end if;

  if new.repeat_freq is null then
    new.series_id := null;
    new.repeat_month_day := null;
    new.turn_user_id := null;
  else
    -- Also when a v1 edit or a direct PATCH clears the due date of a recurring task.
    if new.due_at is null then
      raise exception using errcode = 'P0001', message = 'recurrence_requires_due_date';
    end if;
    new.series_id := coalesce(new.series_id, new.id);
    if new.repeat_freq = 'monthly' then
      if new.repeat_month_day is null
         or old.repeat_freq is distinct from 'monthly'
         or new.repeat_tz is distinct from old.repeat_tz
         or (new.due_at at time zone new.repeat_tz)::date is distinct from (old.due_at at time zone old.repeat_tz)::date then
        new.repeat_month_day := extract(day from new.due_at at time zone new.repeat_tz);
      end if;
    else
      new.repeat_month_day := null;
    end if;
    if new.rotation is null then
      new.turn_user_id := null;
    elsif new.rotation is distinct from old.rotation
          and (new.turn_user_id is null or not (new.turn_user_id = any (new.rotation))) then
      new.turn_user_id := new.rotation[1];
    end if;
  end if;

  if new.status = 'done' and old.status is distinct from 'done' then
    perform private.log_activity(new.group_id, 'task_completed', auth.uid(), null, new.id, new.title, null);
    if new.repeat_freq is not null and new.next_occurrence_id is null then
      new.next_occurrence_id := private.spawn_next_occurrence(new);
    end if;
  end if;

  return new;
end;
$$;

create trigger tasks_before_update_v2
  before update on public.tasks
  for each row execute function private.tasks_before_update_v2();

-- update_task gave the task a new rotation or turn holder: the turn holder becomes its only assignee, assigned by
-- the editor (existing row kept).
create function private.tasks_after_update_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft jsonb := private.task_draft();
begin
  if v_draft ->> 'op' = 'update' and (v_draft ->> 'task_id')::uuid = new.id
     and new.turn_user_id is not null
     and (new.rotation is distinct from old.rotation or new.turn_user_id is distinct from old.turn_user_id) then
    delete from public.task_assignees ta
    where ta.task_id = new.id
      and ta.user_id <> new.turn_user_id;

    insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
    select new.id, new.group_id, new.turn_user_id, auth.uid()
    where exists (
      select 1
      from public.group_members gm
      where gm.group_id = new.group_id
        and gm.user_id = new.turn_user_id
    )
    on conflict (task_id, user_id) do nothing;
  end if;
  return null;
end;
$$;

create trigger tasks_after_update_v2
  after update on public.tasks
  for each row execute function private.tasks_after_update_v2();

-- Checklist items ------------------------------------------------------------------------------------------------

-- Title normalized (invalid_item_title); id, task_id, group_id and created_at immutable; done_at / done_by follow
-- `done` like completed_at / completed_by (trusted contexts may set them explicitly).
create function private.task_checklist_items_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  new.title := private.normalize_item_title(new.title);

  if tg_op = 'INSERT' then
    if v_uid is not null then
      new.created_at := now();
      new.done_at := case when new.done then now() end;
      new.done_by := case when new.done then v_uid end;
    else
      new.created_at := coalesce(new.created_at, now());
      new.done_at := case when new.done then coalesce(new.done_at, now()) end;
      new.done_by := case when new.done then new.done_by end;
    end if;
    return new;
  end if;

  if new.id is distinct from old.id
     or new.task_id is distinct from old.task_id
     or new.group_id is distinct from old.group_id
     or new.created_at is distinct from old.created_at then
    raise exception using errcode = '42501', message = 'immutable_field';
  end if;

  if new.done then
    if not old.done then
      if not (v_uid is null and new.done_at is not null and new.done_at is distinct from old.done_at) then
        new.done_at := now();
      end if;
      if not (v_uid is null and new.done_by is distinct from old.done_by) then
        new.done_by := v_uid;
      end if;
    else
      if v_uid is not null then
        new.done_at := old.done_at;
      end if;
      if new.done_by is not null and v_uid is not null then
        new.done_by := old.done_by;
      end if;
    end if;
  else
    new.done_at := null;
    new.done_by := null;
  end if;

  return new;
end;
$$;

create trigger task_checklist_items_before_write
  before insert or update on public.task_checklist_items
  for each row execute function private.task_checklist_items_before_write();

-- Checklist writes bump the group like task writes (Realtime signal, docs/CONTRACTS-V2.md §5).
create trigger task_checklist_items_after_change_signal
  after insert or update or delete on public.task_checklist_items
  for each row execute function private.on_group_content_change();

-- checklist_item_done: an item becomes done.
create function private.task_checklist_items_after_update_activity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.done and not old.done then
    perform private.log_activity(
      new.group_id, 'checklist_item_done', auth.uid(), null, new.task_id,
      (select t.title from public.tasks t where t.id = new.task_id), new.title
    );
  end if;
  return null;
end;
$$;

create trigger task_checklist_items_after_update_activity
  after update on public.task_checklist_items
  for each row execute function private.task_checklist_items_after_update_activity();

-- Memberships: member_joined / member_left -------------------------------------------------------------------------
-- member_joined: every insert except the first member of a group, its creator (create_group inserts the creator's
-- membership alone, right after the group). member_left: every delete while the group still exists (leave, removal,
-- account deletion: private.log_activity stores a deleted profile as NULL and skips a group being deleted).

create function private.group_members_activity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if exists (
      select 1
      from public.group_members gm
      where gm.group_id = new.group_id
        and gm.user_id <> new.user_id
    ) then
      perform private.log_activity(new.group_id, 'member_joined', new.user_id, new.user_id, null, null, null);
    end if;
  else
    perform private.log_activity(old.group_id, 'member_left', auth.uid(), old.user_id, null, null, null);
  end if;
  return null;
end;
$$;

create trigger group_members_after_write_activity
  after insert or delete on public.group_members
  for each row execute function private.group_members_activity();

-- ntfy push: rotation turns --------------------------------------------------------------------------------------
-- Same as v1 (docs/CONTRACTS.md §7), except the wording of a rotation turn handed out by the server (assigned_by
-- NULL on a rotating task): « C’est ton tour dans « <group name> » » (docs/CONTRACTS-V2.md §11).

create or replace function private.notify_assignment_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base_url text;
  v_topic text;
  v_group_name text;
  v_message text;
begin
  -- Self-assignments are never pushed (assigned_by NULL = trusted context or rotation turn: pushed).
  if new.assigned_by is not distinct from new.user_id then
    return null;
  end if;

  select ps.topic into v_topic from public.push_subscriptions ps where ps.user_id = new.user_id;
  if v_topic is null then
    return null; -- not subscribed
  end if;

  -- Everything below runs in a subtransaction (entered only for subscribed assignees): an error rolls back the
  -- queued request and the log row only.
  begin
    select s.value into v_base_url from private.settings s where s.key = 'ntfy_base_url';
    if coalesce(v_base_url, '') = '' then
      return null; -- push turned off
    end if;

    -- The window is inclusive: a push exactly one hour old still counts.
    delete from private.push_log pl
    where pl.user_id = new.user_id
      and pl.queued_at < now() - interval '1 hour';

    if exists (
      select 1 from private.push_log pl where pl.user_id = new.user_id and pl.task_id = new.task_id
    ) then
      return null; -- already pushed for this task within the hour
    end if;

    if (select count(*) from private.push_log pl where pl.user_id = new.user_id)
       >= private.setting_int('push_max_per_hour', 30) then
      return null; -- per-user hourly limit reached
    end if;

    select g.name into v_group_name from public.groups g where g.id = new.group_id;

    if new.assigned_by is null
       and exists (select 1 from public.tasks t where t.id = new.task_id and t.rotation is not null) then
      -- No-break spaces inside the guillemets.
      v_message := E'C’est ton tour dans « ' || coalesce(v_group_name, '') || E' »';
    else
      v_message := 'Nouvelle tâche assignée dans « ' || coalesce(v_group_name, '') || ' »';
    end if;

    perform net.http_post(
      url := v_base_url,
      body := jsonb_build_object(
        'topic', v_topic,
        'title', 'Équipe',
        'message', v_message,
        'click', 'equipe://task/' || new.group_id::text || '/' || new.task_id::text
      ),
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 5000
    );

    insert into private.push_log (user_id, task_id) values (new.user_id, new.task_id);
  exception when others then
    -- Never log the topic or the group name.
    raise warning 'notify_assignment_push: push not queued (%)', sqlstate;
  end;

  return null;
end;
$$;

-- Privileges ----------------------------------------------------------------------------------------------------

revoke all on all functions in schema private from public, anon;
revoke all on function private.tasks_before_insert_v2() from authenticated;
revoke all on function private.tasks_after_insert_v2() from authenticated;
revoke all on function private.spawn_next_occurrence(public.tasks) from authenticated;
revoke all on function private.tasks_before_update_v2() from authenticated;
revoke all on function private.tasks_after_update_v2() from authenticated;
revoke all on function private.task_checklist_items_before_write() from authenticated;
revoke all on function private.task_checklist_items_after_update_activity() from authenticated;
revoke all on function private.group_members_activity() from authenticated;
