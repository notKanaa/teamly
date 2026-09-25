-- Équipe v2 — three refinements (docs/CONTRACTS-V2.md §0, §2, §5, §6, §7, §11):
-- (A) a turn holder who stops being a member (leave, removal, account deletion) hands the turn over at once;
-- (B) a change of display name or avatar bumps every group of the user (co-members reload the members);
-- (C) a v1 update_task that clears the due date of a recurring task makes it a plain task instead of failing.

-- (A) Turn handover ---------------------------------------------------------------------------------------------------
-- After a membership deletion in a group that still exists, every pending occurrence (status ≠ done) of a rotating task
-- of that group whose turn holder was the departed user gets a new turn at once:
-- - the next member found cyclically after the departed user's position in `rotation` (the rule of the spawn), assigned
--   with assigned_by = NULL (a turn handed out by the server: « C’est ton tour ») and announced by turn_started;
-- - fewer than 2 members of the rotation left: the rotation and the turn are dropped, and the remaining member, if any,
--   becomes the assignee with assigned_by = NULL (no turn_started).
-- The departed id stays in `rotation` until the next spawn cleans it; turn_user_id always points to a member.
--
-- Account deletion: the profile's ON DELETE SET NULL of tasks.turn_user_id and the ON DELETE CASCADE of the membership
-- run in an order that depends on the constraints' oids. Both orders are handled: when turn_user_id was already set to
-- NULL, an occurrence whose rotation lists the departed user is handed over from that user's position; when it was not,
-- the handover moves the turn first and the SET NULL then matches nothing. The departed user's assignment is gone by
-- then (the task_assignees cascade is an RI trigger, which fires before these triggers), and no row written here
-- references the deleted profile.
--
-- The trigger is named to fire after group_members_after_write_activity: member_left comes before turn_started.

create function private.hand_over_turns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task record;
  v_members uuid[];
  v_count integer;
  v_position integer;
  v_turn uuid;
begin
  -- The group is being deleted (delete_group, last member leaving, sole-member account deletion).
  if not exists (select 1 from public.groups g where g.id = old.group_id) then
    return null;
  end if;

  for v_task in
    select t.id, t.title, t.rotation
    from public.tasks t
    where t.group_id = old.group_id
      and t.status <> 'done'
      and t.rotation is not null
      and (t.turn_user_id = old.user_id or (t.turn_user_id is null and old.user_id = any (t.rotation)))
    order by t.id
    for update
  loop
    -- Members of the group still listed, in rotation order.
    select coalesce(array_agg(r.user_id order by r.ord), '{}')
    into v_members
    from unnest(v_task.rotation) with ordinality as r (user_id, ord)
    where exists (
      select 1
      from public.group_members gm
      where gm.group_id = old.group_id
        and gm.user_id = r.user_id
    );

    if cardinality(v_members) >= 2 then
      v_count := cardinality(v_task.rotation);
      v_position := array_position(v_task.rotation, old.user_id);
      v_turn := null;
      for v_step in 1 .. v_count loop
        v_turn := v_task.rotation[(v_position - 1 + v_step) % v_count + 1];
        exit when v_turn = any (v_members);
        v_turn := null;
      end loop;

      update public.tasks t set turn_user_id = v_turn where t.id = v_task.id;

      delete from public.task_assignees ta
      where ta.task_id = v_task.id
        and ta.user_id <> v_turn;
      insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
      values (v_task.id, old.group_id, v_turn, null)
      on conflict (task_id, user_id) do nothing;

      perform private.log_activity(old.group_id, 'turn_started', null, v_turn, v_task.id, v_task.title, null);
    else
      update public.tasks t set rotation = null, turn_user_id = null where t.id = v_task.id;

      if cardinality(v_members) = 1 then
        insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
        values (v_task.id, old.group_id, v_members[1], null)
        on conflict (task_id, user_id) do nothing;
      end if;
    end if;
  end loop;

  return null;
end;
$$;

create trigger group_members_after_write_turns
  after delete on public.group_members
  for each row execute function private.hand_over_turns();

-- (B) Profile signals ----------------------------------------------------------------------------------------------------
-- A change of display_name, avatar_color or avatar_emoji bumps last_activity_at of every group of the user (at most once
-- per group per transaction: private.bump_group_activity), so co-members reload the members through the existing groups
-- UPDATE signal. Other profile updates (onboarded_at, memberships_changed_at) bump nothing.

create function private.profiles_after_update_signal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (new.display_name, new.avatar_color, new.avatar_emoji)
     is distinct from (old.display_name, old.avatar_color, old.avatar_emoji) then
    perform private.bump_group_activity(gm.group_id)
    from public.group_members gm
    where gm.user_id = new.id;
  end if;
  return null;
end;
$$;

create trigger profiles_after_update_signal
  after update on public.profiles
  for each row execute function private.profiles_after_update_signal();

-- (C) update_task clearing the due date of a recurring task -----------------------------------------------------------------
-- Same function as in 20260925000300_v2_triggers.sql, with one more case in step 1: when p_recurrence is NULL
-- (unchanged: every v1 call) and the due date becomes NULL, the task becomes a plain task (rule and rotation cleared,
-- assignees kept) instead of raising recurrence_requires_due_date. An explicit rule with a NULL due date still raises it,
-- and so does a direct PATCH of the due date (no draft).
--
-- After tasks_before_update (v1 rules and completed_by):
-- 1. update_task (draft `op` = update for this task): recurrence (NULL = unchanged, or cleared with the rotation when the
--    due date is cleared; '{}' = none and no rotation; else a rule; then the due-date requirement) → rotation (NULL or
--    the stored list sent back as is = unchanged, '{}' = none, else 2–20 distinct members, recurring tasks only);
-- 2. every update: a recurring task keeps a due date; server-maintained fields (series_id; repeat_month_day,
--    recomputed when the task becomes monthly, or when tz or the local date of the due date changes; the turn,
--    kept by a new rotation when still listed, else rotation[1]);
-- 3. status becoming done: task_completed, then the next occurrence of a recurring task not spawned yet (the spawn
--    runs here, so the completed row is written once, with next_occurrence_id). Reopening and completing again
--    spawns nothing more. Assignees completing a task spawn it too: they change the status only.
create or replace function private.tasks_before_update_v2()
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
    elsif new.repeat_freq is not null and new.due_at is null then
      -- p_recurrence NULL (every v1 call) with the due date cleared: the task becomes a plain task.
      new.repeat_freq := null;
      new.repeat_interval := 1;
      new.repeat_weekdays := null;
      new.repeat_tz := null;
      new.rotation := null;
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
    -- A direct PATCH that clears the due date of a recurring task is refused.
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

-- Privileges -------------------------------------------------------------------------------------------------------------

revoke all on all functions in schema private from public, anon;
revoke all on function private.hand_over_turns() from authenticated;
revoke all on function private.profiles_after_update_signal() from authenticated;
