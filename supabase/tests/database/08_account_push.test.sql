-- delete_my_account (group deletion / oldest member promotion / SET NULL references) and
-- enable_push / disable_push.
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

select tests.create_user('x');
select tests.create_user('y');
select tests.create_user('z');
select tests.create_user('p');
select tests.create_user('q');
select tests.create_user('w');
select tests.create_user('m');
select tests.create_user('boss');

-- G1: x is the only member.
select tests.create_group('G1', 'x');
-- G2: x is the only admin; y joined before z.
select tests.create_group('G2', 'x');
select tests.add_member('G2', 'z', 'member', now() - interval '2 days');
select tests.add_member('G2', 'y', 'member', now() - interval '5 days');
-- G3: x is the only admin; p and q joined at the same time (tie broken by user_id).
select tests.create_group('G3', 'x');
select tests.add_member('G3', 'p', 'member', '2026-01-01');
select tests.add_member('G3', 'q', 'member', '2026-01-01');
-- G4: another admin exists.
select tests.create_group('G4', 'x');
select tests.add_member('G4', 'w', 'admin', now() - interval '9 days');
select tests.add_member('G4', 'm', 'member', now() - interval '10 days');
-- G5: x is a plain member.
select tests.create_group('G5', 'boss');
select tests.add_member('G5', 'x');

select tests.create_task('Tâche de x', 'G2', 'x', array['y', 'x']);
select tests.create_task('Tâche de y', 'G2', 'y', array['x']);
select tests.create_task('Tâche perso', 'G1', 'x', array['x']);
update public.task_assignees set assigned_by = tests.id('x') where task_id = tests.id('Tâche de y');

insert into public.push_subscriptions (user_id, topic) values (tests.id('x'), 'equipe-abcdefghijklmnopqrstuvwx');
insert into private.join_attempts (user_id, succeeded) values (tests.id('x'), false), (tests.id('x'), true);

create function tests.role_of(p_group text, p_user text) returns text language sql as $$
  select role::text from public.group_members where group_id = tests.id(p_group) and user_id = tests.id(p_user)
$$;

-- delete_my_account ------------------------------------------------------------------------------------------
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok($$ select public.delete_my_account() $$, 'P0001', 'not_authenticated',
  'delete_my_account without a user raises not_authenticated');
select tests.as_anon();
select throws_ok($$ select public.delete_my_account() $$, '42501', 'permission denied for function delete_my_account',
  'anon cannot call delete_my_account');

select tests.as_user('x');
select lives_ok($$ select public.delete_my_account() $$, 'x deletes their account');

select tests.as_postgres();
select is((select count(*)::int from auth.users where id = tests.id('x')), 0, 'the auth user is deleted');
select is((select count(*)::int from auth.identities where user_id = tests.id('x')), 0, 'identities are cascaded');
select is((select count(*)::int from public.profiles where id = tests.id('x')), 0, 'the profile is deleted');
select is((select count(*)::int from public.group_members where user_id = tests.id('x')), 0, 'memberships are deleted');
select is((select count(*)::int from public.groups where id = tests.id('G1')), 0, 'a group where x was alone is deleted');
select is((select count(*)::int from public.tasks where group_id = tests.id('G1')), 0, 'with its tasks');
select is(tests.role_of('G2', 'y'), 'admin', 'G2: the oldest other member (y) becomes admin');
select is(tests.role_of('G2', 'z'), 'member', 'G2: z stays member');
select is(tests.role_of('G3', 'p') || '/' || tests.role_of('G3', 'q'),
  case when tests.id('p') < tests.id('q') then 'admin/member' else 'member/admin' end,
  'G3: ties on joined_at are broken by user_id');
select is(tests.role_of('G4', 'm'), 'member', 'G4: nobody is promoted when another admin exists');
select is(tests.role_of('G4', 'w'), 'admin', 'G4: the other admin stays admin');
select results_eq(
  $$ select user_id, role::text from public.group_members where group_id = tests.id('G5') $$,
  $$ values (tests.id('boss'), 'admin') $$,
  'G5: x simply left');
select is((select created_by from public.tasks where id = tests.id('Tâche de x')), null,
  'tasks created by x stay, with created_by = NULL');
select is((select assigned_by from public.task_assignees where task_id = tests.id('Tâche de x') and user_id = tests.id('y')),
  null, 'assignments made by x stay, with assigned_by = NULL');
select is((select count(*)::int from public.task_assignees where user_id = tests.id('x')), 0, 'x''s assignments are deleted');
select is((select count(*)::int from public.task_assignees where task_id = tests.id('Tâche de y')), 0,
  'including on tasks created by others');
select is((select created_by from public.groups where id = tests.id('G2')), null, 'groups.created_by becomes NULL');
select is((select created_by from public.group_invites where group_id = tests.id('G2')), null,
  'group_invites.created_by becomes NULL');
select is((select count(*)::int from public.push_subscriptions where user_id = tests.id('x')), 0,
  'the push subscription is deleted');
select is((select count(*)::int from private.join_attempts where user_id = tests.id('x')), 0,
  'join attempts are deleted');

-- Another device of the deleted account still holds a valid JWT (until it expires): every RPC treats it as
-- not_authenticated, before any other check.
insert into tests.results values ('G5 code', to_jsonb((select code from public.group_invites where group_id = tests.id('G5'))));
select tests.as_user('x');
select throws_ok($$ select public.create_group('Fantôme') $$, 'P0001', 'not_authenticated',
  'stale JWT of a deleted account: create_group');
