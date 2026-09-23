-- Tasks: validation, server-maintained fields (created_by, completed_at, updated_at), assignees
-- (≤ 20, members only, retained rows keep assigned_at/assigned_by), update_task semantics.
begin;
select plan(72);

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
create function tests.create_task(p_name text, p_group text, p_creator text, p_assignees text[] default '{}') returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into public.tasks (group_id, title, created_by)
  values (tests.id(p_group), p_name, tests.id(p_creator)) returning id into v_id;
  insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
  select v_id, tests.id(p_group), tests.id(a), tests.id(p_creator) from unnest(p_assignees) as a;
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
-- -------------------------------------------------------------------------------------------------------

select tests.create_user('admin');
select tests.create_user('creator');
select tests.create_user('outsider');
select tests.create_group('G', 'admin');
select tests.add_member('G', 'creator');
select tests.create_user('m' || i) from generate_series(1, 21) as i;
select tests.add_member('G', 'm' || i) from generate_series(1, 21) as i;

create function tests.members(p_from integer, p_to integer) returns uuid[] language sql as $$
  select array_agg(tests.id('m' || i) order by tests.id('m' || i)) from generate_series(p_from, p_to) as i
$$;
create function tests.assignees(p_task text) returns uuid[] language sql as $$
  select coalesce(array_agg(user_id order by user_id), '{}') from public.task_assignees where task_id = tests.id(p_task)
$$;
create function tests.task(p_name text) returns public.tasks language sql as $$
  select * from public.tasks where id = tests.id(p_name)
$$;

-- create_task validation ------------------------------------------------------------------------------------
select tests.as_user('creator');
select throws_ok(format($$ select public.create_task(%L, '') $$, tests.id('G')), 'P0001', 'invalid_title', 'empty title');
select throws_ok(format($$ select public.create_task(%L, E'  \n ') $$, tests.id('G')), 'P0001', 'invalid_title', 'blank title');
select throws_ok(format($$ select public.create_task(%L, null) $$, tests.id('G')), 'P0001', 'invalid_title', 'NULL title');
select throws_ok(format($$ select public.create_task(%L, %L) $$, tests.id('G'), repeat('t', 201)), 'P0001', 'invalid_title',
  '201-char title');
select lives_ok(format($$ select public.create_task(%L, %L) $$, tests.id('G'), repeat('t', 200)), '200-char title is accepted');
select throws_ok(format($$ select public.create_task(%L, 'Titre', %L) $$, tests.id('G'), repeat('d', 5001)), 'P0001',
  'invalid_details', '5001-char details');
select lives_ok(format($$ select public.create_task(%L, 'Titre', %L) $$, tests.id('G'), repeat('d', 5000)),
  '5000-char details are accepted');
select throws_ok(format($$ select public.create_task(%L, '', null, 'low', null, array[%L]::uuid[]) $$,
    tests.id('G'), tests.id('outsider')),
  'P0001', 'invalid_title', 'the title is validated before the assignees');
select tests.as_user('outsider');
select throws_ok(format($$ select public.create_task(%L, '') $$, tests.id('G')), '42501', 'forbidden',
  'membership is checked before validation');

-- Trimming mirrors Swift's `whitespacesAndNewlines`: U+001C–U+001F are kept, U+200B is trimmed.
select tests.as_user('creator');
select is((public.create_task(tests.id('G'), E'\x1FTitre\x1C')).title, E'\x1FTitre\x1C',
  'U+001C–U+001F are not trimmed (as in Swift)');
select throws_ok(format($$ select public.create_task(%L, %L) $$, tests.id('G'), U&'\200B\3000'), 'P0001', 'invalid_title',
  'a title made of a zero-width space and an ideographic space is blank');

-- Due date: NULL or a finite instant in [1970-01-01, 10000-01-01) UTC. PostgREST renders ±infinity and BC
-- dates as strings that the clients' ISO-8601 decoder rejects, which would break every list containing the task.
select throws_ok(format($$ select public.create_task(%L, 'Infini', null, 'low', 'infinity') $$, tests.id('G')),
  'P0001', 'invalid_due_at', 'due date infinity');
select throws_ok(format($$ select public.create_task(%L, 'Moins infini', null, 'low', '-infinity') $$, tests.id('G')),
  'P0001', 'invalid_due_at', 'due date -infinity');
select throws_ok(format($$ select public.create_task(%L, 'Antique', null, 'low', '0044-03-15 00:00:00+00 BC') $$, tests.id('G')),
  'P0001', 'invalid_due_at', 'due date before Christ');
