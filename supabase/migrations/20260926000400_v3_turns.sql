-- Teamly v3 — turn holders (docs/CONTRACTS-V3.md §2, §3): the absence skip whenever the server chooses a turn holder
-- (create_task with a rotation, the spawn, the handover of a departed turn holder; set_away hands over in the RPC), the
-- repayment of accepted swaps at spawn, the automatic cancellation of pending swaps, and the group signal of an away
-- change.
--
-- The v2 functions private.spawn_next_occurrence and private.hand_over_turns are replaced in place (`create or replace`:
-- same triggers, same privileges) with their v2 body plus the v3 additions. Without anyone away and without swaps they
-- behave exactly as in v2. update_task keeps its v2 rule (a new rotation without the current turn holder gives the turn
-- to rotation[1], the order chosen by the editor): no absence skip there.
-- BEFORE INSERT on tasks now fires: tasks_before_insert → tasks_before_insert_v2 → tasks_before_insert_v3 →
-- tasks_quota_before_insert.

-- create_task with a rotation: the absence skip ------------------------------------------------------------------------------
-- tasks_before_insert_v2 validated the rotation (members only) and gave the turn to rotation[1]; the turn goes to the first
-- member of the rotation, in order, who is not away on the local due date (rotation[1] when everyone is away).
-- tasks_after_insert_v2 then assigns the turn holder, assigned by the creator.

create function private.tasks_before_insert_v3()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft jsonb := private.task_draft();
begin
  if not private.is_spawning()
     and v_draft ->> 'op' = 'create'
     and (v_draft ->> 'group_id')::uuid = new.group_id
     and new.rotation is not null then
    new.turn_user_id := private.pick_turn(
      new.rotation, new.rotation, null, (new.due_at at time zone new.repeat_tz)::date
    );
  end if;
  return new;
end;
$$;

create trigger tasks_before_insert_v3
  before insert on public.tasks
  for each row execute function private.tasks_before_insert_v3();

-- The spawn -------------------------------------------------------------------------------------------------------------------
-- Same function as in 20260925000300_v2_triggers.sql, with the next turn chosen by private.pick_turn:
-- - absence skip: the first member found cyclically after the previous turn holder's position (the previous holder last)
--   who is not away on the new occurrence's local due date; the normal choice when every one of them is away;
-- - repayment: with N that turn holder, the oldest (created_at, then id) accepted swap of the series with to_user = N and
--   repaid_at NULL whose from_user is still a member listed in the rotation. When that from_user is not away on the new
--   local due date, the turn goes to from_user instead and the swap gets repaid_at = now(); otherwise nothing is repaid
--   this time.
create or replace function private.spawn_next_occurrence(p_task public.tasks)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid := gen_random_uuid();
  v_due timestamptz;
  v_day date;
  v_members uuid[];
  v_rotation uuid[];
  v_turn uuid;
  v_assignee uuid;
  v_swap record;
begin
  v_due := private.next_due_at(
    p_task.repeat_freq, p_task.repeat_interval, p_task.repeat_weekdays, p_task.repeat_month_day,
    p_task.repeat_tz, p_task.due_at, now()
  );
  v_day := (v_due at time zone p_task.repeat_tz)::date;

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

    if cardinality(v_members) >= 2 then
      v_rotation := v_members;
      v_turn := private.pick_turn(p_task.rotation, v_members, p_task.turn_user_id, v_day);

      select s.id, s.from_user
      into v_swap
      from public.turn_swaps s
      where s.series_id = coalesce(p_task.series_id, p_task.id)
        and s.status = 'accepted'
        and s.repaid_at is null
        and s.to_user = v_turn
        and s.from_user = any (v_members)
      order by s.created_at, s.id
      limit 1
      for update;
      if found then
        if not private.is_away(v_swap.from_user, v_day) then
          update public.turn_swaps s set repaid_at = now() where s.id = v_swap.id;
          v_turn := v_swap.from_user;
        end if;
      end if;

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

