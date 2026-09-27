-- Teamly — the app is renamed « Teamly » (it was « Équipe »): the ntfy push of a new assignment or of a rotation
-- turn now has the title « Teamly » (docs/CONTRACTS.md §7, docs/CONTRACTS-V2.md §11). Nothing else changes: the
-- function below is the one of 20260925000300_v2_triggers.sql but for its title, and the click deep link keeps the
-- equipe:// scheme of the installed apps.

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
        'title', 'Teamly',
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

-- Privileges (kept by `create or replace`, restated) --------------------------------------------------------------

revoke all on function private.notify_assignment_push() from public, anon, authenticated;
