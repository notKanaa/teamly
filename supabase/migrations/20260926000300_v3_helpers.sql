-- Teamly v3 — private helpers (docs/CONTRACTS-V3.md): absence, the choice of a turn holder with the absence skip, first
-- names, activity events with a date range, and the ntfy push of nudges and mentions.
-- Pure helpers are invoker functions; the ones reading or writing tables are security definer. None is executable by API
-- roles (revokes at the end).

-- Absence (§2) --------------------------------------------------------------------------------------------------------------

-- True when p_user_id is away on the local date p_day (away_from <= p_day <= away_until). NULL p_day: false.
create function private.is_away(p_user_id uuid, p_day date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = p_user_id
      and p.away_from <= p_day
      and p_day <= p.away_until
  );
$$;

-- The turn holder chosen by the server (§2 « Absence skip »): the elements of p_rotation that are in p_candidates, in
-- rotation order, cyclically after p_after's position (p_after itself last) — from the start when p_after is not listed
-- (or NULL). The first of them who is not away on p_day wins; when every one of them is away, the first of them (the
-- normal choice); NULL when there is none.
-- Callers: create_task with a rotation (p_after NULL: rotation[1] unless away), the spawn and the handovers (p_after = the
-- previous turn holder).
create function private.pick_turn(p_rotation uuid[], p_candidates uuid[], p_after uuid, p_day date)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_count integer := coalesce(cardinality(p_rotation), 0);
  v_position integer := coalesce(array_position(p_rotation, p_after), 0);
  v_user uuid;
  v_first uuid;
begin
  for v_step in 1 .. v_count loop
    v_user := p_rotation[(v_position - 1 + v_step) % v_count + 1];
    continue when v_user is null or not (v_user = any (p_candidates));
    if v_first is null then
      v_first := v_user;
    end if;
    if not private.is_away(v_user, p_day) then
      return v_user;
    end if;
  end loop;
  return v_first;
end;
$$;

-- First names (§1, §5) ------------------------------------------------------------------------------------------------------