-- Turn holder leaving (handover) ------------------------------------------------------------------------------------------------
-- Same function as in 20260925000500_v2_turn_handover_signals.sql, with the absence skip: the next member after the
-- departed user's position who is not away on the pending occurrence's local due date (the normal choice when every
-- one of them is away).
create or replace function private.hand_over_turns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task record;
  v_members uuid[];
  v_turn uuid;
begin
  -- The group is being deleted (delete_group, last member leaving, sole-member account deletion).
  if not exists (select 1 from public.groups g where g.id = old.group_id) then
    return null;
  end if;

  for v_task in
    select t.id, t.title, t.rotation, t.due_at, t.repeat_tz
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
      v_turn := private.pick_turn(
        v_task.rotation, v_members, old.user_id, (v_task.due_at at time zone v_task.repeat_tz)::date
      );

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

-- Automatic cancellation of pending swaps (§3) ------------------------------------------------------------------------------------
-- A pending swap becomes `cancelled` (responded_at = now()) as soon as it can no longer be accepted as asked:
-- - its occurrence becomes done, loses its rotation, gets another turn holder than from_user (a handover, set_away, an
--   update_task, a trusted edit), or no longer lists to_user in its rotation (tasks AFTER UPDATE);
-- - from_user or to_user stops being a member of the group (group_members AFTER DELETE);
-- - a deleted occurrence deletes its swaps (foreign key cascade), and so does a deleted account.
-- Accepting a swap marks it accepted before it moves the turn, so it is never cancelled by its own acceptance.

create function private.tasks_after_update_v3()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.turn_swaps s
  set status = 'cancelled',
      responded_at = now()
  where s.task_id = new.id
    and s.status = 'pending'
    and (
      new.status = 'done'
      or new.rotation is null
      or new.turn_user_id is distinct from s.from_user
      or not (s.to_user = any (new.rotation))
    );
  return null;
end;
$$;

create trigger tasks_after_update_v3
  after update on public.tasks
  for each row execute function private.tasks_after_update_v3();

create function private.cancel_turn_swaps_of_departed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- The group is being deleted: its swaps go with its tasks.
  if not exists (select 1 from public.groups g where g.id = old.group_id) then
    return null;
  end if;

  update public.turn_swaps s
  set status = 'cancelled',
      responded_at = now()
  where s.group_id = old.group_id
    and s.status = 'pending'
    and (s.to_user = old.user_id or s.from_user = old.user_id);
  return null;
end;
$$;

create trigger group_members_after_delete_swaps
  after delete on public.group_members
  for each row execute function private.cancel_turn_swaps_of_departed();

-- Away signal (§2) --------------------------------------------------------------------------------------------------------------
-- A change of away_from / away_until bumps every group of the user (at most once per group per transaction), like an avatar
-- change: co-members reload the members and see who is away. The profile UPDATE itself is the user's own
-- `.membershipsChanged` signal.

create function private.profiles_after_update_away_signal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (new.away_from, new.away_until) is distinct from (old.away_from, old.away_until) then
    perform private.bump_group_activity(gm.group_id)
    from public.group_members gm
    where gm.user_id = new.id;
  end if;
  return null;
end;
$$;

create trigger profiles_after_update_away_signal
  after update on public.profiles
  for each row execute function private.profiles_after_update_away_signal();

-- Privileges ----------------------------------------------------------------------------------------------------------------------

revoke all on all functions in schema private from public, anon;
revoke all on function private.tasks_before_insert_v3() from authenticated;
revoke all on function private.spawn_next_occurrence(public.tasks) from authenticated;
revoke all on function private.hand_over_turns() from authenticated;
revoke all on function private.tasks_after_update_v3() from authenticated;
revoke all on function private.cancel_turn_swaps_of_departed() from authenticated;
revoke all on function private.profiles_after_update_away_signal() from authenticated;
