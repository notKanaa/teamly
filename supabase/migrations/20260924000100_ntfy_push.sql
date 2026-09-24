-- Équipe — ntfy push on new assignments (docs/CONTRACTS.md §7) and the private server settings.
--
-- On INSERT into task_assignees, when someone else assigned the user and the user has a push subscription,
-- pg_net queues a JSON POST to the ntfy server root: {topic, title: "Équipe", message, click}. pg_net only
-- sends JSON bodies (other content types raise), and ntfy accepts JSON published to its root URL. The topic
-- stays out of the URL, so it never lands in URL logs (ntfy's response, which echoes it, is kept for
-- pg_net.ttl = 6 h in net._http_response: see the security note below).
--
-- Guarantees:
-- - the request is queued in the same transaction as the assignment: nothing is sent if the insert rolls back;
-- - any error while preparing the push (pg_net missing, settings, log) is turned into a WARNING and never
--   fails the assignment; HTTP errors happen later in the pg_net worker and never touch the insert;
-- - no task title or details are sent (ntfy.sh is a public server), only the group name and the deep link;
-- - abuse control: at most one push per (user, task) per hour (removing and re-adding someone does not spam
--   them) and at most `push_max_per_hour` pushes per user per hour.
--
-- Security note: Supabase grants anon/authenticated EXECUTE on net.http_post and USAGE on schema `net` when
-- pg_net is created (event trigger grant_pg_net_access, as supabase_admin: postgres cannot revoke it), and
-- pg_net grants PUBLIC every privilege on net.http_request_queue and net._http_response. Only the fact that
-- `net` is not an exposed API schema keeps them out of the API: never expose `net` (or `private`).

create extension if not exists pg_net with schema extensions;

-- Private settings -------------------------------------------------------------------------------------
-- Read by definer functions only. Changed from the SQL editor (e.g. to point to a self-hosted ntfy server, or
-- to turn push off with a NULL base URL, like supabase/seed.sql does for the local stack and CI).

create table private.settings (
  key text primary key,
  value text
);

alter table private.settings enable row level security;
revoke all on table private.settings from public, anon, authenticated;

insert into private.settings (key, value) values
  ('ntfy_base_url', 'https://ntfy.sh/'),
  ('push_max_per_hour', '30');

-- Integer setting, or `p_default` when the key is missing or not a non-negative integer.
-- Called by definer functions only (API roles cannot execute it).
create function private.setting_int(p_key text, p_default integer)
returns integer
language plpgsql
stable
set search_path = ''
as $$
declare
  v_value text;
begin
  select s.value into v_value from private.settings s where s.key = p_key;
  v_value := pg_catalog.btrim(v_value);
  if v_value ~ '^[0-9]{1,9}$' then
    return v_value::integer;
  end if;
  return p_default;
end;
$$;

-- Push log (abuse control) ------------------------------------------------------------------------------
-- One row per queued push; rows older than one hour are pruned by the trigger. Deleted with the profile.

create table private.push_log (
  user_id uuid not null references public.profiles (id) on delete cascade,
  task_id uuid not null,
  queued_at timestamptz not null default now()
);

create index push_log_user_queued_at_idx on private.push_log (user_id, queued_at);

alter table private.push_log enable row level security;
revoke all on table private.push_log from public, anon, authenticated;

-- Trigger ----------------------------------------------------------------------------------------------

create function private.notify_assignment_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base_url text;
  v_topic text;
  v_group_name text;
begin
  -- Self-assignments are never pushed (assigned_by NULL = trusted context: pushed like any assignment).
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

    perform net.http_post(
      url := v_base_url,
      body := jsonb_build_object(
        'topic', v_topic,
        'title', 'Équipe',
        'message', 'Nouvelle tâche assignée dans « ' || coalesce(v_group_name, '') || ' »',
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

create trigger task_assignees_after_insert_push
  after insert on public.task_assignees
  for each row execute function private.notify_assignment_push();

-- Privileges ------------------------------------------------------------------------------------------

revoke all on function private.setting_int(text, integer) from public, anon, authenticated;
revoke all on function private.notify_assignment_push() from public, anon, authenticated;
