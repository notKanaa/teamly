-- v3 « Mode absent » (docs/CONTRACTS-V3.md §2): set_away validation, the profile columns, the member_away announcement,
-- the handover of the caller's turns in the range, clear_away, and the absence skip whenever the server chooses a turn
-- holder (create_task with a rotation, the spawn, the handover of a departed turn holder); update_task keeps its v2 rule.
begin;
select plan(55);

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
create function tests.as_anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
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

create function tests.name(p_id uuid) returns text language sql stable as $$
  select coalesce((select i.name from tests.ids i where i.id = p_id order by i.name limit 1), 'null')
$$;
create function tests.task(p_name text) returns public.tasks language sql security definer as $$
  select * from public.tasks where id = tests.id(p_name)
$$;
create function tests.assignees(p_task text) returns text language sql security definer as $$
  select coalesce(string_agg(tests.name(ta.user_id) || '<' || tests.name(ta.assigned_by) || '>', ',' order by tests.name(ta.user_id)), '')
  from public.task_assignees ta where ta.task_id = tests.id(p_task)
$$;
create function tests.turn(p_task text) returns text language sql security definer as $$
  select tests.name((tests.task(p_task)).turn_user_id)
$$;
create function tests.ids_of(p_names text[]) returns uuid[] language sql stable as $$
  select array(select tests.id(n) from unnest(p_names) with ordinality as x (n, o) order by o)
$$;
-- A rotating task of p_group (trusted fixture): p_turn's turn, assigned by the creator.
create function tests.rotating_task(p_name text, p_group text, p_creator text, p_rotation text[], p_turn text,
                                    p_due timestamptz default '2041-03-04 07:00+00', p_status public.task_status default 'todo',
                                    p_freq text default 'weekly') returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into public.tasks (group_id, title, created_by, status, due_at, repeat_freq, repeat_tz, rotation, turn_user_id)
  values (tests.id(p_group), p_name, tests.id(p_creator), p_status, p_due, p_freq, 'Europe/Paris',
          tests.ids_of(p_rotation), tests.id(p_turn))
  returning id into v_id;
  insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
  values (v_id, tests.id(p_group), tests.id(p_turn), tests.id(p_creator));
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
-- Trusted fixture: p_user is away from p_from to p_until.
create function tests.away(p_user text, p_from date, p_until date) returns void language sql as $$
  update public.profiles set away_from = p_from, away_until = p_until where id = tests.id(p_user);
$$;
create function tests.mark(p_name text) returns void language sql security definer as $$
  insert into tests.results values (p_name, to_jsonb((select coalesce(max(id), 0) from public.group_activity)));
