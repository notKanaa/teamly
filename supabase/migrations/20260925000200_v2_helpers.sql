-- Équipe v2 — private helpers (docs/CONTRACTS-V2.md): appearance and checklist validation, recurrence rules
-- (parsing and the next due date), rotation and assignee checks, the task draft that create_task / update_task
-- pass to the task triggers, and the activity writer.
-- Pure helpers are invoker functions (like private.clean_text); the ones reading or writing tables are security
-- definer. None is executable by API roles (catch-all revoke at the end).

-- Appearance (§1) ------------------------------------------------------------------------------------------

-- NULL (automatic color) or a ColorKey, else `invalid_color`.
create function private.check_color(p_color text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_color is not null
     and p_color not in ('indigo', 'violet', 'blue', 'teal', 'green', 'amber', 'orange', 'coral', 'pink') then
    raise exception using errcode = 'P0001', message = 'invalid_color';
  end if;
end;
$$;

-- Normalized emoji: NULL, or clean_text then '' → NULL. Otherwise 1–16 code points, none from the trim set of
-- private.clean_text and no C0/C1 control (U+0000–001F, U+007F–009F), else `invalid_emoji`.
-- Same rule as the check constraints groups_emoji_format and profiles_avatar_emoji_format.
create function private.normalize_emoji(p_emoji text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_emoji text := nullif(private.clean_text(p_emoji), '');
begin
  if v_emoji is not null
     and v_emoji !~ '^[^\u0001- \u007f-   -​    　]{1,16}$' then
    raise exception using errcode = 'P0001', message = 'invalid_emoji';
  end if;
  return v_emoji;
end;
$$;

-- Checklists (§3) ------------------------------------------------------------------------------------------

-- Checklist item title: trimmed with private.clean_text, 1–200 code points, else `invalid_item_title`.
create function private.normalize_item_title(p_title text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_title text := private.clean_text(p_title);
begin
  if v_title is null or char_length(v_title) not between 1 and 200 then
    raise exception using errcode = 'P0001', message = 'invalid_item_title';
  end if;
  return v_title;
end;
$$;

-- Recurrence rules (§5, §6) -----------------------------------------------------------------------------------

-- True when p_value is a JSON number with an integral value in [p_min, p_max] (2 and 2.0 are accepted).
create function private.is_json_integer(p_value jsonb, p_min integer, p_max integer)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_number numeric;
begin
  if jsonb_typeof(p_value) is distinct from 'number' then
    return false;
  end if;
  v_number := (p_value #>> '{}')::numeric;
  return v_number = trunc(v_number) and v_number between p_min and p_max;
end;
$$;

-- IANA zone names known to PostgreSQL (pg_timezone_names, exact case), without the posix/ and right/ copies and the
-- "Factory" placeholder: the clients (Foundation, java.time) must understand the stored name.
create function private.is_valid_time_zone(p_tz text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_tz is not null
    and p_tz !~ '^(posix|right)/'
    and p_tz <> 'Factory'
    and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_tz);
$$;

-- Parses a recurrence rule:
--   {"freq": "daily" | "weekly" | "monthly", "interval": 1…52 (default 1), "weekdays": [1…7] (weekly only), "tz": "<IANA>"}
-- A key whose value is JSON null counts as absent. weekdays: 1–7 distinct integers in 1…7, any order, returned
-- ascending. Unknown keys and anything else raise `invalid_recurrence`.
create function private.parse_recurrence(
  p_rule jsonb,
  out r_freq text,
  out r_interval smallint,
  out r_weekdays smallint[],
  out r_tz text
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_value jsonb;
begin
  if jsonb_typeof(p_rule) is distinct from 'object' then
    raise exception using errcode = 'P0001', message = 'invalid_recurrence';
  end if;
  if exists (
    select 1 from jsonb_object_keys(p_rule) as k (key)
    where k.key not in ('freq', 'interval', 'weekdays', 'tz')
  ) then
    raise exception using errcode = 'P0001', message = 'invalid_recurrence';
  end if;

  v_value := p_rule -> 'freq';
  if jsonb_typeof(v_value) is distinct from 'string' or (v_value #>> '{}') not in ('daily', 'weekly', 'monthly') then
    raise exception using errcode = 'P0001', message = 'invalid_recurrence';
  end if;
  r_freq := v_value #>> '{}';

  v_value := nullif(p_rule -> 'interval', 'null'::jsonb);
  if v_value is null then
    r_interval := 1;
  elsif private.is_json_integer(v_value, 1, 52) then
    r_interval := (v_value #>> '{}')::numeric;
  else
    raise exception using errcode = 'P0001', message = 'invalid_recurrence';
  end if;

  v_value := nullif(p_rule -> 'weekdays', 'null'::jsonb);
  if v_value is not null then
    if r_freq <> 'weekly' or jsonb_typeof(v_value) <> 'array' then
      raise exception using errcode = 'P0001', message = 'invalid_recurrence';
    end if;
    if exists (
      select 1 from jsonb_array_elements(v_value) as e (day)
      where not private.is_json_integer(e.day, 1, 7)
    ) then
      raise exception using errcode = 'P0001', message = 'invalid_recurrence';
    end if;
    select array_agg(distinct (e.day #>> '{}')::numeric::smallint order by (e.day #>> '{}')::numeric::smallint)
    into r_weekdays
    from jsonb_array_elements(v_value) as e (day);
    -- Not empty, no duplicates.
    if r_weekdays is null or cardinality(r_weekdays) <> jsonb_array_length(v_value) then
      raise exception using errcode = 'P0001', message = 'invalid_recurrence';
    end if;
  end if;

  v_value := p_rule -> 'tz';
  if jsonb_typeof(v_value) is distinct from 'string' or not private.is_valid_time_zone(v_value #>> '{}') then
    raise exception using errcode = 'P0001', message = 'invalid_recurrence';
  end if;
  r_tz := v_value #>> '{}';
end;
$$;

-- step(d) of the algorithm (§6): the next local date of a rule after the local date p_day.
--   daily: d + interval days.
--   weekly without weekdays: d + 7 × interval days.
--   weekly with weekdays W: the smallest w ∈ W after isodow(d) in the same week, else the first weekday of W in the
--   week starting on monday(d) + 7 × interval days.
--   monthly: the day p_month_day (clamped to the month's length) of the month `interval` months after d's month.
create function private.recurrence_step(
  p_freq text,
  p_interval integer,
  p_weekdays smallint[],
  p_month_day integer,
  p_day date
)
returns date
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_isodow integer;
  v_next integer;
  v_month date;
  v_month_days integer;
begin
  if p_freq = 'daily' then
    return p_day + p_interval;
  elsif p_freq = 'weekly' then
    if p_weekdays is null then
      return p_day + 7 * p_interval;
    end if;
    v_isodow := extract(isodow from p_day)::integer;
    select min(w) into v_next from unnest(p_weekdays) as w where w > v_isodow;
    if v_next is not null then
      return p_day + (v_next - v_isodow);
    end if;
    select min(w) into v_next from unnest(p_weekdays) as w;
    return p_day - (v_isodow - 1) + 7 * p_interval + (v_next - 1);
  elsif p_freq = 'monthly' then
    v_month := (date_trunc('month', p_day::timestamp) + make_interval(months => p_interval))::date;
    v_month_days := extract(day from v_month + interval '1 month' - interval '1 day')::integer;
    return v_month + (least(p_month_day, v_month_days) - 1);
  end if;
  raise exception using errcode = 'P0001', message = 'invalid_recurrence';
end;
$$;

-- Next due date (§6). With local = p_due_at at time zone p_tz, date d and time of day t: c = step(d), then
-- c = step(c) while (c + t) at time zone p_tz <= p_now, applying step at most 10 000 times in total (the first
-- step included); the result is (c + t) at time zone p_tz. Missed occurrences are skipped and an early completion
-- does not repeat the same slot. A NULL p_month_day (monthly) means the local day of p_due_at.
-- Only explicit time zone conversions are used: the result does not depend on the session time zone.
create function private.next_due_at(
  p_freq text,
  p_interval integer,
  p_weekdays smallint[],
  p_month_day integer,
  p_tz text,
  p_due_at timestamptz,
  p_now timestamptz
)
returns timestamptz
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_local timestamp := p_due_at at time zone p_tz;
  v_time time := v_local::time;
  v_month_day integer := coalesce(p_month_day, extract(day from v_local)::integer);
  v_day date;
  v_steps integer := 1;
begin
  v_day := private.recurrence_step(p_freq, p_interval, p_weekdays, v_month_day, v_local::date);
  while (v_day + v_time) at time zone p_tz <= p_now and v_steps < 10000 loop
    v_day := private.recurrence_step(p_freq, p_interval, p_weekdays, v_month_day, v_day);
    v_steps := v_steps + 1;
  end loop;
  return (v_day + v_time) at time zone p_tz;
end;
$$;

-- Task draft and spawn flag ---------------------------------------------------------------------------------
-- create_task and update_task are security invoker (RLS, column grants and the v1 triggers apply) and cannot call
-- into `private`: they hand their v2 arguments to the security definer task triggers through the transaction-local
-- setting `equipe.task_draft` (JSON), which they reset right after their INSERT / UPDATE. API roles cannot set
-- custom settings (PostgREST only sets request.* and role), so the triggers can trust it.

-- The draft of the running create_task / update_task, or NULL.
create function private.task_draft()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select nullif(current_setting('equipe.task_draft', true), '')::jsonb;
$$;

-- True while private.spawn_next_occurrence inserts an occurrence (`equipe.spawning`, transaction-local).
create function private.is_spawning()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(current_setting('equipe.spawning', true), '') = 'on';
$$;

-- JSON array → uuid[] / text[] (element order kept, JSON null → NULL); NULL when p_value is not an array.
create function private.jsonb_uuid_array(p_value jsonb)
returns uuid[]
language plpgsql
immutable
set search_path = ''
as $$
begin
  if jsonb_typeof(p_value) is distinct from 'array' then
    return null;
  end if;
  return array(
    select (e.value #>> '{}')::uuid
    from jsonb_array_elements(p_value) with ordinality as e (value, ord)
    order by e.ord
  );
end;
$$;

create function private.jsonb_text_array(p_value jsonb)
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
begin
  if jsonb_typeof(p_value) is distinct from 'array' then
    return null;
  end if;
  return array(
    select e.value #>> '{}'
    from jsonb_array_elements(p_value) with ordinality as e (value, ord)
    order by e.ord
  );
end;
$$;

-- Assignees and rotation (§3) -----------------------------------------------------------------------------------

-- The distinct non-NULL ids of p_ids as the assignees of a task of p_group_id: at most 20 (`too_many_assignees`,
-- checked first), all members of the group (`assignee_not_member`). Shared by set_task_assignees and create_task.
create function private.clean_assignee_ids(p_group_id uuid, p_ids uuid[])
returns uuid[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  select coalesce(array_agg(distinct u.id), '{}')
  into v_ids
  from unnest(coalesce(p_ids, '{}'::uuid[])) as u (id)
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
      where gm.group_id = p_group_id
        and gm.user_id = u.id
    )
  ) then
    raise exception using errcode = 'P0001', message = 'assignee_not_member';
  end if;

  return v_ids;
end;
$$;

-- A new rotation for a task of p_group_id: 2–20 distinct user ids, no NULL, all members of the group, else
-- `invalid_rotation`.
create function private.check_rotation(p_group_id uuid, p_rotation uuid[])
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_rotation is null
     or array_ndims(p_rotation) is distinct from 1
     or cardinality(p_rotation) not between 2 and 20 then
    raise exception using errcode = 'P0001', message = 'invalid_rotation';
  end if;
  if array_position(p_rotation, null) is not null
     or (select count(distinct u.id) from unnest(p_rotation) as u (id)) <> cardinality(p_rotation) then
    raise exception using errcode = 'P0001', message = 'invalid_rotation';
  end if;
  if exists (
    select 1
    from unnest(p_rotation) as u (id)
    where not exists (
      select 1
      from public.group_members gm
      where gm.group_id = p_group_id
        and gm.user_id = u.id
    )
  ) then
    raise exception using errcode = 'P0001', message = 'invalid_rotation';
  end if;
end;
$$;

-- Permissions (§4) -----------------------------------------------------------------------------------------------

-- « Change status » rights on a task (docs/CONTRACTS.md §2), also the checklist rights: the caller is a member of
-- the task's group and its admin, the task's creator or one of its assignees.
create function private.can_change_task_status(p_task_id uuid, p_group_id uuid, p_created_by uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    private.is_group_member(p_group_id)
    and (
      private.is_group_admin(p_group_id)
      or p_created_by = (select auth.uid())
      or exists (
        select 1
        from public.task_assignees ta
        where ta.task_id = p_task_id
          and ta.user_id = (select auth.uid())
      )
    ),
    false
  );
$$;

-- Activity feed (§7) ----------------------------------------------------------------------------------------------

-- Writes one event of p_group_id, after deleting the group's events older than 90 days (retention). No-op when the
-- group no longer exists (it is being deleted). An actor or subject whose profile no longer exists (account
-- deletion in progress) is stored as NULL. Writing an event does not bump the group: the triggering write does.
create function private.log_activity(
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
  if not exists (select 1 from public.groups g where g.id = p_group_id) then
    return;
  end if;

  delete from public.group_activity a
  where a.group_id = p_group_id
    and a.created_at < now() - interval '90 days';

  insert into public.group_activity (group_id, kind, actor_id, subject_id, task_id, task_title, item_title)
  values (
    p_group_id,
    p_kind,
    (select p.id from public.profiles p where p.id = p_actor_id),
    (select p.id from public.profiles p where p.id = p_subject_id),
    p_task_id,
    p_task_title,
    p_item_title
  );
end;
$$;

-- Privileges ---------------------------------------------------------------------------------------------------
-- Nothing above is callable by API roles (the RLS helpers keep their explicit `authenticated` grant).

revoke all on all functions in schema private from public, anon;
revoke all on function private.check_color(text) from authenticated;
revoke all on function private.normalize_emoji(text) from authenticated;
revoke all on function private.normalize_item_title(text) from authenticated;
revoke all on function private.is_json_integer(jsonb, integer, integer) from authenticated;
revoke all on function private.is_valid_time_zone(text) from authenticated;
revoke all on function private.parse_recurrence(jsonb) from authenticated;
revoke all on function private.recurrence_step(text, integer, smallint[], integer, date) from authenticated;
revoke all on function private.next_due_at(text, integer, smallint[], integer, text, timestamptz, timestamptz) from authenticated;
revoke all on function private.task_draft() from authenticated;
revoke all on function private.is_spawning() from authenticated;
revoke all on function private.jsonb_uuid_array(jsonb) from authenticated;
revoke all on function private.jsonb_text_array(jsonb) from authenticated;
revoke all on function private.clean_assignee_ids(uuid, uuid[]) from authenticated;
revoke all on function private.check_rotation(uuid, uuid[]) from authenticated;
revoke all on function private.can_change_task_status(uuid, uuid, uuid) from authenticated;
revoke all on function private.log_activity(uuid, text, uuid, uuid, uuid, text, text) from authenticated;
