-- v3 « Échanger mon tour » (docs/CONTRACTS-V3.md §3): request / respond / cancel (permissions, validation, order of the
-- errors), acceptance (turn, assignee, event, signal, no push), the automatic cancellation, the repayment at spawn, account
-- deletion and the RLS of turn_swaps.
begin;
select plan(65);

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
create function tests.affected(p_sql text) returns integer language plpgsql as $$
declare v_count integer;
begin
  execute p_sql;
  get diagnostics v_count = row_count;
  return v_count;
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
-- request_turn_swap as p_user, the swap named p_swap.
create function tests.request(p_swap text, p_user text, p_task text, p_to text) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  perform tests.as_user(p_user);
  select s.id into v_id from public.request_turn_swap(tests.id(p_task), tests.id(p_to)) s;
  perform tests.as_postgres();
  insert into tests.ids values (p_swap, v_id);
  return v_id;
end $$;
create function tests.swap(p_name text) returns public.turn_swaps language sql security definer as $$
  select * from public.turn_swaps where id = tests.id(p_name)
$$;
create function tests.status(p_name text) returns text language sql security definer as $$
  select coalesce((select s.status || case when s.responded_at = now() then '@now' when s.responded_at is null then '' else '@?' end
                   from public.turn_swaps s where s.id = tests.id(p_name)), 'gone')
$$;
create function tests.complete(p_task text, p_user text, p_next text) returns void language plpgsql as $$
begin
  perform tests.as_user(p_user);
  perform public.set_task_status(tests.id(p_task), 'done');
  perform tests.as_postgres();
  insert into tests.ids select p_next, (tests.task(p_task)).next_occurrence_id;
end $$;
create function tests.mark(p_name text) returns void language sql security definer as $$
  insert into tests.results values (p_name, to_jsonb((select coalesce(max(id), 0) from public.group_activity)));
