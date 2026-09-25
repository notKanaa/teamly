-- v2 recurrence (docs/CONTRACTS-V2.md §3, §5, §6): rule JSON validation and check order, stored fields, the
-- next-due algorithm (the test vectors of §6), time zones and DST, repeat_month_day maintenance.
begin;
select plan(117);

-- Test helpers (created inside this transaction, rolled back at the end) ----------------------------
-- tests.as_user(name) = `set local role authenticated` + the JWT claims PostgREST would set;
-- tests.as_postgres() switches back; fixtures are created as postgres (auth.uid() is NULL).
create schema tests;
grant usage on schema tests to anon, authenticated;
create table tests.ids (name text primary key, id uuid not null);
create table tests.results (name text primary key, value jsonb);
grant select, insert on tests.ids, tests.results to anon, authenticated;
create function tests.id(p_name text) returns uuid language sql stable as $$
  select id from tests.ids where name = p_name
$$;
create function tests.create_user(p_name text, p_display_name text default null) returns uuid
language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', p_name || '@test.local', '',
          '{"provider":"email","providers":["email"]}', jsonb_build_object('display_name', coalesce(p_display_name, p_name)), now(), now());
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
create function tests.as_user(p_name text) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', tests.id(p_name), 'role', 'authenticated')::text, true);
end $$;
create function tests.as_postgres() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
end $$;
create function tests.create_group(p_name text, p_admin text, p_code text default null) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into public.groups (name, created_by) values (p_name, tests.id(p_admin)) returning id into v_id;
  insert into public.group_members (group_id, user_id, role) values (v_id, tests.id(p_admin), 'admin');
  insert into public.group_invites (group_id, code, created_by)
  values (v_id, coalesce(p_code, private.generate_invite_code()), tests.id(p_admin));
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
create function tests.add_member(p_group text, p_user text, p_role public.member_role default 'member',
                                 p_joined_at timestamptz default now()) returns void
language sql as $$
  insert into public.group_members (group_id, user_id, role, joined_at)
  values (tests.id(p_group), tests.id(p_user), p_role, p_joined_at);
$$;
-- -------------------------------------------------------------------------------------------------------

-- create_task in G with a rule (as the current user): 'ok' or the error message.
create function tests.create_with(p_rule text, p_due timestamptz default '2041-10-07 16:00+00') returns text
language plpgsql as $$
begin
  perform public.create_task(tests.id('G'), 'Règle', null, 'medium', p_due, '{}', p_rule::jsonb);
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
-- Creates a task named p_name in G (as the current user) and returns its id.
create function tests.new_task(p_name text, p_rule jsonb, p_due timestamptz) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  select t.id into v_id from public.create_task(tests.id('G'), p_name, null, 'medium', p_due, '{}', p_rule) t;
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
create function tests.task(p_name text) returns public.tasks language sql security definer as $$
  select * from public.tasks where id = tests.id(p_name)
