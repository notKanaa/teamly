-- The full §2 task permission matrix, through the RPCs AND through direct table access (RLS + trigger +
-- column grants), for: admin, creator (member), assignee (member), other member, non-member, creator who
-- left the group. Rights are per group.
begin;
select plan(75);

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
select tests.create_user('assignee');
select tests.create_user('other');
select tests.create_user('stranger');
select tests.create_user('leaver');

select tests.create_group('G', 'admin');
select tests.add_member('G', 'creator');
select tests.add_member('G', 'assignee');
select tests.add_member('G', 'other');
select tests.add_member('G', 'leaver');
-- G2: stranger is its admin, admin of G is a plain member there.
select tests.create_group('G2', 'stranger');
select tests.add_member('G2', 'admin');

select tests.create_task('T', 'G', 'creator', array['assignee']);
select tests.create_task('TL', 'G', 'leaver', array['assignee']);
select tests.create_task('D1', 'G', 'creator', array['assignee']);
select tests.create_task('D2', 'G', 'creator', array['assignee']);
select tests.create_task('D3', 'G', 'creator', array['assignee']);
select tests.create_task('D4', 'G', 'creator', array['assignee']);
select tests.create_task('T2', 'G2', 'stranger', array['stranger']);

-- The creator of TL leaves the group: they keep no right on it.
select tests.as_user('leaver');
select public.leave_group(tests.id('G'));
select tests.as_postgres();

create function tests.visible(p_task text) returns text language sql as $$
  select format('task=%s assignees=%s',
    (select count(*) from public.tasks where id = tests.id(p_task)),
    (select count(*) from public.task_assignees where task_id = tests.id(p_task)))
$$;
create function tests.update_sql(p_task text, p_title text) returns text language sql as $$
  select format($f$ select public.update_task(%L, %L, 'Détails', 'high', now() + interval '1 day', array[%L]::uuid[]) $f$,
    tests.id(p_task), p_title, tests.id('assignee'))
$$;
create function tests.rpc(p_call text, p_task text, p_arg text default null) returns text language sql as $$
  select case p_call
    when 'assignees' then format($f$ select public.set_task_assignees(%L, %L::uuid[]) $f$, tests.id(p_task), p_arg)
    when 'status' then format($f$ select public.set_task_status(%L, %L) $f$, tests.id(p_task), p_arg)
    when 'delete' then format($f$ select public.delete_task(%L) $f$, tests.id(p_task))
  end
$$;
create function tests.direct(p_sql text, p_task text) returns integer language sql as $$
  select tests.affected(format(p_sql, tests.id(p_task)))
$$;

-- See group, members, all tasks -----------------------------------------------------------------------------
select tests.as_user('admin');
select is(tests.visible('T'), 'task=1 assignees=1', 'view: admin');
select tests.as_user('creator');
select is(tests.visible('T'), 'task=1 assignees=1', 'view: creator');
select tests.as_user('assignee');
select is(tests.visible('T'), 'task=1 assignees=1', 'view: assignee');
select tests.as_user('other');
select is(tests.visible('T'), 'task=1 assignees=1', 'view: other member');
select tests.as_user('stranger');
select is(tests.visible('T'), 'task=0 assignees=0', 'view: non-member sees nothing');
select tests.as_user('leaver');
select is(tests.visible('TL'), 'task=0 assignees=0', 'view: creator who left sees nothing');

-- Create task ------------------------------------------------------------------------------------------------
select tests.as_user('admin');
select is((public.create_task(tests.id('G'), 'Par admin')).created_by, tests.id('admin'), 'create: admin');
select tests.as_user('creator');
select is((public.create_task(tests.id('G'), 'Par créateur')).created_by, tests.id('creator'), 'create: creator');
select tests.as_user('assignee');
insert into tests.ids
select 'ByAssignee', id
from public.create_task(tests.id('G'), 'Par assigné', null, 'low', null,
                        array[tests.id('admin'), tests.id('other'), tests.id('assignee')]);
select is(
  (select count(*)::int from public.task_assignees where task_id = tests.id('ByAssignee')),
  3, 'create: assignee, assigning anyone in the group including self');
