-- v2 spawning and rotation (docs/CONTRACTS-V2.md §3, §5, §6, §11): the next occurrence (copied fields, checklist,
-- created_by, quota exemption, once per occurrence, v1 set_task_status), the turn order, departed members, rotations
-- shrinking below 2, assigned_by, set_task_assignees refused, update_task rotation edits, v1 edits, ntfy wording.
begin;
select plan(68);

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

create function tests.name(p_id uuid) returns text language sql stable as $$
  select coalesce((select i.name from tests.ids i where i.id = p_id order by i.name limit 1), 'null')
$$;
create function tests.task(p_name text) returns public.tasks language sql security definer as $$
  select * from public.tasks where id = tests.id(p_name)
$$;
-- Creates a task in G as the current user (rule, rotation, assignees, checklist by name) and names it p_name.
create function tests.new_task(p_name text, p_rule jsonb, p_rotation text[] default null, p_assignees text[] default '{}',
                               p_checklist text[] default null, p_due timestamptz default '2041-03-04 07:00+00') returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  select t.id into v_id
  from public.create_task(
    tests.id('G'), p_name, 'Détails de ' || p_name, 'high', p_due,
    array(select tests.id(a) from unnest(p_assignees) as a),
    p_rule,
    case when p_rotation is null then null else array(select tests.id(r) from unnest(p_rotation) with ordinality as x (r, o) order by o) end,
    p_checklist
  ) t;
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
-- Completes p_task as p_user (set_task_status) and names the spawned occurrence p_next.
create function tests.complete(p_task text, p_user text, p_next text) returns void language plpgsql as $$
begin
  perform tests.as_user(p_user);
  perform public.set_task_status(tests.id(p_task), 'done');
  perform tests.as_postgres();
  insert into tests.ids select p_next, (tests.task(p_task)).next_occurrence_id;
end $$;
-- The assignees of a task as "user<assigned_by>", sorted.
create function tests.assignees(p_task text) returns text language sql security definer as $$
  select coalesce(string_agg(tests.name(ta.user_id) || '<' || tests.name(ta.assigned_by) || '>', ',' order by tests.name(ta.user_id)), '')
  from public.task_assignees ta where ta.task_id = tests.id(p_task)
$$;
-- rotation (names) / turn holder of a task.
create function tests.rotation(p_task text) returns text language sql security definer as $$
  select coalesce((select string_agg(tests.name(r.id), ',' order by r.ord)
                   from unnest((tests.task(p_task)).rotation) with ordinality as r (id, ord)), 'null')
         || ' turn=' || tests.name((tests.task(p_task)).turn_user_id)
$$;
create function tests.rotation_sql(p_names text[]) returns text language sql stable as $$
  select format('array[%s]::uuid[]', string_agg(quote_literal(tests.id(n)), ', ' order by o))
  from unnest(p_names) with ordinality as x (n, o)