-- The first word of a display name (« Camille Martin » → « Camille », « Jean-Pierre Durand » → « Jean-Pierre »): the
-- trimmed name up to its first Unicode White_Space code point, like FrenchText.firstName (Swift).
create function private.first_name(p_display_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.regexp_replace(
    private.clean_text(p_display_name),
    '[\u0009-\u000d \u0085   -     　].*$',
    ''
  );
$$;

-- Activity feed (§2, §7) ------------------------------------------------------------------------------------------------------

-- private.log_activity with the date range of member_away (starts_on, ends_on). Same rules: the group's events older than
-- 90 days are deleted first (retention), no-op for a group being deleted, a deleted actor or subject is stored as NULL,
-- and writing an event does not bump the group.
create function private.write_activity(
  p_group_id uuid,
  p_kind text,
  p_actor_id uuid,
  p_subject_id uuid,
  p_task_id uuid,
  p_task_title text,
  p_item_title text,
  p_starts_on date,
  p_ends_on date
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.groups g where g.id = p_group_id) then
    return;
  end if;

  delete from public.group_activity a
  where a.group_id = p_group_id
    and a.created_at < now() - interval '90 days';

  insert into public.group_activity (
    group_id, kind, actor_id, subject_id, task_id, task_title, item_title, starts_on, ends_on
  )
  values (
    p_group_id,
    p_kind,
    (select p.id from public.profiles p where p.id = p_actor_id),
    (select p.id from public.profiles p where p.id = p_subject_id),
    p_task_id,
    p_task_title,
    p_item_title,
    p_starts_on,
    p_ends_on
  );
end;
$$;

-- Same signature and behaviour as in 20260925000200_v2_helpers.sql: now one writer for every event.
create or replace function private.log_activity(
  p_group_id uuid,
  p_kind text,
  p_actor_id uuid,
  p_subject_id uuid,
  p_task_id uuid,
  p_task_title text,
  p_item_title text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.write_activity(p_group_id, p_kind, p_actor_id, p_subject_id, p_task_id, p_task_title, p_item_title,
                                 null, null);
end;
$$;

-- ntfy push of nudges and mentions (§1, §5) -------------------------------------------------------------------------------------
-- The rules of the assignment push (docs/CONTRACTS.md §7), for one push of p_kind ('nudge' or 'mention') to p_user_id about
-- a task: only for a user with a subscription and while ntfy_base_url is set; at most one push per (user, task, kind) per
-- hour and push_max_per_hour pushes per user per hour, all kinds counted (window inclusive, private.push_log). JSON
-- {topic, title « Teamly », message, click equipe://task/<group>/<task>}. No task title or details are sent. Queued in the
-- caller's transaction; any preparation error becomes a WARNING and never fails the write.
create function private.queue_push(
  p_user_id uuid,
  p_task_id uuid,
  p_group_id uuid,
  p_kind text,
  p_message text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base_url text;
  v_topic text;
begin
  select ps.topic into v_topic from public.push_subscriptions ps where ps.user_id = p_user_id;
  if v_topic is null then
    return; -- not subscribed
  end if;

  -- Subtransaction: an error rolls back the queued request and the log row only.
  begin
    select s.value into v_base_url from private.settings s where s.key = 'ntfy_base_url';
    if coalesce(v_base_url, '') = '' then
      return; -- push turned off
    end if;

    delete from private.push_log pl
    where pl.user_id = p_user_id
      and pl.queued_at < now() - interval '1 hour';

    if exists (
      select 1
      from private.push_log pl
      where pl.user_id = p_user_id
        and pl.task_id = p_task_id
        and pl.kind = p_kind
    ) then
      return; -- already pushed for this task and kind within the hour
    end if;

    if (select count(*) from private.push_log pl where pl.user_id = p_user_id)
       >= private.setting_int('push_max_per_hour', 30) then
      return; -- per-user hourly limit reached
    end if;

    perform net.http_post(
      url := v_base_url,
      body := jsonb_build_object(
        'topic', v_topic,
        'title', 'Teamly',
        'message', p_message,
        'click', 'equipe://task/' || p_group_id::text || '/' || p_task_id::text
      ),
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 5000
    );

    insert into private.push_log (user_id, task_id, kind) values (p_user_id, p_task_id, p_kind);
  exception when others then
    -- Never log the topic or the message.
    raise warning 'queue_push: push not queued (%)', sqlstate;
  end;
end;
$$;

-- « <prénom> te relance dans « <groupe> » » / « <prénom> t’a mentionné dans « <groupe> » »: U+2019 apostrophe, no-break
-- spaces (U+00A0) inside the guillemets, as the rotation push of docs/CONTRACTS-V2.md §11.
create function private.push_message(p_kind text, p_from_user uuid, p_group_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_first_name text;
  v_group_name text;
begin
  select private.first_name(p.display_name) into v_first_name from public.profiles p where p.id = p_from_user;
  select g.name into v_group_name from public.groups g where g.id = p_group_id;
  v_first_name := coalesce(nullif(v_first_name, ''), 'Quelqu' || chr(8217) || 'un');
  return v_first_name
    || case when p_kind = 'nudge' then ' te relance dans ' else ' t' || chr(8217) || 'a mentionné dans ' end
    || '«' || chr(160) || coalesce(v_group_name, '') || chr(160) || '»';
end;
$$;

-- Privileges --------------------------------------------------------------------------------------------------------------------
-- Nothing above is callable by API roles (the RLS helpers keep their explicit `authenticated` grant).

revoke all on all functions in schema private from public, anon;
revoke all on function private.is_away(uuid, date) from authenticated;
revoke all on function private.pick_turn(uuid[], uuid[], uuid, date) from authenticated;
revoke all on function private.first_name(text) from authenticated;
revoke all on function private.write_activity(uuid, text, uuid, uuid, uuid, text, text, date, date) from authenticated;
revoke all on function private.log_activity(uuid, text, uuid, uuid, uuid, text, text) from authenticated;
revoke all on function private.queue_push(uuid, uuid, uuid, text, text) from authenticated;
revoke all on function private.push_message(text, uuid, uuid) from authenticated;
