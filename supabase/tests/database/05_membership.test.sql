-- Membership RPCs: set_member_role, remove_member, leave_group (last admin, last member) and the
-- "group always keeps an admin" heal trigger.
begin;
select plan(40);

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
select tests.create_user('carol');
select tests.create_user('dave');
select tests.create_user('eve');
select tests.create_group('G', 'alice');
select tests.add_member('G', 'bob');
select tests.add_member('G', 'carol');
select tests.add_member('G', 'dave');
select tests.create_task('Tâche de Bob', 'G', 'bob', array['bob', 'carol']);
select tests.create_task('Tâche de Carol', 'G', 'carol', array['bob', 'carol', 'dave']);

create function tests.role_of(p_group text, p_user text) returns text language sql as $$
  select role::text from public.group_members where group_id = tests.id(p_group) and user_id = tests.id(p_user)
$$;

-- set_member_role ------------------------------------------------------------------------------------------
select tests.as_user('bob');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, tests.id('G'), tests.id('carol')),
  '42501', 'forbidden', 'a member cannot change roles');
select tests.as_user('eve');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, tests.id('G'), tests.id('eve')),
  '42501', 'forbidden', 'a non-member cannot change roles');
select tests.as_user('alice');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, tests.id('G'), tests.id('eve')),
  'P0001', 'not_member', 'the target must be a member');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'member') $$, tests.id('G'), tests.id('alice')),
  'P0001', 'last_admin', 'the last admin cannot demote themselves');
select lives_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, tests.id('G'), tests.id('bob')),
  'the admin promotes bob');
select is(tests.role_of('G', 'bob'), 'admin', 'bob is admin');
select lives_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, tests.id('G'), tests.id('bob')),
  'setting the same role again is a no-op');
select lives_ok(format($$ select public.set_member_role(%L, %L, 'member') $$, tests.id('G'), tests.id('alice')),
  'an admin may demote themselves when another admin exists');
select is(tests.role_of('G', 'alice'), 'member', 'alice is member');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, tests.id('G'), tests.id('alice')),
  '42501', 'forbidden', 'once demoted, alice lost her admin rights');
select tests.as_user('bob');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'member') $$, tests.id('G'), tests.id('bob')),
  'P0001', 'last_admin', 'bob, now the only admin, cannot demote himself');
select lives_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, tests.id('G'), tests.id('alice')),
  'bob promotes alice back');
select throws_ok(format($$ update public.group_members set role = 'admin' where group_id = %L $$, tests.id('G')),
  '42501', 'permission denied for table group_members', 'roles cannot be changed directly');

-- remove_member -----------------------------------------------------------------------------------------------
select tests.as_user('carol');
select throws_ok(format($$ select public.remove_member(%L, %L) $$, tests.id('G'), tests.id('dave')),
  '42501', 'forbidden', 'a member cannot remove members');
select tests.as_user('alice');
select throws_ok(format($$ select public.remove_member(%L, %L) $$, tests.id('G'), tests.id('alice')),
  'P0001', 'cannot_remove_self', 'an admin cannot remove themselves');
select throws_ok(format($$ select public.remove_member(%L, %L) $$, tests.id('G'), tests.id('eve')),
  'P0001', 'not_member', 'the target must be a member');
select lives_ok(format($$ select public.remove_member(%L, %L) $$, tests.id('G'), tests.id('bob')),
  'an admin can remove another admin');
select is(tests.role_of('G', 'bob'), null, 'bob is no longer a member');
select tests.as_postgres();
select is((select count(*)::int from public.task_assignees where group_id = tests.id('G') and user_id = tests.id('bob')),
  0, 'bob''s assignments in the group are deleted');
select is((select created_by from public.tasks where id = tests.id('Tâche de Bob')), tests.id('bob'),
  'tasks bob created stay, with created_by kept');
select is((select count(*)::int from public.task_assignees where task_id = tests.id('Tâche de Bob')), 1,
  'other assignees of bob''s task are kept');