select throws_ok(format($$ select public.create_task(%L, 'Trop tôt', null, 'low', '1969-12-31 23:59:59.999999+00') $$,
    tests.id('G')),
  'P0001', 'invalid_due_at', 'due date before 1970');
select throws_ok(format($$ select public.create_task(%L, 'Trop tard', null, 'low', '10000-01-01 00:00:00+00') $$, tests.id('G')),
  'P0001', 'invalid_due_at', 'due date in year 10000');
select lives_ok(format($$ select public.create_task(%L, 'Borne basse', null, 'low', '1970-01-01 00:00:00+00') $$, tests.id('G')),
  'due date 1970-01-01T00:00:00Z is accepted');
select lives_ok(format($$ select public.create_task(%L, 'Borne haute', null, 'low', '9999-12-31 23:59:59.999999+00') $$,
    tests.id('G')),
  'due date 9999-12-31T23:59:59.999999Z is accepted');
select throws_ok(format($$ select public.create_task(%L, '', null, 'low', 'infinity') $$, tests.id('G')),
  'P0001', 'invalid_title', 'the title is validated before the due date');
select throws_ok(format($$ select public.create_task(%L, 'Infini', null, 'low', 'infinity', array[%L]::uuid[]) $$,
    tests.id('G'), tests.id('outsider')),
  'P0001', 'invalid_due_at', 'the due date is validated before the assignees');
select throws_ok(format($$ insert into public.tasks (group_id, title, due_at) values (%L, 'Directe', 'infinity') $$, tests.id('G')),
  'P0001', 'invalid_due_at', 'direct inserts are validated too');

select tests.as_user('creator');
insert into tests.ids select 'C1', id from public.create_task(tests.id('G'), '  Titre  ', E'  Détails\n ');
insert into tests.ids select 'C2', id from public.create_task(tests.id('G'), 'Sans détails', '   ', null);
select results_eq(
  $$ select title, details, status::text, priority::text, due_at, completed_at, created_by, created_at, updated_at
     from public.tasks where id = tests.id('C1') $$,
  $$ values ('Titre', 'Détails', 'todo', 'medium', null::timestamptz, null::timestamptz, tests.id('creator'), now(), now()) $$,
  'create_task trims, applies defaults and sets the server-maintained fields');
select results_eq(
  $$ select details, priority::text from public.tasks where id = tests.id('C2') $$,
  $$ values (null::text, 'medium') $$,
  'blank details are stored as NULL; a NULL priority falls back to medium');

-- Assignees on create -------------------------------------------------------------------------------------------
select throws_ok(format($$ select public.create_task(%L, 'Trop', null, 'low', null, %L::uuid[]) $$,
    tests.id('G'), tests.members(1, 21)),
  'P0001', 'too_many_assignees', '21 assignees are too many');
select tests.as_postgres();
select is((select count(*)::int from public.tasks where title = 'Trop'), 0, 'create_task is atomic (no task left behind)');
select tests.as_user('creator');
insert into tests.ids select 'C20', id
from public.create_task(tests.id('G'), 'Vingt', null, 'high', now() + interval '1 day', tests.members(1, 20));
select is(cardinality(tests.assignees('C20')), 20, '20 assignees are accepted');
insert into tests.ids select 'Cdup', id
from public.create_task(tests.id('G'), 'Doublons', null, 'high', null, tests.members(1, 20) || tests.id('m1') || null::uuid);
select is(cardinality(tests.assignees('Cdup')), 20, 'duplicates and NULLs are ignored (20 distinct users)');
select throws_ok(format($$ select public.create_task(%L, 'Externe', null, 'low', null, array[%L]::uuid[]) $$,
    tests.id('G'), tests.id('outsider')),
  'P0001', 'assignee_not_member', 'a non-member cannot be assigned');
select throws_ok(format($$ select public.create_task(%L, 'Inconnu', null, 'low', null, array[%L]::uuid[]) $$,
    tests.id('G'), gen_random_uuid()),
  'P0001', 'assignee_not_member', 'an unknown user cannot be assigned');
select results_eq(
  $$ select count(*)::int, min(assigned_by::text), max(assigned_by::text), min(assigned_at), max(assigned_at)
     from public.task_assignees where task_id = tests.id('C20') $$,
  $$ values (20, tests.id('creator')::text, tests.id('creator')::text, now(), now()) $$,
  'new assignments have assigned_by = caller and assigned_at = now()');

