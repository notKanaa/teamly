-- Équipe — write quotas: groups and tasks created per user per hour.
--
-- One free account could otherwise fill the 500 MB free-tier database in about half an hour (≈ 30 tasks/s with
-- 5000-char details), which turns the hosted project read-only for everyone. BEFORE INSERT triggers count the
-- caller's writes of the last hour and raise `rate_limited` (P0001 → AppError.rateLimited) above the limit.
-- Being triggers, they also cover the direct `POST /rest/v1/tasks` allowed by the column INSERT grant.
--
-- - Only end users are limited (auth.uid() not NULL): migrations, the seed and service tasks are exempt.
-- - The window is inclusive (a write exactly one hour old still counts); older log rows are pruned.
-- - Limits live in private.settings (`quota_groups_per_hour`, `quota_tasks_per_hour`); a missing or invalid
--   value falls back to the default (20 groups, 200 tasks).
-- - The triggers are named to fire after the validation triggers (`groups_before_write`,
--   `tasks_before_insert`: BEFORE triggers fire in name order), and create_group / create_task check the
--   caller's rights and the input first: permission and validation errors keep their precedence.
-- - A refused write raises, so it rolls back its own log row: refused attempts are not counted.

insert into private.settings (key, value) values
  ('quota_groups_per_hour', '20'),
  ('quota_tasks_per_hour', '200');

create table private.write_log (
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null constraint write_log_kind check (kind in ('group', 'task')),
  created_at timestamptz not null default now()
);

create index write_log_user_kind_created_at_idx on private.write_log (user_id, kind, created_at);

alter table private.write_log enable row level security;
revoke all on table private.write_log from public, anon, authenticated;

-- Counts and logs one write of `p_kind` by the caller, or raises `rate_limited`.
create function private.enforce_write_quota(p_kind text, p_limit integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return; -- trusted context
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid) then
    return; -- stale JWT of a deleted account: the RPC or RLS refuses the write with its usual error
  end if;

  -- Serializes the caller's writes of this kind so that concurrent requests cannot exceed the limit.
  perform pg_advisory_xact_lock(hashtextextended('write_quota:' || p_kind || ':' || v_uid::text, 0));

  delete from private.write_log wl
  where wl.user_id = v_uid
    and wl.kind = p_kind
    and wl.created_at < now() - interval '1 hour';

  if (select count(*) from private.write_log wl where wl.user_id = v_uid and wl.kind = p_kind) >= p_limit then
    raise exception using errcode = 'P0001', message = 'rate_limited';
  end if;

  insert into private.write_log (user_id, kind) values (v_uid, p_kind);
end;
$$;

create function private.groups_quota_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.enforce_write_quota('group', private.setting_int('quota_groups_per_hour', 20));
  return new;
end;
$$;

create function private.tasks_quota_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.enforce_write_quota('task', private.setting_int('quota_tasks_per_hour', 200));
  return new;
end;
$$;

create trigger groups_quota_before_insert
  before insert on public.groups
  for each row execute function private.groups_quota_before_insert();

create trigger tasks_quota_before_insert
  before insert on public.tasks
  for each row execute function private.tasks_quota_before_insert();

revoke all on function private.enforce_write_quota(text, integer) from public, anon, authenticated;
revoke all on function private.groups_quota_before_insert() from public, anon, authenticated;
revoke all on function private.tasks_quota_before_insert() from public, anon, authenticated;
