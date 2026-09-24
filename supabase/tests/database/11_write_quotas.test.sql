-- Write quotas: groups and tasks created per user per hour (create_group, create_task and direct INSERTs).
-- now() is constant inside this single transaction, so every write below falls in the same hour.
begin;
select plan(33);

-- Test helpers (created inside this transaction, rolled back at the end) ----------------------------
-- tests.as_user(name) = `set local role authenticated` + the JWT claims PostgREST would set;
-- tests.as_postgres() switches back; fixtures are created as postgres (auth.uid() is NULL).
create schema tests;
grant usage on schema tests to anon, authenticated;
create table tests.ids (name text primary key, id uuid not null);
grant select, insert on tests.ids to anon, authenticated;
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
create function tests.add_member(p_group text, p_user text, p_role public.member_role default 'member') returns void
language sql as $$
  insert into public.group_members (group_id, user_id, role) values (tests.id(p_group), tests.id(p_user), p_role);
$$;
create function tests.logged(p_user text, p_kind text) returns integer language sql as $$
  select count(*)::int from private.write_log wl where wl.user_id = tests.id(p_user) and wl.kind = p_kind
$$;
-- -------------------------------------------------------------------------------------------------------

select tests.create_user('ana');
select tests.create_user('ben');
select tests.create_user('zed');
-- Fixtures are written by a trusted context (no JWT): never limited, never logged.
select tests.create_group('G', 'ana');
select tests.create_group('H', 'ben', 'HJKMNPQR');
select tests.create_group('K', 'ben');
select tests.add_member('G', 'ben');
select tests.add_member('G', 'zed');

select has_trigger('public', 'groups', 'groups_quota_before_insert', 'groups has the quota trigger');
select has_trigger('public', 'tasks', 'tasks_quota_before_insert', 'tasks has the quota trigger');
select is((select value from private.settings where key = 'quota_groups_per_hour'), '20', 'default: 20 groups per user per hour');
select is((select value from private.settings where key = 'quota_tasks_per_hour'), '200', 'default: 200 tasks per user per hour');
select is(tests.logged('ana', 'group') + tests.logged('ben', 'group'), 0, 'trusted writes are not logged');

-- Groups ----------------------------------------------------------------------------------------------------------
select tests.as_user('ana');
select is((select count(*)::int from (select public.create_group('Groupe ' || i) from generate_series(1, 20) as i) s), 20,
  'a user creates 20 groups within an hour');
select throws_ok($$ select public.create_group('Groupe 21') $$, 'P0001', 'rate_limited', 'the 21st group is refused');
select throws_ok($$ select public.create_group('   ') $$, 'P0001', 'invalid_name', 'validation errors come first');
select is((select (public.join_group_by_code('HJKMNPQR')) ->> 'status'), 'joined', 'joining a group is not limited');
select tests.as_postgres();
select is(tests.logged('ana', 'group'), 20, 'refused attempts are not logged');

select tests.as_user('ben');
select lives_ok($$ select public.create_group('Groupe de ben') $$, 'another user is not affected');

select tests.as_postgres();
update private.write_log set created_at = now() - interval '1 hour' where user_id = tests.id('ana') and kind = 'group';
select tests.as_user('ana');
select throws_ok($$ select public.create_group('Groupe 21') $$, 'P0001', 'rate_limited', 'a write exactly one hour old still counts');
select tests.as_postgres();
update private.write_log set created_at = now() - interval '1 hour 1 second' where user_id = tests.id('ana') and kind = 'group';
select tests.as_user('ana');
select lives_ok($$ select public.create_group('Groupe 21') $$, 'older writes no longer count');
select tests.as_postgres();
select is(tests.logged('ana', 'group'), 1, 'and are pruned');

-- Tasks: create_task and direct INSERTs share the quota --------------------------------------------------------------
select tests.as_user('ana');
select is((select count(*)::int from (
  select public.create_task(tests.id('G'), 'Tâche ' || i) from generate_series(1, 199) as i) s), 199,
  '199 tasks through create_task');
