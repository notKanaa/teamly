-- v2 checklists (docs/CONTRACTS-V2.md §2, §3, §4, §5): the four checklist RPCs, their permission matrix, limits and
-- check order, done_at / done_by, group bumps, no write quota, RLS, and create_task's p_checklist.
begin;
select plan(73);

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

-- add_checklist_item as the current user; the item is named p_item.
create function tests.add(p_item text, p_task text, p_title text) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  select i.id into v_id from public.add_checklist_item(tests.id(p_task), p_title) i;
  insert into tests.ids values (p_item, v_id);
  return v_id;
end $$;
create function tests.item(p_name text) returns public.task_checklist_items language sql security definer as $$
  select * from public.task_checklist_items where id = tests.id(p_name)
$$;
create function tests.items(p_task text) returns text language sql security definer as $$
  select coalesce(string_agg(title || '@' || position || case when done then '✓' else '' end, ',' order by position), '')
  from public.task_checklist_items where task_id = tests.id(p_task)
$$;
create function tests.rewind() returns void language sql security definer as $$
  update public.groups set last_activity_at = '2000-01-01' where id = tests.id('G');
$$;
create function tests.bumped() returns boolean language sql security definer as $$
  select last_activity_at = now() from public.groups where id = tests.id('G');
$$;
create function tests.call(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;

select tests.create_user(u) from unnest(array['admin', 'creator', 'assignee', 'other', 'stranger', 'leaver', 'doer']) as u;
select tests.create_group('G', 'admin');
select tests.add_member('G', u) from unnest(array['creator', 'assignee', 'other', 'leaver', 'doer']) as u;
select tests.create_group('G2', 'stranger');
select tests.create_task('T', 'G', 'creator', array['assignee', 'doer']);
select tests.create_task('TL', 'G', 'leaver', array['assignee']);
select tests.as_user('leaver');
select public.leave_group(tests.id('G'));
select tests.as_postgres();

-- add_checklist_item: permission matrix (« change status » rights, §4) -----------------------------------------------
select tests.as_user('admin');
select tests.add('A1', 'T', 'Par admin');
select tests.as_user('creator');
select tests.add('A2', 'T', '  Par créateur  ');
select tests.as_user('assignee');
select tests.add('A3', 'T', 'Par assigné');
select is(tests.items('T'), 'Par admin@1,Par créateur@2,Par assigné@3', 'admin, creator and assignee add items: positions 1, 2, 3; trimmed');
select tests.as_user('other');
select throws_ok(format($$ select public.add_checklist_item(%L, 'Intrus') $$, tests.id('T')), '42501', 'forbidden',
  'add: another member is forbidden');
select throws_ok(format($$ select public.add_checklist_item(%L, '') $$, tests.id('T')), '42501', 'forbidden',
  'add: the permission is checked before the title');
select tests.as_user('stranger');
select throws_ok(format($$ select public.add_checklist_item(%L, 'Intrus') $$, tests.id('T')), 'P0001', 'task_not_found',
  'add: a non-member gets task_not_found');
select tests.as_user('leaver');
select throws_ok(format($$ select public.add_checklist_item(%L, 'Ancien') $$, tests.id('TL')), 'P0001', 'task_not_found',
  'add: a creator who left gets task_not_found');
select tests.as_user('admin');
select throws_ok(format($$ select public.add_checklist_item(%L, 'X') $$, gen_random_uuid()), 'P0001', 'task_not_found',
  'add: an unknown task');
select results_eq(
  $$ select i.task_id, i.group_id, i.done, i.done_at, i.done_by, i.created_at from public.task_checklist_items i
     where i.id = tests.id('A1') $$,
  $$ values (tests.id('T'), tests.id('G'), false, null::timestamptz, null::uuid, now()) $$,
  'add returns an unchecked item of the task''s group');

-- Titles (§3) and limits.
select is(tests.call(format($$ select public.add_checklist_item(%L, '') $$, tests.id('T'))), 'invalid_item_title', 'add: empty title');
select is(tests.call(format($$ select public.add_checklist_item(%L, E' \n ') $$, tests.id('T'))), 'invalid_item_title', 'add: blank title');
select is(tests.call(format($$ select public.add_checklist_item(%L, null) $$, tests.id('T'))), 'invalid_item_title', 'add: NULL title');
select is(tests.call(format($$ select public.add_checklist_item(%L, %L) $$, tests.id('T'), repeat('é', 201))), 'invalid_item_title',
  'add: 201 characters');
select is(tests.call(format($$ select public.add_checklist_item(%L, %L) $$, tests.id('T'), repeat('é', 200))), 'ok',
  'add: 200 characters are accepted');
select tests.as_postgres();
select tests.rewind();
select tests.as_user('assignee');
select public.add_checklist_item(tests.id('T'), 'Item ' || i) from generate_series(5, 30) as i;
select is((select count(*)::int from public.task_checklist_items where task_id = tests.id('T')), 30, '30 items');
select throws_ok(format($$ select public.add_checklist_item(%L, 'Trente et un') $$, tests.id('T')), 'P0001', 'too_many_items',
  'add: the 31st item is refused');
select throws_ok(format($$ select public.add_checklist_item(%L, '  ') $$, tests.id('T')), 'P0001', 'invalid_item_title',
  'add: the title is checked before the count');
select ok(tests.bumped(), 'adding items bumps the group');

-- delete_checklist_item: the positions of the others are kept; the next add takes max + 1.
select tests.as_user('creator');
select public.delete_checklist_item(tests.id('A2'));
select results_eq(
  $$ select position from public.task_checklist_items where task_id = tests.id('T') and position <= 4 order by position $$,
  $$ values (1), (3), (4) $$,
  'delete: the other positions are kept (gap at 2)');
select public.delete_checklist_item(i.id) from public.task_checklist_items i where i.task_id = tests.id('T') and i.position between 5 and 30;
select tests.add('A31', 'T', 'Après suppression');
select is((tests.item('A31')).position, 5, 'add after deletions: max + 1 (4 + 1)');
select tests.as_user('other');
select throws_ok(format($$ select public.delete_checklist_item(%L) $$, tests.id('A1')), '42501', 'forbidden', 'delete: another member');
select tests.as_user('stranger');
select throws_ok(format($$ select public.delete_checklist_item(%L) $$, tests.id('A1')), 'P0001', 'item_not_found', 'delete: a non-member');
select throws_ok(format($$ select public.delete_checklist_item(%L) $$, gen_random_uuid()), 'P0001', 'item_not_found', 'delete: an unknown item');
select tests.as_user('assignee');
select lives_ok(format($$ select public.delete_checklist_item(%L) $$, tests.id('A31')), 'delete: an assignee');
select tests.as_user('admin');
select lives_ok(format($$ select public.delete_checklist_item(%L) $$, tests.id('A3')), 'delete: an admin');
select is(tests.items('T'), 'Par admin@1,' || repeat('é', 200) || '@4', 'two items left');

-- rename_checklist_item ---------------------------------------------------------------------------------------------------
select tests.as_postgres();
select tests.rewind();
select tests.as_user('assignee');
select results_eq(
  format($$ select id, title, position from public.rename_checklist_item(%L, '  Renommé  ') $$, tests.id('A1')),
  format($$ values (%L::uuid, 'Renommé', 1) $$, tests.id('A1')),
  'rename by an assignee: trimmed, position kept');
select ok(tests.bumped(), 'rename bumps the group');
select tests.as_user('creator');
select lives_ok(format($$ select public.rename_checklist_item(%L, 'Par le créateur') $$, tests.id('A1')), 'rename: the creator');
select tests.as_user('admin');
select lives_ok(format($$ select public.rename_checklist_item(%L, 'Par l''admin') $$, tests.id('A1')), 'rename: an admin');
select throws_ok(format($$ select public.rename_checklist_item(%L, '') $$, tests.id('A1')), 'P0001', 'invalid_item_title', 'rename: empty title');
select throws_ok(format($$ select public.rename_checklist_item(%L, %L) $$, tests.id('A1'), repeat('x', 201)), 'P0001', 'invalid_item_title',
  'rename: 201 characters');
select throws_ok(format($$ select public.rename_checklist_item(%L, 'X') $$, gen_random_uuid()), 'P0001', 'item_not_found',
  'rename: an unknown item');
select tests.as_user('other');
select throws_ok(format($$ select public.rename_checklist_item(%L, '') $$, tests.id('A1')), '42501', 'forbidden',
  'rename: another member (permission before title)');
select tests.as_user('stranger');
select throws_ok(format($$ select public.rename_checklist_item(%L, '') $$, tests.id('A1')), 'P0001', 'item_not_found',
  'rename: a non-member gets item_not_found (before the title)');

-- set_checklist_item_done ---------------------------------------------------------------------------------------------------
select tests.as_postgres();
select tests.rewind();
select tests.as_user('doer');
select results_eq(
  format($$ select done, done_at, done_by from public.set_checklist_item_done(%L, true) $$, tests.id('A1')),
  format($$ values (true, now(), %L::uuid) $$, tests.id('doer')),
  'checking an item sets done_at and done_by');
select ok(tests.bumped(), 'checking bumps the group');
select tests.as_postgres();
update public.task_checklist_items set done_at = '2026-01-01' where id = tests.id('A1');
select tests.rewind();
select tests.as_user('creator');
select results_eq(
  format($$ select done, done_at, done_by from public.set_checklist_item_done(%L, true) $$, tests.id('A1')),
  format($$ values (true, '2026-01-01'::timestamptz, %L::uuid) $$, tests.id('doer')),
  'the same value is a no-op (done_at and done_by kept)');
select ok(not tests.bumped(), 'a no-op writes nothing (no bump)');
select results_eq(
  format($$ select done, done_at, done_by from public.set_checklist_item_done(%L, false) $$, tests.id('A1')),
  $$ values (false, null::timestamptz, null::uuid) $$,
  'unchecking clears done_at and done_by');
select throws_ok(format($$ select public.set_checklist_item_done(%L, null) $$, tests.id('A1')), '23502', 'invalid_input',
  'a NULL value is refused');
select tests.as_user('other');
select throws_ok(format($$ select public.set_checklist_item_done(%L, true) $$, tests.id('A1')), '42501', 'forbidden',
  'check: another member');
select throws_ok(format($$ select public.set_checklist_item_done(%L, null) $$, tests.id('A1')), '42501', 'forbidden',
  'check: the permission comes before the NULL check');
select tests.as_user('stranger');
select throws_ok(format($$ select public.set_checklist_item_done(%L, true) $$, tests.id('A1')), 'P0001', 'item_not_found',
  'check: a non-member');
select tests.as_user('admin');
select lives_ok(format($$ select public.set_checklist_item_done(%L, true) $$, tests.id('A1')), 'check: an admin');

-- The write quota does not apply to checklist items (§5).
select tests.as_postgres();
update private.settings set value = '0' where key = 'quota_tasks_per_hour';
insert into tests.results values ('log', to_jsonb((select count(*) from private.write_log)));
select tests.as_user('creator');
select lives_ok(format($$ select public.add_checklist_item(%L, 'Sans quota') $$, tests.id('T')), 'adding an item with a task quota of 0');
select tests.as_postgres();
select is((select count(*)::int from private.write_log), (select (value #>> '{}')::int from tests.results where name = 'log'),
  'checklist writes are not logged by the write quota');
update private.settings set value = '200' where key = 'quota_tasks_per_hour';

-- RLS and privileges (§2) ---------------------------------------------------------------------------------------------------
select tests.as_user('other');
select is((select count(*)::int from public.task_checklist_items where task_id = tests.id('T')), 3, 'members read the items');
select tests.as_user('stranger');
select is((select count(*)::int from public.task_checklist_items where task_id = tests.id('T')), 0, 'non-members read nothing');
select tests.as_user('creator');
select throws_ok(format($$ insert into public.task_checklist_items (task_id, group_id, title, position) values (%L, %L, 'X', 99) $$,
    tests.id('T'), tests.id('G')),
  '42501', 'permission denied for table task_checklist_items', 'no direct INSERT');
select throws_ok(format($$ update public.task_checklist_items set done = true where id = %L $$, tests.id('A1')),
  '42501', 'permission denied for table task_checklist_items', 'no direct UPDATE');
select throws_ok(format($$ delete from public.task_checklist_items where id = %L $$, tests.id('A1')),
  '42501', 'permission denied for table task_checklist_items', 'no direct DELETE');
select tests.as_anon();
select throws_ok(format($$ select public.add_checklist_item(%L, 'X') $$, tests.id('T')), '42501',
  'permission denied for function add_checklist_item', 'anon cannot call add_checklist_item');
select throws_ok($$ select count(*) from public.task_checklist_items $$, '42501',
  'permission denied for table task_checklist_items', 'anon cannot read items');
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok(format($$ select public.add_checklist_item(%L, 'X') $$, tests.id('T')), 'P0001', 'not_authenticated', 'add requires a user');
select throws_ok(format($$ select public.rename_checklist_item(%L, 'X') $$, tests.id('A1')), 'P0001', 'not_authenticated', 'rename requires a user');
select throws_ok(format($$ select public.set_checklist_item_done(%L, true) $$, tests.id('A1')), 'P0001', 'not_authenticated', 'check requires a user');
select throws_ok(format($$ select public.delete_checklist_item(%L) $$, tests.id('A1')), 'P0001', 'not_authenticated', 'delete requires a user');

-- create_task with a checklist (§3, §5) ----------------------------------------------------------------------------------------
select tests.as_user('other');
insert into tests.ids select 'C', id from public.create_task(tests.id('G'), 'Avec liste', null, 'medium', null, '{}', null, null,
  array['  Premier ', 'Deuxième', 'Troisième']);
select is(tests.items('C'), 'Premier@1,Deuxième@2,Troisième@3', 'create_task: items in order, positions 1…n, trimmed');
insert into tests.ids select 'C0', id from public.create_task(tests.id('G'), 'Liste vide', null, 'medium', null, '{}', null, null, '{}');
select is(tests.items('C0'), '', 'an empty checklist creates no item');
select is(tests.call(format($$ select public.create_task(%L, 'L', null, 'medium', null, '{}', null, null, array['Ok', '  ']) $$, tests.id('G'))),
  'invalid_item_title', 'create_task: a blank item');
select is(tests.call(format($$ select public.create_task(%L, 'L', null, 'medium', null, '{}', null, null, array['Ok', null]) $$, tests.id('G'))),
  'invalid_item_title', 'create_task: a NULL item');
select is(tests.call(format($$ select public.create_task(%L, 'L', null, 'medium', null, '{}', null, null, %L::text[]) $$,
    tests.id('G'), array_fill('x'::text, array[31]))),
  'too_many_items', 'create_task: 31 items');
select is(tests.call(format($$ select public.create_task(%L, 'L', null, 'medium', null, '{}', null, null, %L::text[]) $$,
    tests.id('G'), array_fill('x'::text, array[31]) || array[repeat('y', 201)])),
  'invalid_item_title', 'create_task: every title before the count');
select is(tests.call(format($$ select public.create_task(%L, 'L', null, 'medium', null, '{}', null, null, %L::text[]) $$,
    tests.id('G'), array_fill('x'::text, array[30]))),
  'ok', 'create_task: 30 items');
select is(tests.call(format($$ select public.create_task(%L, 'L', null, 'medium', null, array[%L]::uuid[], null, null, array['']) $$,
    tests.id('G'), tests.id('stranger'))),
  'assignee_not_member', 'create_task: assignees before the checklist');
select is(tests.call(format($$ select public.create_task(%L, 'L', null, 'medium', null, %L::uuid[], null, null, array['']) $$,
    tests.id('G'), (select array_agg(gen_random_uuid()) from generate_series(1, 21)))),
  'too_many_assignees', 'create_task: assignee count before the checklist');
select is(tests.call(format($$ select public.create_task(%L, '', null, 'medium', null, '{}', null, null, array['']) $$, tests.id('G'))),
  'invalid_title', 'create_task: the title first');
select tests.as_postgres();
select is((select count(*)::int from public.tasks where title = 'L'), 1, 'refused create_task calls leave nothing behind');

-- Bookkeeping ------------------------------------------------------------------------------------------------------------------
select throws_ok(format($$ update public.task_checklist_items set task_id = %L where id = %L $$, tests.id('C'), tests.id('A1')),
  '42501', 'immutable_field', 'an item cannot move to another task');
select throws_ok(format($$ update public.task_checklist_items set title = '' where id = %L $$, tests.id('A1')),
  'P0001', 'invalid_item_title', 'the trigger validates titles for trusted writes too');
alter table public.task_checklist_items disable trigger task_checklist_items_before_write;
select throws_ok(format($$ update public.task_checklist_items set done_at = null where id = %L $$, tests.id('A1')),
  '23514', null, 'check constraint done = (done_at is not null)');
alter table public.task_checklist_items enable trigger task_checklist_items_before_write;
delete from auth.users where id = tests.id('admin');
select is((tests.item('A1')).done_by, null, 'done_by becomes NULL when the account is deleted');
select ok((tests.item('A1')).done and (tests.item('A1')).done_at is not null, 'the item stays done');
select tests.as_user('other');
select public.delete_task(tests.id('C'));
select tests.as_postgres();
select is((select count(*)::int from public.task_checklist_items where task_id = tests.id('C')), 0, 'items are deleted with their task');

select * from finish();
rollback;