select tests.as_user('alice');
select throws_ok(format($$ delete from public.group_members where group_id = %L and user_id = %L $$,
    tests.id('G'), tests.id('dave')),
  '42501', 'permission denied for table group_members', 'memberships cannot be deleted directly');
select tests.as_user('bob');
select is((select count(*)::int from public.tasks where id = tests.id('Tâche de Bob')), 0,
  'the removed member no longer sees the group''s tasks');

-- leave_group -------------------------------------------------------------------------------------------------
select tests.as_user('eve');
select throws_ok(format($$ select public.leave_group(%L) $$, tests.id('G')), 'P0001', 'not_member',
  'a non-member cannot leave');
select tests.as_user('alice');
select throws_ok(format($$ select public.leave_group(%L) $$, tests.id('G')), 'P0001', 'last_admin',
  'the only admin cannot leave while other members remain');
select tests.as_user('dave');
select lives_ok(format($$ select public.leave_group(%L) $$, tests.id('G')), 'a member leaves');
select tests.as_postgres();
select is(tests.role_of('G', 'dave'), null, 'dave is gone');
select is((select count(*)::int from public.task_assignees where user_id = tests.id('dave')), 0,
  'dave''s assignments are deleted');
select tests.as_user('alice');
select lives_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, tests.id('G'), tests.id('carol')),
  'alice promotes carol');
select lives_ok(format($$ select public.leave_group(%L) $$, tests.id('G')), 'an admin leaves when another admin exists');
select tests.as_user('carol');
select lives_ok(format($$ select public.leave_group(%L) $$, tests.id('G')), 'the last member leaves');
select tests.as_postgres();
select is((select count(*)::int from public.groups where id = tests.id('G')), 0,
  'the group is deleted when its last member leaves');
select is((select count(*)::int from public.tasks where group_id = tests.id('G')), 0, 'with its tasks');

-- Heal trigger --------------------------------------------------------------------------------------------------
-- H: admin alice; members joined in this order: carol (oldest), bob, dave.
select tests.create_group('H', 'alice');
update public.group_members set joined_at = now() - interval '10 days' where group_id = tests.id('H');
select tests.add_member('H', 'bob', 'member', now() - interval '5 days');
select tests.add_member('H', 'carol', 'member', now() - interval '8 days');
select tests.add_member('H', 'dave', 'member', now() - interval '1 day');
delete from public.group_members where group_id = tests.id('H') and user_id = tests.id('alice');
select is(tests.role_of('H', 'carol'), 'admin', 'heal: the oldest remaining member is promoted');
select is(
  (select count(*)::int from public.group_members where group_id = tests.id('H') and role = 'admin'),
  1, 'heal: exactly one member is promoted');
delete from public.group_members where group_id = tests.id('H') and user_id = tests.id('dave');
select is(tests.role_of('H', 'bob'), 'member', 'heal: nothing happens while an admin remains');

-- Tie on joined_at → smallest user_id.
select tests.create_group('I', 'eve');
select tests.add_member('I', 'bob', 'member', '2026-01-01');
select tests.add_member('I', 'dave', 'member', '2026-01-01');
delete from public.group_members where group_id = tests.id('I') and user_id = tests.id('eve');
select is(
  (select user_id from public.group_members where group_id = tests.id('I') and role = 'admin'),
  least(tests.id('bob'), tests.id('dave')), 'heal: ties on joined_at are broken by user_id');

-- Group deletion: the heal trigger is a no-op.
select lives_ok(format($$ delete from public.groups where id = %L $$, tests.id('H')),
  'deleting a group with members works (heal trigger no-op)');
select is((select count(*)::int from public.group_members where group_id = tests.id('H')), 0, 'members are cascaded');

-- A member removed by cascade from a profile deletion also heals (sole admin deleted from auth).
select tests.create_group('J', 'dave');
select tests.add_member('J', 'bob', 'member', now() - interval '2 days');
select tests.add_member('J', 'carol', 'member', now() - interval '3 days');
delete from auth.users where id = tests.id('dave');
select is(tests.role_of('J', 'carol'), 'admin', 'heal: deleting the only admin''s account promotes the oldest member');

select * from finish();
rollback;