$$;
create function tests.since(p_mark text) returns bigint language sql stable as $$
  select (r.value #>> '{}')::bigint from tests.results r where r.name = p_mark
$$;
-- Requests queued by pg_net in this transaction.
create function tests.pushes() returns table (body jsonb) language sql security definer as $$
  select convert_from(q.body, 'UTF8')::jsonb
  from net.http_request_queue q
  where q.id > (select (r.value #>> '{}')::bigint from tests.results r where r.name = 'queue start')
  order by q.id
$$;
-- Every UPDATE of groups (what Realtime would broadcast).
create table tests.events (id uuid);
create function tests.log_event() returns trigger language plpgsql security definer as $$
begin
  insert into tests.events values (new.id);
  return null;
end $$;
create trigger log_groups_update after update on public.groups for each row execute function tests.log_event();
create function tests.events_for(p_name text) returns integer language sql security definer as $$
  select count(*)::int from tests.events where id = tests.id(p_name)
$$;
create function tests.rewind() returns void language plpgsql security definer as $$
begin
  update public.groups set last_activity_at = '2000-01-01' where id in (select id from tests.ids);
  delete from tests.events where true;
end $$;

select tests.create_user(u) from unnest(array['admin', 'a1', 'a2', 'a3', 'a4', 'outsider', 'admin2', 'b1', 'b2', 'b3', 'b4']) as u;
select tests.create_group('G', 'admin');
select tests.add_member('G', u) from unnest(array['a1', 'a2', 'a3', 'a4']) as u;
select tests.create_group('H', 'a1');
select tests.add_member('H', 'admin');
select tests.create_group('Other', 'outsider');
insert into tests.results values ('today', to_jsonb((now() at time zone 'UTC')::date));
create function tests.today() returns date language sql stable as $$
  select (value #>> '{}')::date from tests.results where name = 'today'
$$;

-- set_away: validation (§2) --------------------------------------------------------------------------------------------------
select tests.as_user('a4');
select throws_ok(format($$ select public.set_away(%L, %L) $$, tests.today() + 2, tests.today() + 1),
  'P0001', 'invalid_away', 'p_from after p_until');
select throws_ok(format($$ select public.set_away(%L, %L) $$, tests.today() - 5, tests.today() - 2),
  'P0001', 'invalid_away', 'p_until before yesterday (UTC)');
select lives_ok(format($$ select public.set_away(%L, %L, false) $$, tests.today() - 5, tests.today() - 1),
  'p_until = yesterday (UTC) is accepted');
select lives_ok(format($$ select public.set_away(%L, %L, false) $$, tests.today(), tests.today() + 365),
  '366 days, both ends included, are accepted');
select throws_ok(format($$ select public.set_away(%L, %L) $$, tests.today(), tests.today() + 366),
  'P0001', 'invalid_away', '367 days are refused');
select throws_ok(format($$ select public.set_away(null, %L) $$, tests.today()), 'P0001', 'invalid_away', 'a NULL p_from');
select throws_ok(format($$ select public.set_away(%L, null) $$, tests.today()), 'P0001', 'invalid_away', 'a NULL p_until');
select lives_ok(format($$ select public.set_away(%L, %L, false) $$, tests.today(), tests.today()), 'a single day');
select tests.as_postgres();
select throws_ok(format($$ select public.set_away(%L, %L) $$, tests.today(), tests.today()), 'P0001', 'not_authenticated',
  'no JWT: not_authenticated');
select tests.as_anon();
select throws_ok($$ select public.clear_away() $$, '42501', 'permission denied for function clear_away', 'anon cannot call clear_away');
select tests.as_postgres();
select tests.away('a4', null, null);

-- set_away: profile, announcement, signal, handover ---------------------------------------------------------------------------
-- a2 is away on 2041-03-04 only (trusted fixture).
select tests.away('a2', '2041-03-04', '2041-03-04');
select tests.rotating_task('R1', 'G', 'admin', array['a1', 'a2', 'a3'], 'a1', '2041-03-05 07:00+00');
select tests.rotating_task('R2', 'G', 'admin', array['a1', 'a2', 'a3'], 'a1', '2041-04-04 07:00+00');
select tests.rotating_task('R3', 'G', 'admin', array['a1', 'a2', 'a3'], 'a1', '2041-03-05 07:00+00', 'done');
select tests.rotating_task('R4', 'G', 'admin', array['a2', 'a1'], 'a2', '2041-03-05 07:00+00');
select tests.rotating_task('R5', 'G', 'admin', array['a1', 'a2', 'a3'], 'a1', '2041-03-04 07:00+00');
select tests.rotating_task('R6', 'G', 'admin', array['a1', 'a2'], 'a1', '2041-03-04 07:00+00');
-- Local dates in Europe/Paris: 2041-03-10 23:30Z is March 11 (out of range), 2041-02-28 23:30Z is March 1 (in range).
select tests.rotating_task('R7', 'G', 'admin', array['a1', 'a3'], 'a1', '2041-03-10 23:30+00');
select tests.rotating_task('R8', 'G', 'admin', array['a1', 'a3'], 'a1', '2041-02-28 23:30+00');
insert into public.push_subscriptions (user_id, topic) values (tests.id('a2'), 'equipe-aaaaaaaaaaaaaaaaaaaaaaaa');
update private.settings set value = 'https://ntfy.example.test/' where key = 'ntfy_base_url';
insert into tests.results values ('queue start', to_jsonb((select coalesce(max(q.id), 0) from net.http_request_queue q)));
select tests.rewind();
select tests.mark('away');

select tests.as_user('a1');
select results_eq(
  $$ select away_from, away_until, display_name from public.set_away('2041-03-01', '2041-03-10') $$,
  $$ values ('2041-03-01'::date, '2041-03-10'::date, 'a1') $$,
  'set_away returns the caller''s profile with the range');
select tests.as_postgres();
select results_eq(
  $$ select a.group_id, a.kind, a.actor_id, a.subject_id, a.starts_on, a.ends_on, a.task_id from public.group_activity a
     where a.id > tests.since('away') and a.kind = 'member_away' order by a.id $$,
  $$ select g.id, 'member_away', tests.id('a1'), tests.id('a1'), '2041-03-01'::date, '2041-03-10'::date, null::uuid
     from public.groups g where g.id in (tests.id('G'), tests.id('H')) order by g.id $$,
  'a member_away event in each of the caller''s groups: actor = subject = caller, starts_on / ends_on');
select ok((select max(id) from public.group_activity where id > tests.since('away') and kind = 'member_away')
          < (select min(id) from public.group_activity where id > tests.since('away') and kind = 'turn_started'),
  'the announcement comes before the handover events');
select results_eq(
  $$ select tests.events_for('G'), tests.events_for('H'), tests.events_for('Other') $$,
  $$ values (1, 1, 0) $$,
  'the away change bumps every group of the caller once, no other group');

select is(tests.turn('R1') || ' ' || tests.assignees('R1'), 'a2 a2<null>',
  'a turn in the range goes to the next member, the only assignee, assigned_by NULL');
select is(tests.turn('R2') || ' ' || tests.assignees('R2'), 'a1 a1<admin>', 'a turn after the range is kept');
select is(tests.turn('R3'), 'a1', 'a done occurrence is not touched');
select is(tests.turn('R4'), 'a2', 'an occurrence where the caller is listed but not the turn holder is not touched');
select is(tests.turn('R5') || ' ' || tests.assignees('R5'), 'a3 a3<null>', 'absence skip: a2 is away that day, a3 takes the turn');
select is(tests.turn('R6'), 'a2', 'everyone else is away: the normal choice (the next member)');
select is(tests.turn('R7'), 'a1', 'the local due date counts: March 11 in Paris is out of the range');
select is(tests.turn('R8'), 'a3', 'and March 1 in Paris is in it');
select bag_eq(
  $$ select tests.name(a.subject_id) || ' ' || a.task_title from public.group_activity a
     where a.id > tests.since('away') and a.kind = 'turn_started' and a.actor_id is null $$,
  array['a2 R1', 'a3 R5', 'a2 R6', 'a3 R8'],
  'a turn_started event per handed-over occurrence');
select is((select count(*)::int from tests.pushes() p where p.body ->> 'message' = 'C' || chr(8217) || 'est ton tour dans «' || chr(160) || 'G' || chr(160) || '»'
           and p.body ->> 'topic' = 'equipe-aaaaaaaaaaaaaaaaaaaaaaaa'), 2,
  'the new turn holders are pushed « C’est ton tour » (a2: R1 and R6)');

select tests.mark('quiet');
select tests.as_user('a1');
select public.set_away('2041-06-01', '2041-06-02', false);
select tests.as_postgres();
select is((select count(*)::int from public.group_activity where id > tests.since('quiet') and kind = 'member_away'), 0,
  'p_announce false: no event');
select tests.as_user('a1');
select public.set_away('2041-03-01', '2041-03-10', null);
select tests.as_postgres();
select is((select count(*)::int from public.group_activity where id > tests.since('quiet') and kind = 'member_away'), 2,
  'a NULL p_announce announces (the default)');

-- Co-members read the columns; they are not writable directly.
select tests.as_user('admin');
select results_eq($$ select away_from, away_until from public.profiles where id = tests.id('a1') $$,
  $$ values ('2041-03-01'::date, '2041-03-10'::date) $$, 'a co-member reads the away columns');
select tests.as_user('outsider');
select is((select count(*)::int from public.profiles where id = tests.id('a1')), 0, 'a stranger does not');
select tests.as_user('a1');
select throws_ok($$ update public.profiles set away_from = null, away_until = null where id = auth.uid() $$,
  '42501', 'permission denied for table profiles', 'the away columns are written by the RPCs only');
select tests.as_postgres();
select throws_ok(format($$ update public.profiles set away_until = '2041-02-01' where id = %L $$, tests.id('a1')),
  '23514', null, 'check constraint: away_until >= away_from');
select throws_ok(format($$ update public.profiles set away_until = null where id = %L $$, tests.id('a1')),
  '23514', null, 'check constraint: both NULL or both set');

-- clear_away (§2) -----------------------------------------------------------------------------------------------------------
select tests.rewind();
select tests.mark('clear');
select tests.as_user('a1');
select results_eq($$ select away_from, away_until from public.clear_away() $$, $$ values (null::date, null::date) $$,
  'clear_away returns the profile without range');
select tests.as_postgres();
select is(tests.turn('R1'), 'a2', 'no turn moves back');
select is((select count(*)::int from public.group_activity where id > tests.since('clear')), 0, 'no event');
select is(tests.events_for('G') + tests.events_for('H'), 2, 'clearing bumps the caller''s groups');
select tests.rewind();
select tests.as_user('a1');
select public.clear_away();
select tests.as_postgres();
select is(tests.events_for('G') + tests.events_for('H'), 0, 'clear_away without a range writes nothing (no signal)');

-- Absence skip at create_task (§2) -----------------------------------------------------------------------------------------------
-- a2 is still away on 2041-03-04.
select tests.as_user('admin');
insert into tests.ids select 'C1', id from public.create_task(tests.id('G'), 'C1', null, 'low', '2041-03-04 07:00+00', '{}',
  '{"freq": "weekly", "tz": "Europe/Paris"}', tests.ids_of(array['a2', 'a3', 'a1']));
insert into tests.ids select 'C2', id from public.create_task(tests.id('G'), 'C2', null, 'low', '2041-03-05 07:00+00', '{}',
  '{"freq": "weekly", "tz": "Europe/Paris"}', tests.ids_of(array['a2', 'a3', 'a1']));
insert into tests.ids select 'C3', id from public.create_task(tests.id('G'), 'C3', null, 'low', '2041-03-03 23:30+00', '{}',
  '{"freq": "weekly", "tz": "Europe/Paris"}', tests.ids_of(array['a2', 'a3']));
insert into tests.ids select 'C4', id from public.create_task(tests.id('G'), 'C4', null, 'low', '2041-03-03 23:30+00', '{}',
  '{"freq": "weekly", "tz": "UTC"}', tests.ids_of(array['a2', 'a3']));
select tests.as_postgres();
select tests.away('a4', '2041-03-01', '2041-03-31');
select tests.as_user('admin');
insert into tests.ids select 'C5', id from public.create_task(tests.id('G'), 'C5', null, 'low', '2041-03-04 07:00+00', '{}',
  '{"freq": "weekly", "tz": "Europe/Paris"}', tests.ids_of(array['a4', 'a2']));
select tests.as_postgres();
select is(tests.turn('C1') || ' ' || tests.assignees('C1'), 'a3 a3<admin>',
  'create_task: rotation[1] is away on the due date, the turn goes to the next member, assigned by the creator');
select is(tests.turn('C2'), 'a2', 'not away on that date: rotation[1]');
select is(tests.turn('C3'), 'a3', 'the local due date counts (Europe/Paris: March 4, 00:30)');
select is(tests.turn('C4'), 'a2', '(UTC: March 3)');
select is(tests.turn('C5') || ' ' || tests.assignees('C5'), 'a4 a4<admin>', 'everyone away: rotation[1]');

-- update_task keeps its v2 rule: a new rotation without the turn holder gives the turn to rotation[1], away or not.
select tests.as_user('admin');
select public.update_task(tests.id('C2'), 'C2', null, 'low', '2041-03-04 07:00+00', null, null, tests.ids_of(array['a2', 'a3']));
select tests.as_postgres();
select is(tests.turn('C2'), 'a2', 'update_task: the stored turn holder is still listed, the turn is kept');
select tests.as_user('admin');
select public.update_task(tests.id('C1'), 'C1', null, 'low', '2041-03-04 07:00+00', null, null, tests.ids_of(array['a2', 'a1']));
select tests.as_postgres();
select is(tests.turn('C1'), 'a2', 'update_task: a new rotation without the turn holder gives the turn to rotation[1] (no absence skip)');

-- Absence skip at spawn (§2) ---------------------------------------------------------------------------------------------------------
-- Daily tasks due 2041-03-03: the next occurrence is due 2041-03-04 (a2 and a4 away).
select tests.rotating_task('S1', 'G', 'admin', array['a1', 'a2', 'a3'], 'a1', '2041-03-03 07:00+00', 'todo', 'daily');
select tests.rotating_task('S2', 'G', 'admin', array['a1', 'a2'], 'a1', '2041-03-03 07:00+00', 'todo', 'daily');
select tests.rotating_task('S3', 'G', 'admin', array['a2', 'a4'], 'a4', '2041-03-03 07:00+00', 'todo', 'daily');
select tests.as_user('a1');
select public.set_task_status(tests.id('S1'), 'done');
select public.set_task_status(tests.id('S2'), 'done');
select tests.as_user('a4');
select public.set_task_status(tests.id('S3'), 'done');
select tests.as_postgres();
insert into tests.ids select 'S1+', (tests.task('S1')).next_occurrence_id;
insert into tests.ids select 'S2+', (tests.task('S2')).next_occurrence_id;
insert into tests.ids select 'S3+', (tests.task('S3')).next_occurrence_id;
select is((tests.task('S1+')).due_at, '2041-03-04 07:00+00'::timestamptz, 'the next occurrence is due March 4');
select is(tests.turn('S1+') || ' ' || tests.assignees('S1+'), 'a3 a3<null>',
  'spawn: the next member (a2) is away on the new due date, a3 takes the turn');
select is((select tests.name(subject_id) from public.group_activity where kind = 'turn_started' and task_id = tests.id('S1+')), 'a3',
  'turn_started names the chosen turn holder');
select is(tests.turn('S2+') || ' ' || tests.assignees('S2+'), 'a1 a1<a1>',
  'spawn: the only other member is away, the previous turn holder takes it again (assigned by themselves)');
select is(tests.turn('S3+'), 'a2', 'spawn: everyone away, the normal choice');

-- Absence skip at the handover of a departed turn holder (§2) ---------------------------------------------------------------------------
select tests.create_group('G2', 'admin2');
select tests.add_member('G2', u) from unnest(array['b1', 'b2', 'b3', 'b4']) as u;
select tests.away('b2', '2041-03-04', '2041-03-04');
select tests.rotating_task('L1', 'G2', 'admin2', array['b1', 'b2', 'b3', 'b4'], 'b1', '2041-03-04 07:00+00');
select tests.rotating_task('L2', 'G2', 'admin2', array['b1', 'b2', 'b3'], 'b1', '2041-03-05 07:00+00');
select tests.as_user('b1');
select public.leave_group(tests.id('G2'));
select tests.as_postgres();
select is(tests.turn('L1') || ' ' || tests.assignees('L1'), 'b3 b3<null>',
  'handover: the next member (b2) is away on the due date, b3 takes the turn');
select is(tests.turn('L2'), 'b2', 'handover: on another date, the next member');
select tests.away('b4', '2041-03-01', '2041-03-31');
select tests.away('b2', '2041-03-01', '2041-03-31');
select tests.as_user('admin2');
select public.remove_member(tests.id('G2'), tests.id('b3'));
select tests.as_postgres();
select is(tests.turn('L1'), 'b4', 'handover: everyone left is away, the normal choice (the next member, b4)');

-- private.is_away / pick_turn ------------------------------------------------------------------------------------------------------------
select ok(private.is_away(tests.id('b2'), '2041-03-01') and private.is_away(tests.id('b2'), '2041-03-31')
          and not private.is_away(tests.id('b2'), '2041-04-01') and not private.is_away(tests.id('b2'), null),
  'is_away: both ends included, NULL date never away');
select is(tests.name(private.pick_turn(tests.ids_of(array['a1', 'a2', 'a3']), tests.ids_of(array['a1', 'a3']), tests.id('a3'), '2041-01-01')),
  'a1', 'pick_turn: after the last position, wraps around, skipping non-candidates');
select is(private.pick_turn(tests.ids_of(array['a1', 'a2']), '{}', null, '2041-01-01'), null, 'pick_turn: no candidate, NULL');
select ok(not has_function_privilege('authenticated', 'private.pick_turn(uuid[], uuid[], uuid, date)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'private.is_away(uuid, date)', 'EXECUTE'),
  'API roles cannot call the helpers');

select * from finish();
rollback;