select tests.as_user('other');
select is((public.create_task(tests.id('G'), 'Par autre')).created_by, tests.id('other'), 'create: other member');
select tests.as_user('stranger');
select throws_ok(format($$ select public.create_task(%L, 'Intrus') $$, tests.id('G')), '42501', 'forbidden',
  'create: non-member is forbidden');
select tests.as_user('leaver');
select throws_ok(format($$ select public.create_task(%L, 'Intrus') $$, tests.id('G')), '42501', 'forbidden',
  'create: former member is forbidden');
-- Direct INSERT (RLS WITH CHECK + trigger-maintained created_by).
select tests.as_user('other');
select is(tests.affected(format($$ insert into public.tasks (group_id, title) values (%L, 'Direct') $$, tests.id('G'))), 1,
  'create (direct): a member can insert');
select is((select created_by from public.tasks where title = 'Direct' and group_id = tests.id('G')), tests.id('other'),
  'create (direct): created_by is forced to the caller');
select throws_ok(format($$ insert into public.tasks (group_id, title, created_by) values (%L, 'Usurpé', %L) $$,
    tests.id('G'), tests.id('admin')),
  '42501', 'permission denied for table tasks', 'create (direct): created_by cannot be supplied');
select tests.as_user('stranger');
select throws_ok(format($$ insert into public.tasks (group_id, title) values (%L, 'Intrus') $$, tests.id('G')),
  '42501', 'new row violates row-level security policy for table "tasks"', 'create (direct): non-member is rejected by RLS');

-- Edit task fields (update_task) ------------------------------------------------------------------------------
select tests.as_user('admin');
select is((select title from public.update_task(tests.id('T'), 'Par admin', 'Détails', 'high', null, array[tests.id('assignee')])),
  'Par admin', 'edit: admin');
select tests.as_user('creator');
select is((select title from public.update_task(tests.id('T'), 'Par créateur', null, 'low', null, array[tests.id('assignee')])),
  'Par créateur', 'edit: creator');
select tests.as_user('assignee');
select throws_ok(tests.update_sql('T', 'Par assigné'), '42501', 'forbidden', 'edit: assignee is forbidden');
select tests.as_user('other');
select throws_ok(tests.update_sql('T', 'Par autre'), '42501', 'forbidden', 'edit: other member is forbidden');
select tests.as_user('stranger');
select throws_ok(tests.update_sql('T', 'Par intrus'), 'P0001', 'task_not_found', 'edit: non-member gets task_not_found');
select tests.as_user('leaver');
select throws_ok(tests.update_sql('TL', 'Par ancien'), 'P0001', 'task_not_found',
  'edit: creator who left gets task_not_found');
select tests.as_user('admin');
select lives_ok(tests.update_sql('TL', 'Reprise par admin'), 'edit: admin can edit the task of a creator who left');
select throws_ok(tests.update_sql('T2', 'Par admin ailleurs'), '42501', 'forbidden',
  'edit: being admin of G gives nothing in G2');

-- Edit task fields (direct UPDATE) -------------------------------------------------------------------------------
select tests.as_user('admin');
select is(tests.direct($$ update public.tasks set title = 'Direct admin' where id = %L $$, 'T'), 1, 'edit (direct): admin');
select tests.as_user('creator');
select is(tests.direct($$ update public.tasks set title = 'Direct créateur' where id = %L $$, 'T'), 1, 'edit (direct): creator');
select tests.as_user('assignee');
select throws_ok(format($$ update public.tasks set title = 'Direct assigné' where id = %L $$, tests.id('T')),
  '42501', 'forbidden_fields', 'edit (direct): assignee changing the title → forbidden_fields');
select throws_ok(format($$ update public.tasks set priority = 'medium' where id = %L $$, tests.id('T')),
  '42501', 'forbidden_fields', 'edit (direct): assignee changing the priority → forbidden_fields');
select throws_ok(format($$ update public.tasks set due_at = now() where id = %L $$, tests.id('T')),
  '42501', 'forbidden_fields', 'edit (direct): assignee changing the due date → forbidden_fields');
select throws_ok(format($$ update public.tasks set details = 'Nouveau', status = 'done' where id = %L $$, tests.id('T')),
  '42501', 'forbidden_fields', 'edit (direct): assignee changing details along with status → forbidden_fields');