$$;
create function tests.since(p_mark text) returns bigint language sql stable as $$
  select (r.value #>> '{}')::bigint from tests.results r where r.name = p_mark
$$;
create function tests.pushes() returns table (body jsonb) language sql security definer as $$
  select convert_from(q.body, 'UTF8')::jsonb
  from net.http_request_queue q
  where q.id > (select (r.value #>> '{}')::bigint from tests.results r where r.name = 'queue start')
  order by q.id
$$;
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

select tests.create_user(u) from unnest(array['admin', 'a', 'b', 'c', 'd', 'gone', 'leaver', 'fromleaver', 'x', 'outsider',
                                              'delto', 'delfrom']) as u;
select tests.create_group('G', 'admin');
select tests.add_member('G', u) from unnest(array['a', 'b', 'c', 'd', 'gone', 'leaver', 'fromleaver', 'x', 'delto', 'delfrom']) as u;
select tests.create_group('Other', 'outsider');
insert into public.push_subscriptions (user_id, topic) values (tests.id('b'), 'equipe-bbbbbbbbbbbbbbbbbbbbbbbb');
update private.settings set value = 'https://ntfy.example.test/' where key = 'ntfy_base_url';

select tests.rotating_task('T1', 'G', 'admin', array['a', 'b', 'c'], 'a');
select tests.rotating_task('TD', 'G', 'admin', array['a', 'b'], 'a', '2041-03-04 07:00+00', 'done');
select tests.rotating_task('T2', 'G', 'admin', array['a', 'b', 'gone'], 'a');
insert into public.tasks (group_id, title, created_by) values (tests.id('G'), 'Plain', tests.id('admin'));
insert into tests.ids select 'P', id from public.tasks where title = 'Plain';
insert into public.task_assignees (task_id, group_id, user_id, assigned_by) values (tests.id('P'), tests.id('G'), tests.id('a'), tests.id('admin'));
delete from public.group_members where group_id = tests.id('G') and user_id = tests.id('gone');

-- request_turn_swap: errors in order (§3) -------------------------------------------------------------------------------------
select tests.as_user('outsider');
select throws_ok(format($$ select public.request_turn_swap(%L, %L) $$, tests.id('T1'), tests.id('b')), 'P0001', 'task_not_found',
  'a non-member: task_not_found');
select throws_ok(format($$ select public.request_turn_swap(gen_random_uuid(), %L) $$, tests.id('b')), 'P0001', 'task_not_found',
  'an unknown task: task_not_found');
select tests.as_user('b');
select throws_ok(format($$ select public.request_turn_swap(%L, %L) $$, tests.id('T1'), tests.id('c')), 'P0001', 'not_your_turn',
  'a member who does not hold the turn: not_your_turn');
select tests.as_user('a');
select throws_ok(format($$ select public.request_turn_swap(%L, %L) $$, tests.id('TD'), tests.id('b')), 'P0001', 'not_your_turn',
  'a done occurrence: not_your_turn');
select throws_ok(format($$ select public.request_turn_swap(%L, %L) $$, tests.id('P'), tests.id('b')), 'P0001', 'not_your_turn',
  'a task without rotation: not_your_turn');
select throws_ok(format($$ select public.request_turn_swap(%L, %L) $$, tests.id('T1'), tests.id('a')), 'P0001', 'invalid_rotation',
  'to the caller: invalid_rotation');
select throws_ok(format($$ select public.request_turn_swap(%L, %L) $$, tests.id('T1'), tests.id('d')), 'P0001', 'invalid_rotation',
  'to a member not listed in the rotation: invalid_rotation');
select throws_ok(format($$ select public.request_turn_swap(%L, %L) $$, tests.id('T1'), tests.id('outsider')), 'P0001', 'invalid_rotation',
  'to a non-member: invalid_rotation');
select throws_ok(format($$ select public.request_turn_swap(%L, %L) $$, tests.id('T2'), tests.id('gone')), 'P0001', 'invalid_rotation',
  'to a listed user who left the group: invalid_rotation');
select throws_ok(format($$ select public.request_turn_swap(%L, null) $$, tests.id('T1')), 'P0001', 'invalid_rotation',
  'to NULL: invalid_rotation');
select tests.as_postgres();
select tests.rewind();
select tests.request('S1', 'a', 'T1', 'b');
select results_eq(
  $$ select task_id, group_id, series_id, from_user, to_user, status, created_at, responded_at, repaid_at from tests.swap('S1') $$,
  $$ values (tests.id('T1'), tests.id('G'), (tests.task('T1')).series_id, tests.id('a'), tests.id('b'), 'pending', now(),
             null::timestamptz, null::timestamptz) $$,
  'request_turn_swap: a pending swap of the series, from the caller to the member');
select is(tests.events_for('G'), 1, 'a swap write bumps the group');
select tests.as_user('a');
select throws_ok(format($$ select public.request_turn_swap(%L, %L) $$, tests.id('T1'), tests.id('c')), 'P0001', 'swap_pending',
  'a second proposal for the same occurrence: swap_pending');
select tests.as_anon();
select throws_ok(format($$ select public.request_turn_swap(%L, %L) $$, tests.id('T1'), tests.id('c')),
  '42501', 'permission denied for function request_turn_swap', 'anon cannot call it');
select tests.as_postgres();

-- RLS ------------------------------------------------------------------------------------------------------------------------------
select tests.as_user('c');
select is((select count(*)::int from public.turn_swaps where id = tests.id('S1')), 1, 'every member of the group sees the swaps');
select tests.as_user('outsider');
select is((select count(*)::int from public.turn_swaps), 0, 'a non-member sees nothing');
select tests.as_user('b');
select throws_ok($$ update public.turn_swaps set status = 'accepted' $$, '42501', 'permission denied for table turn_swaps',
  'no direct UPDATE');
select throws_ok(format($$ insert into public.turn_swaps (task_id, group_id, series_id, from_user, to_user) values (%L, %L, %L, %L, %L) $$,
    tests.id('T1'), tests.id('G'), tests.id('T1'), tests.id('b'), tests.id('a')),
  '42501', 'permission denied for table turn_swaps', 'no direct INSERT');
select throws_ok($$ delete from public.turn_swaps $$, '42501', 'permission denied for table turn_swaps', 'no direct DELETE');

-- respond_turn_swap: errors, decline --------------------------------------------------------------------------------------------------
select tests.as_user('outsider');
select throws_ok(format($$ select public.respond_turn_swap(%L, true) $$, tests.id('S1')), 'P0001', 'swap_not_found',
  'a non-member: swap_not_found');
select throws_ok($$ select public.respond_turn_swap(gen_random_uuid(), true) $$, 'P0001', 'swap_not_found', 'an unknown swap');
select tests.as_user('c');
select throws_ok(format($$ select public.respond_turn_swap(%L, true) $$, tests.id('S1')), '42501', 'forbidden',
  'another member: forbidden');
select tests.as_user('a');
select throws_ok(format($$ select public.respond_turn_swap(%L, true) $$, tests.id('S1')), '42501', 'forbidden',
  'the requester cannot answer their own proposal');
select tests.as_user('b');
select throws_ok(format($$ select public.respond_turn_swap(%L, null) $$, tests.id('S1')), '23502', 'invalid_input',
  'a NULL answer: invalid_input');
select is((select status from public.respond_turn_swap(tests.id('S1'), false)), 'declined', 'to_user declines');
select tests.as_postgres();
select is(tests.status('S1'), 'declined@now', 'declined, responded_at = now()');
select is(tests.turn('T1') || ' ' || tests.assignees('T1'), 'a a<admin>', 'a decline changes nothing on the occurrence');
select tests.as_user('b');
select throws_ok(format($$ select public.respond_turn_swap(%L, true) $$, tests.id('S1')), 'P0001', 'swap_not_pending',
  'answering again: swap_not_pending');
select tests.as_user('a');
select throws_ok(format($$ select public.cancel_turn_swap(%L) $$, tests.id('S1')), 'P0001', 'swap_not_pending',
  'cancelling a declined swap: swap_not_pending');
select tests.as_postgres();

-- Accept ------------------------------------------------------------------------------------------------------------------------------
select tests.request('S2', 'a', 'T1', 'b');
insert into tests.results values ('queue start', to_jsonb((select coalesce(max(q.id), 0) from net.http_request_queue q)));
select tests.mark('accept');
select tests.rewind();
select tests.as_user('b');
select results_eq($$ select status, responded_at from public.respond_turn_swap(tests.id('S2'), true) $$,
  $$ values ('accepted', now()) $$, 'to_user accepts: accepted, responded_at = now()');
select tests.as_postgres();
select is(tests.turn('T1') || ' ' || tests.assignees('T1'), 'b b<b>',
  'the occurrence''s turn and its only assignee become to_user, assigned by themselves');
select results_eq(
  $$ select kind, actor_id, subject_id, task_id, task_title from public.group_activity where id > tests.since('accept') $$,
  $$ values ('turn_swapped', tests.id('b'), tests.id('a'), tests.id('T1'), 'T1') $$,
  'a turn_swapped event: actor = to_user, subject = from_user');
select is(tests.events_for('G'), 1, 'accepting bumps the group once');
select is((select count(*)::int from tests.pushes()), 0, 'no push: to_user accepted (assigned_by = to_user)');
select tests.as_user('a');
select throws_ok(format($$ select public.request_turn_swap(%L, %L) $$, tests.id('T1'), tests.id('c')), 'P0001', 'not_your_turn',
  'the former turn holder no longer holds the turn');
select tests.as_postgres();

-- cancel_turn_swap ----------------------------------------------------------------------------------------------------------------------
select tests.rotating_task('T3', 'G', 'admin', array['a', 'b', 'c'], 'a');
select tests.request('S3', 'a', 'T3', 'c');
select tests.as_user('c');
select throws_ok(format($$ select public.cancel_turn_swap(%L) $$, tests.id('S3')), '42501', 'forbidden', 'only from_user may cancel');
select tests.as_user('outsider');
select throws_ok(format($$ select public.cancel_turn_swap(%L) $$, tests.id('S3')), 'P0001', 'swap_not_found', 'a non-member: swap_not_found');
select tests.as_user('a');
select is((select status from public.cancel_turn_swap(tests.id('S3'))), 'cancelled', 'from_user cancels');
select throws_ok(format($$ select public.cancel_turn_swap(%L) $$, tests.id('S3')), 'P0001', 'swap_not_pending', 'cancelling again');
select tests.as_user('c');
select throws_ok(format($$ select public.respond_turn_swap(%L, true) $$, tests.id('S3')), 'P0001', 'swap_not_pending',
  'a cancelled swap cannot be accepted');
select tests.as_postgres();
select is(tests.status('S3'), 'cancelled@now', 'cancelled, responded_at = now()');

-- Automatic cancellation (§3) ---------------------------------------------------------------------------------------------------------
select tests.rotating_task('T4', 'G', 'admin', array['a', 'b', 'c'], 'a');
select tests.request('S4', 'a', 'T4', 'b');
select tests.complete('T4', 'a', 'T4+');
select is(tests.status('S4'), 'cancelled@now', 'the occurrence becomes done: cancelled');
select is(tests.turn('T4+'), 'b', 'the spawn follows the normal order (a pending swap is no debt)');

select tests.rotating_task('T5', 'G', 'admin', array['a', 'b', 'c'], 'a');
select tests.request('S5', 'a', 'T5', 'c');
select tests.as_user('admin');
select public.update_task(tests.id('T5'), 'T5', null, 'medium', '2041-03-04 07:00+00', null, null, tests.ids_of(array['b', 'c']));
select tests.as_postgres();
select is(tests.status('S5'), 'cancelled@now', 'the turn changes another way (update_task): cancelled');

select tests.rotating_task('T6', 'G', 'admin', array['a', 'b', 'c'], 'a');
select tests.request('S6', 'a', 'T6', 'c');
select tests.as_user('admin');
select public.update_task(tests.id('T6'), 'T6', null, 'medium', '2041-03-04 07:00+00', null, null, tests.ids_of(array['a', 'b']));
select tests.as_postgres();
select is(tests.turn('T6') || ' ' || tests.status('S6'), 'a cancelled@now', 'to_user no longer listed in the rotation: cancelled');

select tests.rotating_task('T7', 'G', 'admin', array['a', 'leaver', 'c'], 'a');
select tests.request('S7', 'a', 'T7', 'leaver');
select tests.as_user('leaver');
select public.leave_group(tests.id('G'));
select tests.as_postgres();
select is(tests.status('S7'), 'cancelled@now', 'to_user leaves the group: cancelled');

select tests.rotating_task('T8', 'G', 'admin', array['a', 'b', 'c'], 'a');
select tests.request('S8', 'a', 'T8', 'b');
select tests.as_user('admin');
select public.update_task(tests.id('T8'), 'T8', null, 'medium', '2041-03-04 07:00+00', null, '{}');
select tests.as_postgres();
select is(tests.status('S8'), 'cancelled@now', 'the rule is cleared (no rotation any more): cancelled');

select tests.rotating_task('T9', 'G', 'admin', array['a', 'b', 'c'], 'a');
select tests.request('S9', 'a', 'T9', 'b');
select tests.as_user('admin');
select public.delete_task(tests.id('T9'));
select tests.as_postgres();
select is(tests.status('S9'), 'gone', 'the occurrence is deleted: its swaps are deleted (foreign key cascade)');

select tests.rotating_task('T10', 'G', 'admin', array['fromleaver', 'b', 'c'], 'fromleaver');
select tests.request('S10', 'fromleaver', 'T10', 'c');
select tests.as_user('fromleaver');
select public.leave_group(tests.id('G'));
select tests.as_postgres();
select is(tests.turn('T10') || ' ' || tests.status('S10'), 'b cancelled@now', 'from_user leaves: the handover moves the turn, cancelled');

select tests.rotating_task('T11', 'G', 'admin', array['a', 'b', 'c'], 'a', '2041-05-04 07:00+00');
select tests.request('S11', 'a', 'T11', 'c');
select tests.as_user('a');
select public.set_away('2041-05-04', '2041-05-04', false);
select public.clear_away();
select tests.as_postgres();
select is(tests.turn('T11') || ' ' || tests.status('S11'), 'b cancelled@now', 'set_away hands the turn over: cancelled');

select tests.rotating_task('T12', 'G', 'admin', array['a', 'b', 'c'], 'a');
select tests.request('S12', 'a', 'T12', 'b');
select tests.as_user('a');
select public.set_task_status(tests.id('T12'), 'in_progress');
select tests.as_postgres();
select is(tests.status('S12'), 'pending', 'an in_progress occurrence is still pending: the swap stays');

-- Repayment at spawn (§3) ------------------------------------------------------------------------------------------------------------
-- R: a ↔ b, daily. a gives R to b; the debt is paid back the next time the spawn would pick b.
select tests.rotating_task('R', 'G', 'admin', array['a', 'b'], 'a', '2041-03-03 07:00+00', 'todo', 'daily');
select tests.request('SR', 'a', 'R', 'b');
select tests.as_user('b');
select public.respond_turn_swap(tests.id('SR'), true);
select tests.as_postgres();
select tests.complete('R', 'b', 'R2');
select is(tests.turn('R2') || ' ' || coalesce((tests.swap('SR')).repaid_at::text, 'unpaid'), 'a unpaid',
  'after b''s favour the next turn is a''s (N = a: nothing to repay)');
select tests.complete('R2', 'a', 'R3');
select is(tests.turn('R3') || ' ' || tests.assignees('R3'), 'a a<a>',
  'N = b owes nothing but got a''s turn: the turn goes back to a (repayment), assigned by the completer');
select results_eq($$ select status, repaid_at from tests.swap('SR') $$, $$ values ('accepted', now()) $$,
  'the swap gets repaid_at = now() and stays accepted');
select is((select tests.name(subject_id) from public.group_activity where kind = 'turn_started' and task_id = tests.id('R3')), 'a',
  'turn_started names the repaid member');
select tests.complete('R3', 'a', 'R4');
select is(tests.turn('R4'), 'b', 'once repaid, the normal order again');

-- The repayment is skipped while from_user is away on the new due date.
select tests.rotating_task('Q', 'G', 'admin', array['a', 'b'], 'a', '2041-04-03 07:00+00', 'todo', 'daily');
select tests.request('SQ', 'a', 'Q', 'b');
select tests.as_user('b');
select public.respond_turn_swap(tests.id('SQ'), true);
select tests.as_postgres();
select tests.complete('Q', 'b', 'Q2');
update public.profiles set away_from = '2041-04-05', away_until = '2041-04-05' where id = tests.id('a');
select tests.complete('Q2', 'a', 'Q3');
select is(tests.turn('Q3') || ' ' || coalesce((tests.swap('SQ')).repaid_at::text, 'unpaid'), 'b unpaid',
  'from_user is away on the new due date: no repayment this time');
update public.profiles set away_from = null, away_until = null where id = tests.id('a');

-- The oldest accepted swap of the series whose from_user is still a member listed in the rotation.
select tests.rotating_task('W', 'G', 'admin', array['b', 'c', 'a', 'x'], 'a', '2041-06-01 07:00+00', 'todo', 'daily');
insert into public.turn_swaps (task_id, group_id, series_id, from_user, to_user, status, created_at, responded_at)
values
  (tests.id('W'), tests.id('G'), tests.id('W'), tests.id('x'), tests.id('b'), 'accepted', now() - interval '3 hours', now() - interval '3 hours'),
  (tests.id('W'), tests.id('G'), tests.id('W'), tests.id('d'), tests.id('b'), 'accepted', now() - interval '150 minutes', now() - interval '150 minutes'),
  (tests.id('W'), tests.id('G'), tests.id('W'), tests.id('c'), tests.id('b'), 'accepted', now() - interval '2 hours', now() - interval '2 hours'),
  (tests.id('W'), tests.id('G'), tests.id('W'), tests.id('a'), tests.id('b'), 'accepted', now() - interval '1 hour', now() - interval '1 hour');
insert into tests.ids select 'W:' || tests.name(from_user), id from public.turn_swaps where series_id = tests.id('W');
delete from public.group_members where group_id = tests.id('G') and user_id = tests.id('x');
select tests.complete('W', 'a', 'W2');
select is(tests.turn('W2'), 'c', 'N = b: x left and d is not listed, so c''s swap (the oldest eligible) is repaid');
select results_eq(
  $$ select tests.name(from_user), repaid_at is not null from public.turn_swaps where series_id = tests.id('W') order by created_at $$,
  $$ values ('x', false), ('d', false), ('c', true), ('a', false) $$,
  'only that swap is repaid');

-- Account deletion ---------------------------------------------------------------------------------------------------------------------
select tests.rotating_task('TX', 'G', 'admin', array['delfrom', 'b', 'c', 'delto'], 'delfrom');
select tests.request('SX', 'delfrom', 'TX', 'delto');
select tests.as_user('delto');
select lives_ok($$ select public.delete_my_account() $$, 'to_user deletes their account with a pending swap');
select tests.as_postgres();
select is(tests.status('SX'), 'gone', 'the swap is deleted with the account');
select tests.request('SY', 'delfrom', 'TX', 'b');
select tests.as_user('delfrom');
select lives_ok($$ select public.delete_my_account() $$, 'from_user deletes their account with a pending swap');
select tests.as_postgres();
select is(tests.status('SY') || ' ' || tests.turn('TX'), 'gone b', 'the swap is deleted and the turn handed over');

select is((select count(*)::int from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'turn_swaps'), 1,
  'turn_swaps is published to Realtime');
select ok(exists (select 1 from pg_indexes where indexname = 'turn_swaps_one_pending_per_task_idx'
                  and indexdef like '%UNIQUE%' and indexdef like '%WHERE (status = ''pending''::text)%'),
  'at most one pending swap per occurrence (partial unique index)');

select * from finish();
rollback;
