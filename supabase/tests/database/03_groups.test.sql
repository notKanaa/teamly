-- Groups: create_group, rename_group, delete_group (+ no direct writes).
begin;
select plan(32);

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

select tests.create_user('alice');
select tests.create_user('bob');
select tests.create_user('eve');

-- not_authenticated: role authenticated but no `sub` claim.
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok($$ select public.create_group('Sans compte') $$, 'P0001', 'not_authenticated',
  'create_group without a user raises not_authenticated');
select tests.as_postgres();

-- create_group ------------------------------------------------------------------------------------------
select tests.as_user('alice');
select throws_ok($$ select public.create_group('') $$, 'P0001', 'invalid_name', 'empty name is rejected');
select throws_ok($$ select public.create_group(E' \t\n ') $$, 'P0001', 'invalid_name', 'blank name is rejected');
select throws_ok($$ select public.create_group(null) $$, 'P0001', 'invalid_name', 'NULL name is rejected');
select throws_ok(format($$ select public.create_group(%L) $$, repeat('g', 61)), 'P0001', 'invalid_name',
  '61-char name is rejected');
select lives_ok(format($$ select public.create_group(%L) $$, repeat('g', 60)), '60-char name is accepted');

insert into tests.results select 'coloc', to_jsonb(g) from public.create_group('  Coloc  ') as g;
insert into tests.ids select 'coloc', (value ->> 'id')::uuid from tests.results where name = 'coloc';

select is((select value ->> 'name' from tests.results where name = 'coloc'), 'Coloc',
  'create_group trims the name and returns the groups row');
select is((select (value ->> 'created_by')::uuid from tests.results where name = 'coloc'), tests.id('alice'),
  'created_by is the caller');
select is((select (value ->> 'last_activity_at')::timestamptz from tests.results where name = 'coloc'), now(),
  'last_activity_at is set');
select results_eq(
  $$ select user_id, role::text from public.group_members where group_id = tests.id('coloc') $$,
  $$ values (tests.id('alice'), 'admin') $$,
  'the creator is the only member, as admin');
select matches(
  (select code from public.group_invites where group_id = tests.id('coloc')),
  '^[A-HJ-NP-Z2-9]{8}$', 'an invite code is created (8 chars of the unambiguous alphabet)');
select is(
  (select count(*)::int from public.groups where id = tests.id('coloc')),
  1, 'the creator sees the new group');
select throws_ok($$ insert into public.groups (name) values ('Direct') $$, '42501',
  'permission denied for table groups', 'groups cannot be inserted directly');

select tests.as_user('eve');
select is((select count(*)::int from public.groups where id = tests.id('coloc')), 0, 'a non-member does not see the group');
select is((select count(*)::int from public.group_members where group_id = tests.id('coloc')), 0,
  'a non-member does not see the members');

select tests.as_postgres();
select tests.add_member('coloc', 'bob');

-- rename_group ------------------------------------------------------------------------------------------
select tests.as_user('bob');
select throws_ok(format($$ select public.rename_group(%L, 'Pirate') $$, tests.id('coloc')), '42501', 'forbidden',
  'a member cannot rename the group');
select tests.as_user('eve');
select throws_ok(format($$ select public.rename_group(%L, 'Pirate') $$, tests.id('coloc')), '42501', 'forbidden',
  'a non-member cannot rename the group');
select throws_ok(format($$ select public.rename_group(%L, 'Pirate') $$, gen_random_uuid()), 'P0001', 'group_not_found',
  'renaming an unknown group raises group_not_found');

select tests.as_postgres();
update public.groups set last_activity_at = '2000-01-01' where id = tests.id('coloc');
select tests.as_user('alice');
select throws_ok(format($$ select public.rename_group(%L, '   ') $$, tests.id('coloc')), 'P0001', 'invalid_name',
  'rename rejects a blank name');
select is((public.rename_group(tests.id('coloc'), '  Coloc des Lilas ')).name, 'Coloc des Lilas',
  'the admin renames the group (trimmed)');
select is((select last_activity_at from public.groups where id = tests.id('coloc')), now(),
  'rename bumps last_activity_at');
select throws_ok(format($$ update public.groups set name = 'Direct' where id = %L $$, tests.id('coloc')), '42501',
  'permission denied for table groups', 'groups cannot be updated directly, even by an admin');
select throws_ok(format($$ delete from public.groups where id = %L $$, tests.id('coloc')), '42501',
  'permission denied for table groups', 'groups cannot be deleted directly, even by an admin');

-- delete_group ------------------------------------------------------------------------------------------
select tests.as_postgres();
select tests.create_task('Vaisselle', 'coloc', 'bob', array['alice', 'bob']);

select tests.as_user('bob');
select throws_ok(format($$ select public.delete_group(%L) $$, tests.id('coloc')), '42501', 'forbidden',
  'a member cannot delete the group');
select tests.as_user('eve');
select throws_ok(format($$ select public.delete_group(%L) $$, tests.id('coloc')), '42501', 'forbidden',
  'a non-member cannot delete the group');
select tests.as_user('alice');
select throws_ok(format($$ select public.delete_group(%L) $$, gen_random_uuid()), 'P0001', 'group_not_found',
  'deleting an unknown group raises group_not_found');
select lives_ok(format($$ select public.delete_group(%L) $$, tests.id('coloc')), 'the admin deletes the group');

select tests.as_postgres();
select is((select count(*)::int from public.groups where id = tests.id('coloc')), 0, 'the group is gone');
select is((select count(*)::int from public.group_members where group_id = tests.id('coloc')), 0,
  'memberships are cascaded');
select is((select count(*)::int from public.tasks where group_id = tests.id('coloc')), 0, 'tasks are cascaded');
select is((select count(*)::int from public.task_assignees where group_id = tests.id('coloc')), 0,
  'assignments are cascaded');
select is((select count(*)::int from public.group_invites where group_id = tests.id('coloc')), 0,
  'the invite code is cascaded');

select * from finish();
rollback;