select tests.as_user('other');
select is(tests.direct($$ update public.tasks set title = 'Direct autre' where id = %L $$, 'T'), 0,
  'edit (direct): other member affects 0 rows');
select tests.as_user('stranger');
select is(tests.direct($$ update public.tasks set title = 'Direct intrus' where id = %L $$, 'T'), 0,
  'edit (direct): non-member affects 0 rows');
select tests.as_user('leaver');
select is(tests.direct($$ update public.tasks set title = 'Direct ancien' where id = %L $$, 'TL'), 0,
  'edit (direct): creator who left affects 0 rows');
select tests.as_user('admin');
select is(tests.direct($$ update public.tasks set title = 'Direct ailleurs' where id = %L $$, 'T2'), 0,
  'edit (direct): admin of G affects 0 rows in G2');
select throws_ok(format($$ update public.tasks set created_by = %L where id = %L $$, tests.id('admin'), tests.id('T')),
  '42501', 'permission denied for table tasks', 'edit (direct): created_by is not updatable');
select throws_ok(format($$ update public.tasks set completed_at = now() where id = %L $$, tests.id('T')),
  '42501', 'permission denied for table tasks', 'edit (direct): completed_at is not updatable');

-- Assignees (set_task_assignees) ----------------------------------------------------------------------------------
select tests.as_user('admin');
select lives_ok(tests.rpc('assignees', 'T', format('{%s,%s}', tests.id('assignee'), tests.id('admin'))), 'assignees: admin');
select tests.as_user('creator');
select lives_ok(tests.rpc('assignees', 'T', format('{%s}', tests.id('assignee'))), 'assignees: creator');
select tests.as_user('assignee');
select throws_ok(tests.rpc('assignees', 'T', '{}'), '42501', 'forbidden', 'assignees: assignee is forbidden');
select tests.as_user('other');
select throws_ok(tests.rpc('assignees', 'T', '{}'), '42501', 'forbidden', 'assignees: other member is forbidden');
select tests.as_user('stranger');
select throws_ok(tests.rpc('assignees', 'T', '{}'), 'P0001', 'task_not_found', 'assignees: non-member gets task_not_found');
select tests.as_user('leaver');
select throws_ok(tests.rpc('assignees', 'TL', '{}'), 'P0001', 'task_not_found',
  'assignees: creator who left gets task_not_found');
select tests.as_user('creator');
select throws_ok(format($$ insert into public.task_assignees (task_id, group_id, user_id) values (%L, %L, %L) $$,
    tests.id('T'), tests.id('G'), tests.id('other')),
  '42501', 'permission denied for table task_assignees', 'assignees (direct): no INSERT');
select tests.as_user('admin');
select throws_ok(format($$ delete from public.task_assignees where task_id = %L $$, tests.id('T')),
  '42501', 'permission denied for table task_assignees', 'assignees (direct): no DELETE');
select tests.as_postgres();
select results_eq(format($$ select user_id from public.task_assignees where task_id = %L $$, tests.id('T')),
  format($$ values (%L::uuid) $$, tests.id('assignee')), 'assignees: the denied attempts changed nothing');

-- Change task status (set_task_status) ------------------------------------------------------------------------------
select tests.as_user('admin');
select is((public.set_task_status(tests.id('T'), 'in_progress')).status::text, 'in_progress', 'status: admin');
select tests.as_user('creator');
select is((public.set_task_status(tests.id('T'), 'done')).status::text, 'done', 'status: creator');
select tests.as_user('assignee');
select is((public.set_task_status(tests.id('T'), 'todo')).status::text, 'todo', 'status: assignee');
select tests.as_user('other');
select throws_ok(tests.rpc('status', 'T', 'done'), '42501', 'forbidden', 'status: other member is forbidden');
select tests.as_user('stranger');
select throws_ok(tests.rpc('status', 'T', 'done'), 'P0001', 'task_not_found', 'status: non-member gets task_not_found');
select tests.as_user('leaver');
select throws_ok(tests.rpc('status', 'TL', 'done'), 'P0001', 'task_not_found',
  'status: creator who left gets task_not_found');