$$;
-- Requests queued by pg_net in this transaction.
create function tests.pushes() returns table (body jsonb) language sql security definer as $$
  select convert_from(q.body, 'UTF8')::jsonb
  from net.http_request_queue q
  where q.id > (select (r.value #>> '{}')::bigint from tests.results r where r.name = 'queue start')
  order by q.id
$$;

select tests.create_user(u) from unnest(array['admin', 'creator', 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'gone', 'leaver',
                                              'deleted', 'outsider']) as u;
select tests.create_group('G', 'admin');
select tests.add_member('G', u) from unnest(array['creator', 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'gone', 'leaver', 'deleted']) as u;

-- Spawning (§6) ------------------------------------------------------------------------------------------------------
select tests.as_user('creator');
select tests.new_task('S', '{"freq": "daily", "tz": "Europe/Paris"}', null, array['m1', 'm2'], array['Un', 'Deux', 'Trois']);
select public.delete_checklist_item((select id from public.task_checklist_items where task_id = tests.id('S') and title = 'Deux'));
select public.set_checklist_item_done((select id from public.task_checklist_items where task_id = tests.id('S') and title = 'Un'), true);
select tests.as_postgres();
-- The write quota does not apply to spawns.
update private.settings set value = '0' where key = 'quota_tasks_per_hour';
insert into tests.results values ('log before', to_jsonb((select count(*) from private.write_log)));

-- m1 is only an assignee (not an editor): completing still spawns.
select tests.complete('S', 'm1', 'S2');
select results_eq(
  $$ select status::text, completed_by, completed_at, next_occurrence_id is not null from public.tasks where id = tests.id('S') $$,
  $$ values ('done', tests.id('m1'), now(), true) $$,
  'the completed occurrence: completed_by = completer, next_occurrence_id set');
select results_eq(
  $$ select group_id, title, details, priority::text, status::text, repeat_freq, repeat_interval, repeat_tz, series_id,
            created_by, created_at, updated_at, completed_at, completed_by, next_occurrence_id, due_at
     from public.tasks where id = tests.id('S2') $$,
  $$ values (tests.id('G'), 'S', 'Détails de S', 'high', 'todo', 'daily', 1::smallint, 'Europe/Paris', tests.id('S'),
             tests.id('creator'), now(), now(), null::timestamptz, null::uuid, null::uuid, '2041-03-05 07:00+00'::timestamptz) $$,
  'the next occurrence copies the fields, keeps the series creator, series_id = first occurrence, due one day later');
select results_eq(
  $$ select title, position, done, done_at, done_by from public.task_checklist_items where task_id = tests.id('S2') order by position $$,
  $$ values ('Un', 1, false, null::timestamptz, null::uuid), ('Trois', 3, false, null, null) $$,
  'the checklist is copied unchecked, with the same positions (gaps kept)');
select is(tests.assignees('S2'), 'm1<m1>,m2<m2>', 'same assignees, each a continuation (assigned_by = user_id)');
select is((select count(*)::int from private.write_log), (select (value #>> '{}')::int from tests.results where name = 'log before'),
  'the spawn is exempt from the write quota (nothing logged, quota 0 not enforced)');
update private.settings set value = '200' where key = 'quota_tasks_per_hour';

-- Reopening and completing again spawns nothing more.
select tests.as_user('m1');
select public.set_task_status(tests.id('S'), 'todo');
select public.set_task_status(tests.id('S'), 'done');
select tests.as_postgres();
select is((select count(*)::int from public.tasks where series_id = tests.id('S')), 2, 'reopen then complete again: no second spawn');
select is((tests.task('S')).next_occurrence_id, tests.id('S2'), 'next_occurrence_id is unchanged');
select tests.as_user('m1');
select public.set_task_status(tests.id('S'), 'done');
select tests.as_postgres();
select is((select count(*)::int from public.tasks where series_id = tests.id('S')), 2, 'done → done spawns nothing');

-- A direct PATCH of the status (v1 path) spawns too; the chain keeps the first id as series_id.
select tests.as_user('m2');
update public.tasks set status = 'done' where id = tests.id('S2');
select tests.as_postgres();
insert into tests.ids select 'S3', (tests.task('S2')).next_occurrence_id;
select results_eq(
  $$ select series_id, due_at, created_by from public.tasks where id = tests.id('S3') $$,
  $$ values (tests.id('S'), '2041-03-06 07:00+00'::timestamptz, tests.id('creator')) $$,
  'a direct status PATCH spawns the third occurrence (same series, next day, series creator)');

-- Deleting the pending occurrence ends the series.
select tests.as_user('creator');
select public.delete_task(tests.id('S3'));
select public.set_task_status(tests.id('S2'), 'todo');
select public.set_task_status(tests.id('S2'), 'done');
select tests.as_postgres();
select is((select count(*)::int from public.tasks where series_id = tests.id('S')), 2, 'after deleting the pending occurrence, nothing respawns');

-- Clearing the rule makes the occurrence a plain task: completing it spawns nothing.
select tests.as_user('creator');
select tests.new_task('C', '{"freq": "weekly", "tz": "Europe/Paris"}');
select public.update_task(tests.id('C'), 'C', null, 'high', '2041-03-04 07:00+00', null, '{}');
select public.set_task_status(tests.id('C'), 'done');
select tests.as_postgres();
select ok((tests.task('C')).next_occurrence_id is null and (tests.task('C')).series_id is null,
  'a cleared rule: completing spawns nothing');

-- The series creator is kept even after leaving the group, and NULL once their account is deleted.
select tests.as_user('leaver');
select tests.new_task('L', '{"freq": "weekly", "tz": "Europe/Paris"}', null, array['m3']);
select public.leave_group(tests.id('G'));
select tests.complete('L', 'm3', 'L2');
select is((tests.task('L2')).created_by, tests.id('leaver'), 'a creator who left stays the series creator');
select tests.as_user('deleted');
select tests.new_task('X', '{"freq": "weekly", "tz": "Europe/Paris"}', null, array['m3']);
select tests.as_postgres();
delete from auth.users where id = tests.id('deleted');
select tests.complete('X', 'm3', 'X2');
select is((tests.task('X2')).created_by, null, 'a deleted creator: created_by stays NULL');

-- A trusted context completing a task (no JWT) spawns too.
update public.tasks set status = 'done' where id = tests.id('L2');
select results_eq(
  $$ select t.series_id, t.created_by, l.completed_by from public.tasks t, public.tasks l
     where l.id = tests.id('L2') and t.id = l.next_occurrence_id $$,
  $$ values (tests.id('L'), tests.id('leaver'), null::uuid) $$,
  'a trusted completion spawns (completed_by NULL)');

-- Rotation: creation and validation (§3, §5) ------------------------------------------------------------------------
select tests.as_user('creator');
select tests.new_task('R', '{"freq": "weekly", "tz": "Europe/Paris"}', array['m1', 'm2', 'm3'], array['outsider']);
select is(tests.rotation('R'), 'm1,m2,m3 turn=m1', 'create_task with a rotation: the turn is rotation[1]');
select is(tests.assignees('R'), 'm1<creator>', 'the assignee is rotation[1], assigned by the creator (p_assignee_ids ignored)');
select throws_ok(format($$ select public.create_task(%L, 'R', null, 'low', '2041-03-04 07:00+00', '{}', '{"freq": "daily", "tz": "UTC"}', %s) $$,
    tests.id('G'), tests.rotation_sql(array['m1'])),
  'P0001', 'invalid_rotation', 'a rotation of 1 user');
select throws_ok(format($$ select public.create_task(%L, 'R', null, 'low', '2041-03-04 07:00+00', '{}', '{"freq": "daily", "tz": "UTC"}', %s) $$,
    tests.id('G'), tests.rotation_sql(array['m1', 'm2', 'm1'])),
  'P0001', 'invalid_rotation', 'duplicates');
select throws_ok(format($$ select public.create_task(%L, 'R', null, 'low', '2041-03-04 07:00+00', '{}', '{"freq": "daily", "tz": "UTC"}', %s) $$,
    tests.id('G'), tests.rotation_sql(array['m1', 'outsider'])),
  'P0001', 'invalid_rotation', 'a non-member');
select throws_ok(format($$ select public.create_task(%L, 'R', null, 'low', '2041-03-04 07:00+00', '{}', '{"freq": "daily", "tz": "UTC"}', array[%L, null]::uuid[]) $$,
    tests.id('G'), tests.id('m1')),
  'P0001', 'invalid_rotation', 'a NULL id');
select throws_ok(format($$ select public.create_task(%L, 'R', null, 'low', '2041-03-04 07:00+00', '{}', '{"freq": "daily", "tz": "UTC"}', %L::uuid[]) $$,
    tests.id('G'), (select array_agg(gen_random_uuid()) from generate_series(1, 21))),
  'P0001', 'invalid_rotation', 'more than 20 ids');
select throws_ok(format($$ select public.create_task(%L, 'R', null, 'low', '2041-03-04 07:00+00', '{}', null, %s) $$,
    tests.id('G'), tests.rotation_sql(array['m1', 'm2'])),
  'P0001', 'invalid_rotation', 'a rotation without recurrence');
select throws_ok(format($$ select public.create_task(%L, 'R', null, 'low', '2041-03-04 07:00+00', '{}', '{"freq": "daily"}', %s) $$,
    tests.id('G'), tests.rotation_sql(array['m1'])),
  'P0001', 'invalid_recurrence', 'order: recurrence before rotation');
select throws_ok(format($$ select public.create_task(%L, 'R', null, 'low', '2041-03-04 07:00+00', array[%L]::uuid[], '{"freq": "daily", "tz": "UTC"}', %s) $$,
    tests.id('G'), tests.id('outsider'), tests.rotation_sql(array['m1', 'outsider'])),
  'P0001', 'invalid_rotation', 'order: rotation before assignees');
select lives_ok(format($$ select public.create_task(%L, 'Vingt', null, 'low', '2041-03-04 07:00+00', '{}', '{"freq": "daily", "tz": "UTC"}', %s) $$,
    tests.id('G'), tests.rotation_sql(array['m1', 'm2'])),
  'a rotation of 2 members');

-- Turn order (§6) ---------------------------------------------------------------------------------------------------
select tests.as_postgres();
insert into public.push_subscriptions (user_id, topic) values
  (tests.id('m1'), 'equipe-aaaaaaaaaaaaaaaaaaaaaaaa'),
  (tests.id('m2'), 'equipe-bbbbbbbbbbbbbbbbbbbbbbbb'),
  (tests.id('m3'), 'equipe-cccccccccccccccccccccccc'),
  (tests.id('admin'), 'equipe-dddddddddddddddddddddddd');
update private.settings set value = 'https://ntfy.example.test/' where key = 'ntfy_base_url';
insert into tests.results values ('queue start', to_jsonb((select coalesce(max(q.id), 0) from net.http_request_queue q)));

select tests.complete('R', 'm1', 'R2');
select is(tests.rotation('R2'), 'm1,m2,m3 turn=m2', 'm1 completes: m2''s turn');
select is(tests.assignees('R2'), 'm2<null>', 'the turn holder is the only assignee, assigned_by NULL');
select results_eq(
  $$ select kind, actor_id, subject_id, task_id, task_title from public.group_activity
     where group_id = tests.id('G') and kind = 'turn_started' and task_id = tests.id('R2') $$,
  $$ values ('turn_started', null::uuid, tests.id('m2'), tests.id('R2'), 'R') $$,
  'turn_started: no actor, the turn holder as subject, the new occurrence');
select is((select count(*)::int from tests.pushes()), 1, 'one ntfy push: the new turn holder');
select is((select body from tests.pushes()),
  jsonb_build_object(
    'topic', 'equipe-bbbbbbbbbbbbbbbbbbbbbbbb',
    'title', 'Équipe',
    'message', E'C’est ton tour dans « G »',
    'click', 'equipe://task/' || tests.id('G') || '/' || tests.id('R2')),
  'rotation turn push: « C’est ton tour dans « G » », deep link to the new occurrence');
select is((select body ->> 'message' from tests.pushes()), E'C’est ton tour dans « G »',
  'the message uses a typographic apostrophe and no-break spaces inside the guillemets');
select tests.complete('R2', 'm2', 'R3');
select is(tests.rotation('R3'), 'm1,m2,m3 turn=m3', 'm2 completes: m3''s turn');
select tests.complete('R3', 'm3', 'R4');
select is(tests.rotation('R4'), 'm1,m2,m3 turn=m1', 'm3 completes: back to m1');
select is(tests.assignees('R4'), 'm1<null>', 'm1 assigned by nobody (a turn)');

-- The completer becomes the turn holder: assigned_by = the completer (no notification).
select tests.as_user('creator');
select tests.new_task('Self', '{"freq": "weekly", "tz": "Europe/Paris"}', array['m1', 'admin']);
select tests.as_postgres();
insert into tests.results values ('pushes before self', to_jsonb((select count(*) from tests.pushes())));
select tests.complete('Self', 'admin', 'Self2');
select is(tests.rotation('Self2') || ' ' || tests.assignees('Self2'), 'm1,admin turn=admin admin<admin>',
  'the admin completes m1''s turn: the admin''s turn, assigned by themselves');
select is((select count(*)::int from tests.pushes()), (select (value #>> '{}')::int from tests.results where name = 'pushes before self'),
  'no push for a turn taken by the completer');

-- Departed members are skipped; the turn continues after the previous holder's position in the original list.
select tests.as_user('creator');
select tests.new_task('P', '{"freq": "weekly", "tz": "Europe/Paris"}', array['m1', 'm4', 'm2', 'm3']);
select tests.as_postgres();
delete from public.group_members where group_id = tests.id('G') and user_id = tests.id('m4');
select tests.complete('P', 'm1', 'P2');
select is(tests.rotation('P2'), 'm1,m2,m3 turn=m2', 'm4 left: skipped, and removed from the new rotation');

-- The spawn continues after the previous turn holder's position, even when they are no longer a member. Since the
-- handover of 20260925000500 (17_v2_turn_handover_signals) only a fixture gets there: a trusted edit gives the turn to
-- m5 after m5 left.
select tests.as_user('creator');
select tests.new_task('Q', '{"freq": "weekly", "tz": "Europe/Paris"}', array['m3', 'm5', 'm1']);
select tests.as_postgres();
delete from public.group_members where group_id = tests.id('G') and user_id = tests.id('m5');
update public.tasks set turn_user_id = tests.id('m5') where id = tests.id('Q');
select tests.complete('Q', 'admin', 'Q2');
select is(tests.rotation('Q2'), 'm3,m1 turn=m1', 'm5 (turn holder, no longer a member): the turn goes to the next member after m5, m1');

-- The turn holder's account is deleted: the turn is handed over at once. A NULL turn (a fixture) makes the spawn start
-- from the first member of the cleaned list.
select tests.as_user('creator');
select tests.new_task('Z', '{"freq": "weekly", "tz": "Europe/Paris"}', array['gone', 'm2', 'm3']);
select tests.as_postgres();
delete from auth.users where id = tests.id('gone');
select is(tests.rotation('Z'), 'gone,m2,m3 turn=m2', 'the turn holder''s account is deleted: the turn goes to the next member');
update public.tasks set turn_user_id = null where id = tests.id('Z');
select tests.complete('Z', 'admin', 'Z2');
select is(tests.rotation('Z2') || ' ' || tests.assignees('Z2'), 'm2,m3 turn=m2 m2<null>',
  'no previous turn holder: the first member of the cleaned list');

-- Fewer than 2 members left: the rotation is dropped, the remaining member is the assignee.
select tests.as_user('creator');
select tests.new_task('T', '{"freq": "weekly", "tz": "Europe/Paris"}', array['m1', 'm6']);
select tests.new_task('T0', '{"freq": "weekly", "tz": "Europe/Paris"}', array['m1', 'm6']);
select tests.as_postgres();
delete from public.group_members where group_id = tests.id('G') and user_id = tests.id('m6');
select tests.complete('T', 'm1', 'T2');
select results_eq(
  $$ select rotation, turn_user_id, series_id from public.tasks where id = tests.id('T2') $$,
  $$ values (null::uuid[], null::uuid, tests.id('T')) $$,
  'm6 left: the rotation of T2 is dropped (still a recurring task)');
select is(tests.assignees('T2'), 'm1<m1>', 'the remaining member is the assignee (assigned by themselves: the completer)');
select tests.complete('T0', 'admin', 'T02');
select is(tests.assignees('T02'), 'm1<null>', 'completed by someone else: assigned_by NULL');
select is((select count(*)::int from public.group_activity where kind = 'turn_started' and task_id in (tests.id('T2'), tests.id('T02'))), 0,
  'no turn_started without a rotation');
select tests.as_user('creator');
select tests.new_task('Empty', '{"freq": "weekly", "tz": "Europe/Paris"}', array['m2', 'm3']);
select tests.as_postgres();
delete from public.group_members where group_id = tests.id('G') and user_id in (tests.id('m2'), tests.id('m3'));
select tests.complete('Empty', 'creator', 'Empty2');
select is(tests.rotation('Empty2') || ' [' || tests.assignees('Empty2') || ']', 'null turn=null []',
  'every rotation member left: no rotation, no assignee');
select tests.add_member('G', 'm2');
select tests.add_member('G', 'm3');
select tests.add_member('G', 'm4');
select tests.add_member('G', 'm5');
select tests.add_member('G', 'm6');

-- set_task_assignees refuses rotating tasks (§5) -----------------------------------------------------------------------
select tests.as_user('creator');
select throws_ok(format($$ select public.set_task_assignees(%L, array[%L]::uuid[]) $$, tests.id('R4'), tests.id('m2')),
  'P0001', 'invalid_rotation', 'set_task_assignees on a rotating task: the creator');
select tests.as_user('admin');
select throws_ok(format($$ select public.set_task_assignees(%L, '{}') $$, tests.id('R4')),
  'P0001', 'invalid_rotation', 'set_task_assignees on a rotating task: an admin');
select tests.as_user('m5');
select throws_ok(format($$ select public.set_task_assignees(%L, '{}') $$, tests.id('R4')),
  '42501', 'forbidden', 'the permission check comes first');
select tests.as_user('outsider');
select throws_ok(format($$ select public.set_task_assignees(%L, '{}') $$, tests.id('R4')),
  'P0001', 'task_not_found', 'a non-member gets task_not_found');

-- update_task and rotations (§5) ----------------------------------------------------------------------------------------
select tests.as_user('creator');
select public.update_task(tests.id('R4'), 'R', null, 'high', (tests.task('R4')).due_at, array[tests.id('m2'), tests.id('m3')]);
select is(tests.assignees('R4'), 'm1<null>', 'update_task ignores p_assignee_ids while the task has a rotation');

select tests.new_task('V', '{"freq": "weekly", "tz": "Europe/Paris"}', array['m1', 'm3']);
select public.update_task(tests.id('V'), 'V', null, 'high', '2041-03-04 07:00+00', null, null,
  array[tests.id('m3'), tests.id('m1'), tests.id('m4')]);
select is(tests.rotation('V') || ' ' || tests.assignees('V'), 'm3,m1,m4 turn=m1 m1<creator>',
  'a new rotation that still lists the turn holder keeps the turn (and the assignment row)');
select tests.as_user('admin');
select public.update_task(tests.id('V'), 'V', null, 'high', '2041-03-04 07:00+00', null, null,
  array[tests.id('m3'), tests.id('m4')]);
select is(tests.rotation('V') || ' ' || tests.assignees('V'), 'm3,m4 turn=m3 m3<admin>',
  'without the turn holder: the turn goes to rotation[1], assigned by the editor');
select tests.as_postgres();
delete from public.group_members where group_id = tests.id('G') and user_id = tests.id('m4');
select tests.as_user('creator');
select lives_ok(format($$ select public.update_task(%L, 'V bis', null, 'high', '2041-03-04 07:00+00', null, null, %s) $$,
    tests.id('V'), tests.rotation_sql(array['m3', 'm4'])),
  'the stored rotation sent back as is (m4 left since) counts as unchanged');
select is(tests.rotation('V'), 'm3,m4 turn=m3', 'the rotation is unchanged');
select throws_ok(format($$ select public.update_task(%L, 'V', null, 'high', '2041-03-04 07:00+00', null, null, %s) $$,
    tests.id('V'), tests.rotation_sql(array['m3', 'm4', 'm1'])),
  'P0001', 'invalid_rotation', 'a new rotation must list members only');
select tests.as_postgres();
select tests.add_member('G', 'm4');
select tests.as_user('creator');
select public.update_task(tests.id('V'), 'V', null, 'high', '2041-03-04 07:00+00', null, null, '{}');
select is(tests.rotation('V') || ' ' || tests.assignees('V') || ' ' || (tests.task('V')).repeat_freq,
  'null turn=null m3<admin> weekly', '''{}'' removes the rotation and the turn; the assignee and the rule stay');
select public.update_task(tests.id('V'), 'V', null, 'high', '2041-03-04 07:00+00', null, null, array[tests.id('m1'), tests.id('m3')]);
select is(tests.rotation('V') || ' ' || tests.assignees('V'), 'm1,m3 turn=m1 m1<creator>',
  'a rotation on a task without turn holder: rotation[1], the other assignees are removed');
select public.update_task(tests.id('V'), 'V', null, 'high', '2041-03-04 07:00+00', array[tests.id('m4'), tests.id('m1')], null, '{}');
select is(tests.rotation('V') || ' ' || tests.assignees('V'), 'null turn=null m1<creator>,m4<creator>',
  'removing the rotation and giving assignees at once: the assignees are replaced');
select public.update_task(tests.id('V'), 'V', null, 'high', '2041-03-04 07:00+00', null, null, array[tests.id('m1'), tests.id('m3')]);
select throws_ok(format($$ select public.update_task(%L, 'V', null, 'high', '2041-03-04 07:00+00', null, '{}', %s) $$,
    tests.id('V'), tests.rotation_sql(array['m3', 'm1'])),
  'P0001', 'invalid_rotation', 'no recurrence with a new rotation');
select lives_ok(format($$ select public.update_task(%L, 'V', null, 'high', '2041-03-04 07:00+00', null, '{}', %s) $$,
    tests.id('V'), tests.rotation_sql(array['m1', 'm3'])),
  'clearing the rule while sending the stored rotation back');
select is(tests.rotation('V') || ' ' || coalesce((tests.task('V')).repeat_freq, 'plain'), 'null turn=null plain',
  'clearing the rule also clears the rotation');
select tests.new_task('NoRule', null);
select throws_ok(format($$ select public.update_task(%L, 'NoRule', null, 'high', '2041-03-04 07:00+00', null, null, %s) $$,
    tests.id('NoRule'), tests.rotation_sql(array['m1', 'm3'])),
  'P0001', 'invalid_rotation', 'a rotation on a task without recurrence');

-- v1 compatibility (§0): a v1 update_task call keeps the recurrence, the rotation, the turn and the checklist ----------------
select tests.new_task('W', '{"freq": "weekly", "weekdays": [1, 4], "tz": "Europe/Paris"}', array['m1', 'm3'], '{}', array['A', 'B']);
select public.update_task(
  p_task_id => tests.id('W'), p_title => 'W (v1)', p_details => 'Édité en v1', p_priority => 'low',
  p_due_at => '2041-03-05 07:00+00', p_assignee_ids => array[tests.id('m4')]);
select results_eq(
  $$ select title, details, priority::text, repeat_freq, repeat_weekdays, repeat_tz, rotation, turn_user_id
     from public.tasks where id = tests.id('W') $$,
  format($$ values ('W (v1)', 'Édité en v1', 'low', 'weekly', '{1,4}'::smallint[], 'Europe/Paris', %s, %L::uuid) $$,
         tests.rotation_sql(array['m1', 'm3']), tests.id('m1')),
  'v1 update_task: the v1 fields change, the rule, the rotation and the turn are kept');
select is(tests.assignees('W'), 'm1<creator>', 'v1 update_task: the turn holder stays the only assignee');
select is((select string_agg(title || '@' || position, ',' order by position) from public.task_checklist_items where task_id = tests.id('W')),
  'A@1,B@2', 'v1 update_task: the checklist is kept');

-- Pushes (§11): the creator's initial assignment keeps the v1 wording; continuations are not pushed. ----------------------
select tests.as_postgres();
insert into tests.results values ('pushes before', to_jsonb((select count(*) from tests.pushes())));
select tests.as_user('creator');
select tests.new_task('Push', '{"freq": "weekly", "tz": "Europe/Paris"}', array['m2', 'm3']);
select tests.as_postgres();
select is((select body ->> 'message' from tests.pushes() offset (select (value #>> '{}')::int from tests.results where name = 'pushes before') limit 1),
  'Nouvelle tâche assignée dans « G »', 'the first turn, assigned by the creator, keeps the v1 wording');
select tests.as_user('creator');
select tests.new_task('Cont', '{"freq": "weekly", "tz": "Europe/Paris"}', null, array['m1']);
select tests.as_postgres();
insert into tests.results values ('pushes before cont', to_jsonb((select count(*) from tests.pushes())));
select tests.complete('Cont', 'm1', 'Cont2');
select is((select count(*)::int from tests.pushes()), (select (value #>> '{}')::int from tests.results where name = 'pushes before cont'),
  'a continuation (assigned_by = user_id) is not pushed');
select is(tests.assignees('Cont2'), 'm1<m1>', 'the continuation row');

select * from finish();
rollback;