-- set_task_assignees keeps existing rows -------------------------------------------------------------------------
select tests.as_postgres();
select tests.create_task('R', 'G', 'creator');
insert into public.task_assignees (task_id, group_id, user_id, assigned_by, assigned_at)
values (tests.id('R'), tests.id('G'), tests.id('m1'), tests.id('admin'), '2026-01-01');
select tests.as_user('creator');
select lives_ok(format($$ select public.set_task_assignees(%L, %L::uuid[]) $$, tests.id('R'), tests.members(1, 2)),
  'the creator replaces the assignees with m1, m2');
select results_eq(
  $$ select user_id, assigned_by, assigned_at from public.task_assignees where task_id = tests.id('R') order by assigned_at $$,
  $$ values (tests.id('m1'), tests.id('admin'), '2026-01-01'::timestamptz), (tests.id('m2'), tests.id('creator'), now()) $$,
  'the retained row keeps assigned_at/assigned_by; the new row gets the caller and now()');
select lives_ok(format($$ select public.set_task_assignees(%L, %L::uuid[]) $$, tests.id('R'), tests.members(2, 2)),
  'replace with m2 only');
select is(tests.assignees('R'), tests.members(2, 2), 'm1 was removed');
select throws_ok(format($$ select public.set_task_assignees(%L, %L::uuid[]) $$, tests.id('R'), tests.members(1, 21)),
  'P0001', 'too_many_assignees', 'set_task_assignees: 21 is too many');
select throws_ok(format($$ select public.set_task_assignees(%L, array[%L, %L]::uuid[]) $$,
    tests.id('R'), tests.id('m3'), tests.id('outsider')),
  'P0001', 'assignee_not_member', 'set_task_assignees: members only');
select is(tests.assignees('R'), tests.members(2, 2), 'a rejected replacement changes nothing');
select throws_ok(format($$ select public.set_task_assignees(%L, '{}') $$, gen_random_uuid()),
  'P0001', 'task_not_found', 'set_task_assignees: unknown task');
select lives_ok(format($$ select public.set_task_assignees(%L, null) $$, tests.id('R')), 'NULL clears the assignees');
select is(tests.assignees('R'), '{}'::uuid[], 'no assignee left');
select tests.as_postgres();
select throws_ok(format($$ insert into public.task_assignees (task_id, group_id, user_id) values (%L, %L, %L) $$,
    tests.id('R'), tests.id('G'), tests.id('outsider')),
  '23503', null, 'the (group_id, user_id) foreign key forbids assigning a non-member, even for trusted code');

-- update_task ------------------------------------------------------------------------------------------------------
update public.tasks set updated_at = '2000-01-01' where id = tests.id('C20');
select tests.as_user('creator');
select results_eq(
  format($$ select title, details, priority::text, due_at, updated_at
            from public.update_task(%L, ' Nouveau titre ', '', 'low', '2030-01-01T10:00:00+02:00', %L::uuid[]) $$,
         tests.id('C20'), tests.members(5, 6)),
  $$ values ('Nouveau titre', null::text, 'low', '2030-01-01 08:00:00+00'::timestamptz, now()) $$,
  'update_task edits every field and maintains updated_at');
select is(tests.assignees('C20'), tests.members(5, 6), 'update_task replaces the assignees');
select is(
  (select due_at from public.update_task(tests.id('C20'), 'Nouveau titre', null, 'low', null, null)),
  null, 'a NULL due date clears it');
select is(tests.assignees('C20'), tests.members(5, 6), 'NULL assignee ids leave the assignees unchanged');
select lives_ok(format($$ select public.update_task(%L, 'Nouveau titre', null, 'low', null, '{}') $$, tests.id('C20')),
  'update_task with an empty assignee array');
select is(tests.assignees('C20'), '{}'::uuid[], 'an empty array clears the assignees');
select throws_ok(format($$ select public.update_task(%L, '  ', null, 'low', null, '{}') $$, tests.id('C20')),
  'P0001', 'invalid_title', 'update_task validates the title');
select throws_ok(format($$ select public.update_task(%L, 'Ok', %L, 'low', null, '{}') $$, tests.id('C20'), repeat('d', 5001)),
  'P0001', 'invalid_details', 'update_task validates the details');
select throws_ok(format($$ select public.update_task(%L, 'Ok', null, 'low', 'infinity', null) $$, tests.id('C20')),
  'P0001', 'invalid_due_at', 'update_task validates the due date');