$$;
create function tests.utc(p_value timestamptz) returns text language sql immutable as $$
  select to_char(p_value at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
$$;
-- The next due date of a vector (rule JSON as sent by the clients, stored repeat_month_day or NULL), in UTC ISO.
create function tests.next(p_rule jsonb, p_month_day integer, p_due timestamptz, p_now timestamptz) returns text
language sql stable as $$
  select tests.utc(private.next_due_at(r.r_freq, r.r_interval, r.r_weekdays, p_month_day, r.r_tz, p_due, p_now))
  from private.parse_recurrence(p_rule) r
$$;

select tests.create_user('alice');
select tests.create_user('bob');
select tests.create_user('outsider');
select tests.create_group('G', 'alice');
select tests.add_member('G', 'bob');

-- Rule JSON validation (§3, §5) -----------------------------------------------------------------------------------
select tests.as_user('bob');
select is(tests.create_with('[]'), 'invalid_recurrence', 'rule: an array is refused');
select is(tests.create_with('"daily"'), 'invalid_recurrence', 'rule: a string is refused');
select is(tests.create_with('{"tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: freq is required');
select is(tests.create_with('{"freq": "yearly", "tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: unknown freq');
select is(tests.create_with('{"freq": "Daily", "tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: freq is case sensitive');
select is(tests.create_with('{"freq": 1, "tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: freq must be a string');
select is(tests.create_with('{"freq": null, "tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: freq null');
select is(tests.create_with('{"freq": "daily", "tz": "Europe/Paris", "until": "2042-01-01"}'), 'invalid_recurrence',
  'rule: unknown keys are refused');
select is(tests.create_with('{"freq": "daily", "interval": 0, "tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: interval 0');
select is(tests.create_with('{"freq": "daily", "interval": 53, "tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: interval 53');
select is(tests.create_with('{"freq": "daily", "interval": 1.5, "tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: interval 1.5');
select is(tests.create_with('{"freq": "daily", "interval": "2", "tz": "Europe/Paris"}'), 'invalid_recurrence',
  'rule: interval must be a number');
select is(tests.create_with('{"freq": "daily", "interval": true, "tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: interval true');
select is(tests.create_with('{"freq": "daily", "interval": 52, "tz": "Europe/Paris"}'), 'ok', 'rule: interval 52 is accepted');
select is(tests.create_with('{"freq": "daily", "weekdays": [1], "tz": "Europe/Paris"}'), 'invalid_recurrence',
  'rule: weekdays on a daily rule');
select is(tests.create_with('{"freq": "monthly", "weekdays": [1], "tz": "Europe/Paris"}'), 'invalid_recurrence',
  'rule: weekdays on a monthly rule');
select is(tests.create_with('{"freq": "weekly", "weekdays": [], "tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: empty weekdays');
select is(tests.create_with('{"freq": "weekly", "weekdays": [0], "tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: weekday 0');
select is(tests.create_with('{"freq": "weekly", "weekdays": [8], "tz": "Europe/Paris"}'), 'invalid_recurrence', 'rule: weekday 8');
select is(tests.create_with('{"freq": "weekly", "weekdays": [1, 1], "tz": "Europe/Paris"}'), 'invalid_recurrence',
  'rule: duplicate weekdays');
select is(tests.create_with('{"freq": "weekly", "weekdays": ["1"], "tz": "Europe/Paris"}'), 'invalid_recurrence',
  'rule: weekdays must be numbers');
select is(tests.create_with('{"freq": "weekly", "weekdays": [2.5], "tz": "Europe/Paris"}'), 'invalid_recurrence',
  'rule: weekdays must be integers');
select is(tests.create_with('{"freq": "weekly", "weekdays": 1, "tz": "Europe/Paris"}'), 'invalid_recurrence',
  'rule: weekdays must be an array');
select is(tests.create_with('{"freq": "weekly", "weekdays": [null], "tz": "Europe/Paris"}'), 'invalid_recurrence',
  'rule: a NULL weekday');
select is(tests.create_with('{"freq": "weekly", "weekdays": [1, 2, 3, 4, 5, 6, 7, 1], "tz": "Europe/Paris"}'), 'invalid_recurrence',
  'rule: more than 7 weekdays');
select is(tests.create_with('{"freq": "daily"}'), 'invalid_recurrence', 'rule: tz is required');
select is(tests.create_with('{"freq": "daily", "tz": null}'), 'invalid_recurrence', 'rule: tz null');
select is(tests.create_with('{"freq": "daily", "tz": 1}'), 'invalid_recurrence', 'rule: tz must be a string');
select is(tests.create_with('{"freq": "daily", "tz": "Europe/Pariss"}'), 'invalid_recurrence', 'rule: unknown tz');
select is(tests.create_with('{"freq": "daily", "tz": "europe/paris"}'), 'invalid_recurrence', 'rule: tz is case sensitive');
select is(tests.create_with('{"freq": "daily", "tz": "posix/Europe/Paris"}'), 'invalid_recurrence', 'rule: posix/ copies are refused');
select is(tests.create_with('{"freq": "daily", "tz": "Factory"}'), 'invalid_recurrence', 'rule: the Factory zone is refused');
select is(tests.create_with('{"freq": "daily", "tz": "UTC+3"}'), 'invalid_recurrence', 'rule: POSIX offsets are refused');
select is(tests.create_with('{"freq": "daily", "tz": "CEST"}'), 'invalid_recurrence', 'rule: abbreviations are refused');
select is(tests.create_with('{"freq": "daily", "tz": "America/Argentina/Buenos_Aires"}'), 'ok', 'rule: three-part zone names');
select is(tests.create_with('{"freq": "daily", "tz": "UTC"}'), 'ok', 'rule: UTC');

-- Check order (§3): permission → title → details → due date → recurrence (shape, then due date) → rotation → assignees
select tests.as_user('outsider');
select throws_ok(format($$ select public.create_task(%L, '', null, 'medium', null, '{}', '[]') $$, tests.id('G')),
  '42501', 'forbidden', 'order: permission first');
select tests.as_user('bob');
select throws_ok(format($$ select public.create_task(%L, '', null, 'medium', null, '{}', '[]') $$, tests.id('G')),
  'P0001', 'invalid_title', 'order: title before recurrence');
select throws_ok(format($$ select public.create_task(%L, 'T', %L, 'medium', null, '{}', '[]') $$, tests.id('G'), repeat('d', 5001)),
  'P0001', 'invalid_details', 'order: details before recurrence');
select throws_ok(format($$ select public.create_task(%L, 'T', null, 'medium', 'infinity', '{}', '[]') $$, tests.id('G')),
  'P0001', 'invalid_due_at', 'order: due date before recurrence');
select throws_ok(format($$ select public.create_task(%L, 'T', null, 'medium', null, '{}', '{"freq": "hourly"}') $$, tests.id('G')),
  'P0001', 'invalid_recurrence', 'order: the rule shape before the due-date requirement');
select throws_ok(format($$ select public.create_task(%L, 'T', null, 'medium', null, '{}', '{"freq": "daily", "tz": "UTC"}') $$, tests.id('G')),
  'P0001', 'recurrence_requires_due_date', 'a recurring task needs a due date');
select throws_ok(format($$ select public.create_task(%L, 'T', null, 'medium', '2041-10-07 16:00+00', array[%L]::uuid[], '[]') $$,
    tests.id('G'), tests.id('outsider')),
  'P0001', 'invalid_recurrence', 'order: recurrence before assignees');

-- Stored fields (§2, §5) -------------------------------------------------------------------------------------------
select tests.new_task('W', '{"freq": "weekly", "interval": 2.0, "weekdays": [5, 1, 3], "tz": "Europe/Paris"}', '2041-10-09 16:00+00');
select results_eq(
  $$ select repeat_freq, repeat_interval, repeat_weekdays, repeat_month_day, repeat_tz, series_id = id, next_occurrence_id,
            rotation, turn_user_id
     from public.tasks where id = tests.id('W') $$,
  $$ values ('weekly', 2::smallint, '{1,3,5}'::smallint[], null::smallint, 'Europe/Paris', true, null::uuid, null::uuid[], null::uuid) $$,
  'weekly rule: interval 2.0 → 2, weekdays sorted, series_id = id');
select tests.new_task('D', '{"freq": "daily", "interval": null, "weekdays": null, "tz": "UTC"}', '2041-10-09 16:00+00');
select results_eq(
  $$ select repeat_freq, repeat_interval, repeat_weekdays from public.tasks where id = tests.id('D') $$,
  $$ values ('daily', 1::smallint, null::smallint[]) $$,
  'JSON null values count as absent keys (interval 1, no weekdays)');
select tests.new_task('Tokyo', '{"freq": "monthly", "tz": "Asia/Tokyo"}', '2041-01-30 15:30+00');
select is((tests.task('Tokyo')).repeat_month_day, 31::smallint,
  'monthly: repeat_month_day is the local day of the due date (Jan 31 00:30 in Tokyo, Jan 30 in UTC)');
select tests.new_task('Plain', '{}', '2041-10-09 16:00+00');
select results_eq(
  $$ select repeat_freq, repeat_interval, repeat_tz, series_id from public.tasks where id = tests.id('Plain') $$,
  $$ values (null::text, 1::smallint, null::text, null::uuid) $$,
  'create_task with ''{}'' creates a plain task');
select is((public.create_task(tests.id('G'), 'v1')).repeat_freq, null, 'a v1 create_task call creates a plain task');

-- Test vectors (§6): the same table is used by the Swift and Kotlin ports ------------------------------------------
-- Columns: rule JSON, stored repeat_month_day (monthly; NULL = the local day of due_at), due_at, now → next due_at.
select tests.as_postgres();
select is(tests.next('{"freq":"daily","tz":"Europe/Paris"}', null, '2026-09-24T18:00:00Z', '2026-09-24T19:00:00Z'),
  '2026-09-25T18:00:00Z', 'vector 1: daily');
select is(tests.next('{"freq":"daily","tz":"Europe/Paris"}', null, '2026-09-26T18:00:00Z', '2026-09-24T10:00:00Z'),
  '2026-09-27T18:00:00Z', 'vector 2: daily, completed early (the same slot is not repeated)');
select is(tests.next('{"freq":"daily","interval":3,"tz":"Europe/Paris"}', null, '2026-09-24T06:00:00Z', '2026-09-24T07:00:00Z'),
  '2026-09-27T06:00:00Z', 'vector 3: every 3 days');
select is(tests.next('{"freq":"daily","tz":"Europe/Paris"}', null, '2026-09-20T06:00:00Z', '2026-09-24T12:00:00Z'),
  '2026-09-25T06:00:00Z', 'vector 4: daily, missed occurrences skipped');
select is(tests.next('{"freq":"daily","tz":"Europe/Paris"}', null, '2026-09-22T06:00:00Z', '2026-09-24T06:00:00Z'),
  '2026-09-25T06:00:00Z', 'vector 5: an occurrence due exactly now is skipped (<=)');
select is(tests.next('{"freq":"weekly","tz":"Europe/Paris"}', null, '2026-09-21T07:00:00Z', '2026-09-21T08:00:00Z'),
  '2026-09-28T07:00:00Z', 'vector 6: weekly, the due date''s weekday');
select is(tests.next('{"freq":"weekly","interval":2,"tz":"Europe/Paris"}', null, '2026-09-21T07:00:00Z', '2026-09-21T08:00:00Z'),
  '2026-10-05T07:00:00Z', 'vector 7: every 2 weeks');
select is(tests.next('{"freq":"weekly","weekdays":[1,3,5],"tz":"Europe/Paris"}', null, '2026-09-23T16:00:00Z', '2026-09-23T17:00:00Z'),
  '2026-09-25T16:00:00Z', 'vector 8: Mon/Wed/Fri, from a Wednesday');
select is(tests.next('{"freq":"weekly","weekdays":[1,3,5],"tz":"Europe/Paris"}', null, '2026-09-25T16:00:00Z', '2026-09-25T17:00:00Z'),
  '2026-09-28T16:00:00Z', 'vector 9: Mon/Wed/Fri, from a Friday');
select is(tests.next('{"freq":"weekly","interval":2,"weekdays":[2,4],"tz":"Europe/Paris"}', null, '2026-09-22T16:00:00Z', '2026-09-22T17:00:00Z'),
  '2026-09-24T16:00:00Z', 'vector 10: Tue/Thu every 2 weeks, from a Tuesday (same week)');
select is(tests.next('{"freq":"weekly","interval":2,"weekdays":[2,4],"tz":"Europe/Paris"}', null, '2026-09-24T16:00:00Z', '2026-09-24T17:00:00Z'),
  '2026-10-06T16:00:00Z', 'vector 11: Tue/Thu every 2 weeks, from a Thursday (2 weeks later)');
select is(tests.next('{"freq":"weekly","interval":2,"weekdays":[1,3],"tz":"Europe/Paris"}', null, '2026-09-27T08:00:00Z', '2026-09-27T09:00:00Z'),
  '2026-10-05T08:00:00Z', 'vector 12: Mon/Wed every 2 weeks, due on a Sunday (the week starts on Monday)');
select is(tests.next('{"freq":"weekly","weekdays":[1,3,5],"tz":"Europe/Paris"}', null, '2026-09-14T16:00:00Z', '2026-09-24T12:00:00Z'),
  '2026-09-25T16:00:00Z', 'vector 13: Mon/Wed/Fri, missed occurrences skipped');
select is(tests.next('{"freq":"monthly","tz":"Europe/Paris"}', null, '2026-01-31T17:00:00Z', '2026-01-31T18:00:00Z'),
  '2026-02-28T17:00:00Z', 'vector 14: monthly on the 31st → February 28');
select is(tests.next('{"freq":"monthly","tz":"Europe/Paris"}', 31, '2026-02-28T17:00:00Z', '2026-02-28T18:00:00Z'),
  '2026-03-31T16:00:00Z', 'vector 15: … → March 31 (month day 31 kept, no drift; after the DST change)');
select is(tests.next('{"freq":"monthly","tz":"Europe/Paris"}', 31, '2026-03-31T16:00:00Z', '2026-03-31T17:00:00Z'),
  '2026-04-30T16:00:00Z', 'vector 16: … → April 30');
select is(tests.next('{"freq":"monthly","tz":"Europe/Paris"}', 31, '2026-04-30T16:00:00Z', '2026-04-30T17:00:00Z'),
  '2026-05-31T16:00:00Z', 'vector 17: … → May 31');
select is(tests.next('{"freq":"monthly","tz":"Europe/Paris"}', 31, '2028-01-31T17:00:00Z', '2028-01-31T18:00:00Z'),
  '2028-02-29T17:00:00Z', 'vector 18: monthly on the 31st, leap year → February 29');
select is(tests.next('{"freq":"monthly","interval":3,"tz":"Europe/Paris"}', null, '2026-01-15T08:00:00Z', '2026-01-15T09:00:00Z'),
  '2026-04-15T07:00:00Z', 'vector 19: every 3 months');
select is(tests.next('{"freq":"monthly","tz":"Europe/Paris"}', null, '2026-05-15T07:00:00Z', '2026-09-24T12:00:00Z'),
  '2026-10-15T07:00:00Z', 'vector 20: monthly, missed occurrences skipped');
select is(tests.next('{"freq":"daily","tz":"Europe/Paris"}', null, '2026-03-28T07:00:00Z', '2026-03-28T08:00:00Z'),
  '2026-03-29T06:00:00Z', 'vector 21: daily at 08:00 across the Europe/Paris spring DST change');
select is(tests.next('{"freq":"weekly","tz":"Europe/Paris"}', null, '2026-10-19T16:30:00Z', '2026-10-19T17:00:00Z'),
  '2026-10-26T17:30:00Z', 'vector 22: weekly at 18:30 across the Europe/Paris autumn DST change');
select is(tests.next('{"freq":"daily","tz":"America/New_York"}', null, '2026-03-07T14:00:00Z', '2026-03-07T15:00:00Z'),
  '2026-03-08T13:00:00Z', 'vector 23: daily at 09:00 across the America/New_York DST change');
select is(tests.next('{"freq":"monthly","tz":"Asia/Tokyo"}', null, '2026-01-30T15:30:00Z', '2026-01-30T16:00:00Z'),
  '2026-02-27T15:30:00Z', 'vector 24: monthly, local date ≠ UTC date (Jan 31 00:30 in Tokyo → Feb 28 00:30)');
select is(tests.next('{"freq":"weekly","weekdays":[7],"tz":"UTC"}', null, '2026-09-27T20:00:00Z', '2026-09-27T21:00:00Z'),
  '2026-10-04T20:00:00Z', 'vector 25: weekly on Sunday only');
select is(tests.next('{"freq":"daily","tz":"Europe/Paris"}', null, '1990-01-01T08:00:00Z', '2026-09-24T12:00:00Z'),
  '2017-05-19T07:00:00Z', 'vector 26: at most 10 000 steps (the result may stay in the past)');
select is(tests.next('{"freq":"monthly","interval":12,"tz":"Europe/Paris"}', 29, '2027-02-28T09:00:00Z', '2027-02-28T10:00:00Z'),
  '2028-02-29T09:00:00Z', 'vector 27: yearly on February 29 (month day 29, every 12 months)');

-- The algorithm does not depend on the session time zone (PostgREST clients can set it with Prefer: timezone).
create table tests.vectors (n integer, rule jsonb, month_day integer, due timestamptz, now_at timestamptz);
insert into tests.vectors values
  (4, '{"freq":"daily","tz":"Europe/Paris"}', null, '2026-09-20T06:00:00Z', '2026-09-24T12:00:00Z'),
  (11, '{"freq":"weekly","interval":2,"weekdays":[2,4],"tz":"Europe/Paris"}', null, '2026-09-24T16:00:00Z', '2026-09-24T17:00:00Z'),
  (15, '{"freq":"monthly","tz":"Europe/Paris"}', 31, '2026-02-28T17:00:00Z', '2026-02-28T18:00:00Z'),
  (21, '{"freq":"daily","tz":"Europe/Paris"}', null, '2026-03-28T07:00:00Z', '2026-03-28T08:00:00Z'),
  (24, '{"freq":"monthly","tz":"Asia/Tokyo"}', null, '2026-01-30T15:30:00Z', '2026-01-30T16:00:00Z');
create function tests.vector_results() returns table (n integer, next text) language sql stable as $$
  select v.n, tests.next(v.rule, v.month_day, v.due, v.now_at) from tests.vectors v order by v.n
$$;
set local timezone = 'Pacific/Kiritimati';
select results_eq($$ select * from tests.vector_results() $$,
  $$ values (4, '2026-09-25T06:00:00Z'), (11, '2026-10-06T16:00:00Z'), (15, '2026-03-31T16:00:00Z'),
            (21, '2026-03-29T06:00:00Z'), (24, '2026-02-27T15:30:00Z') $$,
  'same results with the session in Pacific/Kiritimati (UTC+14)');
set local timezone = 'America/Los_Angeles';
select results_eq($$ select * from tests.vector_results() $$,
  $$ values (4, '2026-09-25T06:00:00Z'), (11, '2026-10-06T16:00:00Z'), (15, '2026-03-31T16:00:00Z'),
            (21, '2026-03-29T06:00:00Z'), (24, '2026-02-27T15:30:00Z') $$,
  'same results with the session in America/Los_Angeles');
set local timezone = 'UTC';

-- DST (§6): PostgreSQL's rules for local times that do not exist or are ambiguous (the scenarios avoid 02:00–03:00).
select is(tests.next('{"freq":"daily","tz":"Europe/Paris"}', null, '2026-03-28T01:30:00Z', '2026-03-28T02:00:00Z'),
  '2026-03-29T01:30:00Z', 'DST: 02:30 on the spring-forward day does not exist and reads as 03:30 CEST (01:30Z)');
select is(tests.next('{"freq":"daily","tz":"Europe/Paris"}', null, '2026-10-24T00:30:00Z', '2026-10-24T01:00:00Z'),
  '2026-10-25T01:30:00Z', 'DST: 02:30 on the fall-back day is ambiguous and reads as 02:30 CET (01:30Z, the later instant)');

-- Spawned due dates use the stored rule (a real completion: now() is the transaction time) -------------------------------
-- A daily task overdue by three days: the next occurrence is the first slot after now(), same local time.
select tests.as_user('bob');
select tests.new_task('Overdue', '{"freq": "daily", "tz": "Europe/Paris"}',
  ((((now() at time zone 'Europe/Paris')::date - 3) + time '07:15') at time zone 'Europe/Paris'));
select public.set_task_status(tests.id('Overdue'), 'done');
select tests.as_postgres();
select results_eq(
  $$ select t.due_at > now(), t.due_at <= now() + interval '25 hours', (t.due_at at time zone 'Europe/Paris')::time
     from public.tasks t where t.id = (tests.task('Overdue')).next_occurrence_id $$,
  $$ values (true, true, '07:15'::time) $$,
  'an overdue daily task: the next occurrence is the first slot after now(), at the same local time');

-- repeat_month_day (§5): kept on a clamped occurrence, recomputed when the local due date or tz changes ----------------
select tests.as_user('bob');
select tests.new_task('M31', '{"freq": "monthly", "tz": "Europe/Paris"}', '2041-01-31 17:00+00');
select is((tests.task('M31')).repeat_month_day, 31::smallint, 'monthly on January 31: month day 31');
select public.set_task_status(tests.id('M31'), 'done');
insert into tests.ids select 'Feb', (tests.task('M31')).next_occurrence_id;
select results_eq(
  $$ select tests.utc(due_at), repeat_month_day from public.tasks where id = tests.id('Feb') $$,
  $$ values ('2041-02-28T17:00:00Z', 31::smallint) $$,
  'the spawned occurrence is due February 28 and keeps month day 31');
select public.update_task(tests.id('Feb'), 'M31', null, 'medium', (tests.task('Feb')).due_at, null);
select is((tests.task('Feb')).repeat_month_day, 31::smallint, 'a v1 edit with the same due date keeps month day 31');
select public.update_task(tests.id('Feb'), 'M31', null, 'medium', '2041-02-28 19:00+00', null);
select is((tests.task('Feb')).repeat_month_day, 31::smallint, 'a new time on the same local date keeps month day 31');
select public.update_task(tests.id('Feb'), 'M31', null, 'medium', (tests.task('Feb')).due_at, null,
  '{"freq": "monthly", "interval": 2, "tz": "Europe/Paris"}');
select results_eq(
  $$ select repeat_interval, repeat_month_day from public.tasks where id = tests.id('Feb') $$,
  $$ values (2::smallint, 31::smallint) $$,
  'a new interval keeps month day 31');
select public.update_task(tests.id('Feb'), 'M31', null, 'medium', (tests.task('Feb')).due_at, null,
  '{"freq": "monthly", "interval": 2, "tz": "Europe/Paris"}');
select is((tests.task('Feb')).repeat_month_day, 31::smallint, 'the same rule sent again keeps month day 31');
select public.update_task(tests.id('Feb'), 'M31', null, 'medium', (tests.task('Feb')).due_at, null,
  '{"freq": "monthly", "interval": 2, "tz": "Asia/Tokyo"}');
select is((tests.task('Feb')).repeat_month_day, 1::smallint, 'a new tz recomputes the month day (Mar 1 04:00 in Tokyo)');
select public.update_task(tests.id('Feb'), 'M31', null, 'medium', (tests.task('Feb')).due_at, null,
  '{"freq": "monthly", "tz": "Europe/Paris"}');
select is((tests.task('Feb')).repeat_month_day, 28::smallint, 'back to Europe/Paris: the local day, 28');
select public.update_task(tests.id('Feb'), 'M31', null, 'medium', '2041-02-26 17:00+00', null);
select is((tests.task('Feb')).repeat_month_day, 26::smallint, 'a new local due date recomputes the month day');
select public.update_task(tests.id('Feb'), 'M31', null, 'medium', '2041-02-26 17:00+00', null,
  '{"freq": "weekly", "tz": "Europe/Paris"}');
select results_eq(
  $$ select repeat_freq, repeat_month_day, repeat_weekdays from public.tasks where id = tests.id('Feb') $$,
  $$ values ('weekly', null::smallint, null::smallint[]) $$,
  'weekly: no month day');
select public.update_task(tests.id('Feb'), 'M31', null, 'medium', '2041-02-26 17:00+00', null,
  '{"freq": "monthly", "tz": "Europe/Paris"}');
select is((tests.task('Feb')).repeat_month_day, 26::smallint, 'becoming monthly sets the month day');

-- update_task (§5): NULL = unchanged, '{}' = none, a rule; v1 edits keep the rule -------------------------------------
select tests.new_task('U', '{"freq": "weekly", "weekdays": [2], "tz": "Europe/Paris"}', '2041-10-08 16:00+00');
select public.update_task(tests.id('U'), 'U2', 'Détails', 'high', '2041-10-08 16:00+00', '{}');
select results_eq(
  $$ select title, repeat_freq, repeat_weekdays, repeat_tz, series_id = id from public.tasks where id = tests.id('U') $$,
  $$ values ('U2', 'weekly', '{2}'::smallint[], 'Europe/Paris', true) $$,
  'a v1 update_task call keeps the rule');
-- (A v1 edit that clears the due date turns the task into a plain task: 17_v2_turn_handover_signals.test.sql.)
select throws_ok(format($$ select public.update_task(%L, 'U2', null, 'high', null, null, '{"freq": "weekly", "weekdays": [2], "tz": "Europe/Paris"}') $$,
    tests.id('U')),
  'P0001', 'recurrence_requires_due_date', 'an explicit rule cannot go with a NULL due date');
select throws_ok(format($$ update public.tasks set due_at = null where id = %L $$, tests.id('U')),
  'P0001', 'recurrence_requires_due_date', 'nor can a direct PATCH clear the due date of a recurring task');
select throws_ok(format($$ update public.tasks set repeat_freq = 'daily' where id = %L $$, tests.id('U')),
  '42501', 'permission denied for table tasks', 'the rule cannot be written directly');
select throws_ok(format($$ select public.update_task(%L, '', null, 'high', '2041-10-08 16:00+00', null, '[]') $$, tests.id('U')),
  'P0001', 'invalid_title', 'update_task: title before recurrence');
select throws_ok(format($$ select public.update_task(%L, 'U2', null, 'high', null, null, '{"freq": "daily"}') $$, tests.id('U')),
  'P0001', 'invalid_recurrence', 'update_task: the rule shape before the due-date requirement');
select throws_ok(format($$ select public.update_task(%L, 'U2', null, 'high', '2041-10-08 16:00+00', array[%L]::uuid[], '{"freq": "daily"}') $$,
    tests.id('U'), tests.id('outsider')),
  'P0001', 'invalid_recurrence', 'update_task: recurrence before assignees');
select lives_ok(format($$ select public.update_task(%L, 'U2', null, 'high', null, null, '{}') $$, tests.id('U')),
  'clearing the rule and the due date at once');
select results_eq(
  $$ select repeat_freq, repeat_interval, repeat_weekdays, repeat_tz, repeat_month_day, series_id, due_at
     from public.tasks where id = tests.id('U') $$,
  $$ values (null::text, 1::smallint, null::smallint[], null::text, null::smallint, null::uuid, null::timestamptz) $$,
  '''{}'' makes the occurrence a plain task');
select throws_ok(format($$ select public.update_task(%L, 'U2', null, 'high', null, null, '{"freq": "daily", "tz": "UTC"}') $$, tests.id('U')),
  'P0001', 'recurrence_requires_due_date', 'a rule on a task without due date');
select public.update_task(tests.id('U'), 'U2', null, 'high', '2041-10-09 16:00+00', null, '{"freq": "daily", "interval": 2, "tz": "UTC"}');
select results_eq(
  $$ select repeat_freq, repeat_interval, series_id = id from public.tasks where id = tests.id('U') $$,
  $$ values ('daily', 2::smallint, true) $$,
  'a plain task gets a rule: a new series');
select public.update_task(tests.id('U'), 'U2', null, 'high', '2041-10-09 16:00+00', null, 'null'::jsonb);
select is((tests.task('U')).repeat_interval, 2::smallint, 'a JSON null rule means unchanged');

-- Editing the rule never moves updated_at (§2) nor spawns.
select tests.as_postgres();
update public.tasks set updated_at = '2000-01-01' where id = tests.id('U');
select tests.as_user('bob');
select public.update_task(tests.id('U'), 'U2', null, 'high', '2041-10-09 16:00+00', null, '{"freq": "weekly", "tz": "UTC"}');
select is((tests.task('U')).updated_at, '2000-01-01'::timestamptz, 'a rule-only edit keeps updated_at');
select is((select count(*)::int from public.tasks where series_id = tests.id('U')), 1, 'editing the rule spawns nothing');

-- Constraints are the last line of defense ------------------------------------------------------------------------------
select tests.as_postgres();
alter table public.tasks disable trigger tasks_before_update_v2;
select throws_ok(format($$ update public.tasks set repeat_weekdays = '{3,1}' where id = %L $$, tests.id('W')),
  '23514', null, 'tasks_repeat_weekdays_check: ascending');
select throws_ok(format($$ update public.tasks set repeat_weekdays = '{1,8}' where id = %L $$, tests.id('W')),
  '23514', null, 'tasks_repeat_weekdays_check: 1…7');
select throws_ok(format($$ update public.tasks set repeat_weekdays = '{1,1}' where id = %L $$, tests.id('W')),
  '23514', null, 'tasks_repeat_weekdays_check: distinct');
select throws_ok(format($$ update public.tasks set repeat_weekdays = '{}' where id = %L $$, tests.id('W')),
  '23514', null, 'tasks_repeat_weekdays_check: not empty');
select throws_ok(format($$ update public.tasks set repeat_tz = null where id = %L $$, tests.id('W')),
  '23514', null, 'tasks_repeat_tz_iff_repeating');
select throws_ok(format($$ update public.tasks set series_id = null where id = %L $$, tests.id('W')),
  '23514', null, 'tasks_series_id_iff_repeating');
select throws_ok(format($$ update public.tasks set repeat_month_day = 5 where id = %L $$, tests.id('W')),
  '23514', null, 'tasks_repeat_month_day_iff_monthly');
select throws_ok(format($$ update public.tasks set due_at = null where id = %L $$, tests.id('W')),
  '23514', null, 'tasks_repeat_needs_due_at');
select throws_ok(format($$ update public.tasks set repeat_interval = 0 where id = %L $$, tests.id('W')),
  '23514', null, 'tasks_repeat_interval_range');
select throws_ok(format($$ update public.tasks set rotation = array[%L]::uuid[] where id = %L $$, tests.id('bob'), tests.id('W')),
  '23514', null, 'tasks_rotation_check: at least 2 users');
select throws_ok(format($$ update public.tasks set turn_user_id = %L where id = %L $$, tests.id('bob'), tests.id('W')),
  '23514', null, 'tasks_turn_user_in_rotation');
select throws_ok(format($$ update public.tasks set repeat_freq = null, repeat_tz = null, series_id = null, repeat_weekdays = null,
    repeat_interval = 3 where id = %L $$, tests.id('W')),
  '23514', null, 'tasks_repeat_interval_default: a plain task has interval 1');
alter table public.tasks enable trigger tasks_before_update_v2;

select * from finish();
rollback;