select lives_ok($$ insert into public.tasks (group_id, title) values (tests.id('G'), 'Directe') $$,
  'the 200th task through a direct INSERT');
select throws_ok($$ insert into public.tasks (group_id, title) values (tests.id('G'), 'Directe 2') $$,
  'P0001', 'rate_limited', 'a direct INSERT beyond the quota is refused');
select throws_ok(format($$ select public.create_task(%L, 'Tâche 201') $$, tests.id('G')),
  'P0001', 'rate_limited', 'create_task beyond the quota is refused');
select throws_ok(format($$ select public.create_task(%L, '   ') $$, tests.id('G')),
  'P0001', 'invalid_title', 'validation errors come first');
select throws_ok(format($$ select public.create_task(%L, 'Ailleurs') $$, tests.id('K')),
  '42501', 'forbidden', 'permission errors come first');
select tests.as_postgres();
select is(tests.logged('ana', 'task'), 200, 'refused tasks are not logged');
select is((select count(*)::int from public.tasks where group_id = tests.id('G') and created_by = tests.id('ana')), 200,
  'ana created exactly 200 tasks');

select tests.as_user('ben');
select lives_ok(format($$ select public.create_task(%L, 'Tâche de ben') $$, tests.id('G')), 'ben is not affected');
select tests.as_user('ana');
select lives_ok($$ update public.tasks set status = 'done' where title = 'Directe' $$, 'updates are not limited');
select tests.as_postgres();
select lives_ok($$ insert into public.tasks (group_id, title) values (tests.id('G'), 'Contexte de confiance') $$,
  'a trusted context is never limited');
select is(tests.logged('ana', 'task'), 200, 'nor logged');

-- The limits are read from private.settings (an invalid or missing value falls back to the default) ---------------
update private.settings set value = '2' where key = 'quota_tasks_per_hour';
select tests.as_user('ben');
select lives_ok(format($$ select public.create_task(%L, 'Deuxième tâche de ben') $$, tests.id('G')), 'ben''s 2nd task');
select throws_ok(format($$ select public.create_task(%L, 'Troisième tâche de ben') $$, tests.id('G')),
  'P0001', 'rate_limited', 'a lower limit applies at once');
select tests.as_postgres();
update private.settings set value = 'illimité' where key = 'quota_tasks_per_hour';
select tests.as_user('ben');
select lives_ok(format($$ select public.create_task(%L, 'Troisième tâche de ben') $$, tests.id('G')),
  'an invalid value falls back to the default');
select tests.as_postgres();
-- Without the key: ana has 1 + 18 = 19 groups in the last hour, one below the default limit (20).
delete from private.settings where key = 'quota_groups_per_hour';
update private.write_log set created_at = now() - interval '30 minutes' where user_id = tests.id('ana') and kind = 'group';
insert into private.write_log (user_id, kind) select tests.id('ana'), 'group' from generate_series(1, 18);
select tests.as_user('ana');
select lives_ok($$ select public.create_group('Groupe 22') $$, 'a missing value falls back to the default: 20th group');
select throws_ok($$ select public.create_group('Groupe 23') $$, 'P0001', 'rate_limited', 'and the 21st is refused');

-- A deleted account's stale JWT gets the usual RLS error (not a foreign-key error from the log) ----------------------
select tests.as_postgres();
delete from auth.users where id = tests.id('zed');
select tests.as_user('zed');
select throws_ok($$ insert into public.tasks (group_id, title) values (tests.id('G'), 'Fantôme') $$,
  '42501', 'new row violates row-level security policy for table "tasks"', 'stale JWT: RLS error');

-- Account deletion removes the user's log (cascade from the profile).
select tests.as_postgres();
delete from auth.users where id = tests.id('ana');
select is(tests.logged('ana', 'group') + tests.logged('ana', 'task'), 0, 'deleting an account deletes its write log');

select * from finish();
rollback;