select throws_ok(format($$ select public.update_task(%L, 'Changé', null, 'high', null, array[%L]::uuid[]) $$,
    tests.id('C20'), tests.id('outsider')),
  'P0001', 'assignee_not_member', 'update_task validates the assignees');
select is((tests.task('C20')).title, 'Nouveau titre', 'a rejected update_task changes nothing (atomic)');
select throws_ok(format($$ select public.update_task(%L, 'X', null, 'low', null, '{}') $$, gen_random_uuid()),
  'P0001', 'task_not_found', 'update_task: unknown task');

-- completed_at invariant -----------------------------------------------------------------------------------------------
select is((public.set_task_status(tests.id('C1'), 'done')).completed_at, now(), 'done sets completed_at = now()');
select tests.as_postgres();
update public.tasks set completed_at = '2026-01-02' where id = tests.id('C1');
select tests.as_user('creator');
select is((public.set_task_status(tests.id('C1'), 'done')).completed_at, '2026-01-02'::timestamptz,
  'done → done keeps the original completed_at');
select lives_ok(format($$ update public.tasks set title = 'Titre modifié' where id = %L $$, tests.id('C1')),
  'editing a done task');
select is((tests.task('C1')).completed_at, '2026-01-02'::timestamptz, 'editing a done task keeps completed_at');
select is((public.set_task_status(tests.id('C1'), 'in_progress')).completed_at, null, 'leaving done clears completed_at');
select is(tests.affected(format($$ update public.tasks set status = 'done' where id = %L $$, tests.id('C1'))), 1,
  'direct status update to done');
select is((tests.task('C1')).completed_at, now(), 'the trigger also sets completed_at on direct updates');
select throws_ok(format($$ update public.tasks set title = '' where id = %L $$, tests.id('C1')),
  'P0001', 'invalid_title', 'direct updates are validated too');
select throws_ok(format($$ update public.tasks set due_at = '-infinity' where id = %L $$, tests.id('C1')),
  'P0001', 'invalid_due_at', 'direct due date updates are validated too');
select is(
  (select count(*)::int from public.tasks where (status = 'done') <> (completed_at is not null)),
  0, 'invariant holds for every visible task');

select tests.as_postgres();
alter table public.tasks disable trigger tasks_before_update;
select throws_ok(format($$ update public.tasks set completed_at = null where id = %L $$, tests.id('C1')),
  '23514', null, 'the check constraint (status = done) = (completed_at is not null) is the last line of defense');
alter table public.tasks enable trigger tasks_before_update;
alter table public.tasks disable trigger tasks_before_insert;
select throws_ok(format($$ insert into public.tasks (group_id, title, due_at) values (%L, 'Sans trigger', 'infinity') $$,
    tests.id('G')),
  '23514', null, 'the due_at range check constraint is the last line of defense');
alter table public.tasks enable trigger tasks_before_insert;
insert into public.tasks (group_id, title, status, completed_at, created_by)
values (tests.id('G'), 'Incohérente', 'todo', now(), tests.id('admin'));
select is((select completed_at from public.tasks where title = 'Incohérente'), null,
  'completed_at is cleared on insert when the task is not done');

-- Immutable fields (trigger, even for trusted code) ------------------------------------------------------------------
select throws_ok(format($$ update public.tasks set created_by = %L where id = %L $$, tests.id('admin'), tests.id('C1')),
  '42501', 'immutable_field', 'created_by cannot be reassigned');
select lives_ok(format($$ update public.tasks set created_by = null where id = %L $$, tests.id('C2')),
  'created_by can become NULL (ON DELETE SET NULL)');
select throws_ok(format($$ update public.tasks set group_id = gen_random_uuid() where id = %L $$, tests.id('C1')),
  '42501', 'immutable_field', 'a task cannot move to another group');
select throws_ok(format($$ update public.tasks set created_at = now() - interval '1 day' where id = %L $$, tests.id('C1')),
  '42501', 'immutable_field', 'created_at is immutable');

-- A creator whose created_by became NULL is no longer an editor; the admin still is.
select tests.as_user('creator');
select throws_ok(format($$ select public.update_task(%L, 'Orpheline', null, 'low', null, '{}') $$, tests.id('C2')),
  '42501', 'forbidden', 'a task without creator can only be edited by admins');
select tests.as_user('admin');
select is((select title from public.update_task(tests.id('C2'), 'Orpheline', null, 'low', null, '{}')), 'Orpheline',
  'the admin edits a task without creator');

select * from finish();
rollback;