select tests.as_user('admin');
select throws_ok(tests.rpc('status', 'T2', 'done'), '42501', 'forbidden', 'status: being admin of G gives nothing in G2');

-- Change task status (direct UPDATE) -------------------------------------------------------------------------------
select tests.as_user('admin');
select is(tests.direct($$ update public.tasks set status = 'in_progress' where id = %L $$, 'T'), 1, 'status (direct): admin');
select tests.as_user('creator');
select is(tests.direct($$ update public.tasks set status = 'done' where id = %L $$, 'T'), 1, 'status (direct): creator');
select tests.as_user('assignee');
select is(tests.direct($$ update public.tasks set status = 'todo' where id = %L $$, 'T'), 1, 'status (direct): assignee');
select tests.as_user('other');
select is(tests.direct($$ update public.tasks set status = 'done' where id = %L $$, 'T'), 0,
  'status (direct): other member affects 0 rows');
select tests.as_user('stranger');
select is(tests.direct($$ update public.tasks set status = 'done' where id = %L $$, 'T'), 0,
  'status (direct): non-member affects 0 rows');
select tests.as_user('leaver');
select is(tests.direct($$ update public.tasks set status = 'done' where id = %L $$, 'TL'), 0,
  'status (direct): creator who left affects 0 rows');

-- Delete task (delete_task) -----------------------------------------------------------------------------------------
select tests.as_user('assignee');
select throws_ok(tests.rpc('delete', 'D1'), '42501', 'forbidden', 'delete: assignee is forbidden');
select tests.as_user('other');
select throws_ok(tests.rpc('delete', 'D1'), '42501', 'forbidden', 'delete: other member is forbidden');
select tests.as_user('stranger');
select throws_ok(tests.rpc('delete', 'D1'), 'P0001', 'task_not_found', 'delete: non-member gets task_not_found');
select tests.as_user('leaver');
select throws_ok(tests.rpc('delete', 'TL'), 'P0001', 'task_not_found', 'delete: creator who left gets task_not_found');
select tests.as_user('admin');
select throws_ok(tests.rpc('delete', 'T2'), '42501', 'forbidden', 'delete: being admin of G gives nothing in G2');
select throws_ok(format($$ select public.delete_task(%L) $$, gen_random_uuid()), 'P0001', 'task_not_found',
  'delete: unknown task gets task_not_found');
select tests.as_user('creator');
select lives_ok(tests.rpc('delete', 'D1'), 'delete: creator');
select tests.as_user('admin');
select lives_ok(tests.rpc('delete', 'D2'), 'delete: admin');

-- Delete task (direct DELETE) --------------------------------------------------------------------------------------
select tests.as_user('assignee');
select is(tests.direct($$ delete from public.tasks where id = %L $$, 'D3'), 0, 'delete (direct): assignee affects 0 rows');
select tests.as_user('other');
select is(tests.direct($$ delete from public.tasks where id = %L $$, 'D3'), 0, 'delete (direct): other member affects 0 rows');
select tests.as_user('stranger');
select is(tests.direct($$ delete from public.tasks where id = %L $$, 'D3'), 0, 'delete (direct): non-member affects 0 rows');
select tests.as_user('leaver');
select is(tests.direct($$ delete from public.tasks where id = %L $$, 'TL'), 0,
  'delete (direct): creator who left affects 0 rows');
select tests.as_user('creator');
select is(tests.direct($$ delete from public.tasks where id = %L $$, 'D3'), 1, 'delete (direct): creator');
select tests.as_user('admin');
select is(tests.direct($$ delete from public.tasks where id = %L $$, 'D4'), 1, 'delete (direct): admin');

select tests.as_postgres();
select is(
  (select count(*)::int from public.tasks where id in (tests.id('D1'), tests.id('D2'), tests.id('D3'), tests.id('D4'))),
  0, 'the four deletable tasks are gone');
select is(
  (select count(*)::int from public.tasks where id in (tests.id('T'), tests.id('TL'), tests.id('T2'))),
  3, 'the other tasks survived every denied attempt');
select is((select title from public.tasks where id = tests.id('TL')), 'Reprise par admin',
  'the task of the creator who left kept its admin edit only');

select * from finish();
rollback;