select throws_ok(format($$ select public.join_group_by_code(%L) $$, (select value #>> '{}' from tests.results where name = 'G5 code')),
  'P0001', 'not_authenticated', 'stale JWT: join_group_by_code (valid code)');
select throws_ok(format($$ select public.regenerate_invite_code(%L) $$, tests.id('G2')), 'P0001', 'not_authenticated',
  'stale JWT: regenerate_invite_code');
select throws_ok(format($$ select public.rename_group(%L, 'Fantôme') $$, tests.id('G2')), 'P0001', 'not_authenticated',
  'stale JWT: rename_group');
select throws_ok(format($$ select public.delete_group(%L) $$, tests.id('G2')), 'P0001', 'not_authenticated',
  'stale JWT: delete_group');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'member') $$, tests.id('G2'), tests.id('y')),
  'P0001', 'not_authenticated', 'stale JWT: set_member_role');
select throws_ok(format($$ select public.remove_member(%L, %L) $$, tests.id('G2'), tests.id('z')),
  'P0001', 'not_authenticated', 'stale JWT: remove_member');
select throws_ok(format($$ select public.leave_group(%L) $$, tests.id('G2')), 'P0001', 'not_authenticated',
  'stale JWT: leave_group');
select throws_ok(format($$ select public.create_task(%L, 'Fantôme') $$, tests.id('G2')), 'P0001', 'not_authenticated',
  'stale JWT: create_task');
select throws_ok(format($$ select public.update_task(%L, 'Fantôme', null, 'low', null, null) $$, tests.id('Tâche de x')),
  'P0001', 'not_authenticated', 'stale JWT: update_task');
select throws_ok(format($$ select public.set_task_status(%L, 'done') $$, tests.id('Tâche de x')), 'P0001', 'not_authenticated',
  'stale JWT: set_task_status');
select throws_ok(format($$ select public.delete_task(%L) $$, tests.id('Tâche de x')), 'P0001', 'not_authenticated',
  'stale JWT: delete_task');
select throws_ok(format($$ select public.set_task_assignees(%L, '{}') $$, tests.id('Tâche de x')), 'P0001', 'not_authenticated',
  'stale JWT: set_task_assignees');
select throws_ok($$ select public.enable_push() $$, 'P0001', 'not_authenticated', 'stale JWT: enable_push');
select throws_ok($$ select public.disable_push() $$, 'P0001', 'not_authenticated', 'stale JWT: disable_push');
select throws_ok($$ select public.delete_my_account() $$, 'P0001', 'not_authenticated', 'stale JWT: delete_my_account');
select tests.as_postgres();

-- The last admin who is alone in every group can also delete their account.
select tests.create_user('solo');
select tests.create_group('Solo', 'solo');
select tests.as_user('solo');
select lives_ok($$ select public.delete_my_account() $$, 'a user with only solo groups deletes their account');
select tests.as_postgres();
select is((select count(*)::int from public.groups where id = tests.id('Solo')), 0, 'their group is gone');

-- enable_push / disable_push ---------------------------------------------------------------------------------
select tests.as_user('y');
insert into tests.results values ('topic1', to_jsonb(public.enable_push()));
select matches((select value #>> '{}' from tests.results where name = 'topic1'), '^equipe-[a-z0-9]{24}$',
  'enable_push returns equipe- + 24 chars [a-z0-9]');
select is(public.enable_push(), (select value #>> '{}' from tests.results where name = 'topic1'),
  'enable_push returns the existing topic');
select results_eq(
  $$ select topic from public.push_subscriptions where user_id = tests.id('y') $$,
  $$ select value #>> '{}' from tests.results where name = 'topic1' $$,
  'the user reads their own topic');
select tests.as_user('z');
select is_empty($$ select topic from public.push_subscriptions $$, 'another user cannot read it');
select lives_ok($$ select public.disable_push() $$, 'disable_push without a subscription is a no-op');
select throws_ok($$ insert into public.push_subscriptions (user_id, topic) values (auth.uid(), 'equipe-aaaaaaaaaaaaaaaaaaaaaaaa') $$,
  '42501', 'permission denied for table push_subscriptions', 'push_subscriptions cannot be written directly');
select tests.as_user('y');
select throws_ok($$ delete from public.push_subscriptions $$,
  '42501', 'permission denied for table push_subscriptions', 'push_subscriptions cannot be deleted directly');
select lives_ok($$ select public.disable_push() $$, 'disable_push');
select is_empty($$ select topic from public.push_subscriptions $$, 'the subscription is gone');
select isnt(public.enable_push(), (select value #>> '{}' from tests.results where name = 'topic1'),
  're-enabling creates a new random topic');

select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok($$ select public.enable_push() $$, 'P0001', 'not_authenticated', 'enable_push requires a user');
select throws_ok($$ select public.disable_push() $$, 'P0001', 'not_authenticated', 'disable_push requires a user');
select tests.as_anon();
select throws_ok($$ select public.enable_push() $$, '42501', 'permission denied for function enable_push',
  'anon cannot call enable_push');
select tests.as_postgres();
select is(
  (select count(distinct private.random_string('abcdefghijklmnopqrstuvwxyz0123456789', 24))::int from generate_series(1, 50)),
  50, 'topics are random');

select * from finish();
rollback;
