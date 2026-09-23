-- Invite codes (admin-only read, regeneration) and join_group_by_code (normalization, statuses,
-- attempt log, rate limit).
begin;
select plan(38);

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
select tests.create_user('mallory');
select tests.create_group('Lilas', 'alice', 'QWERTY23');
select tests.add_member('Lilas', 'bob');

create function tests.attempts(p_user text, p_succeeded boolean) returns integer language sql as $$
  select count(*)::int from private.join_attempts where user_id = tests.id(p_user) and succeeded = p_succeeded
$$;

-- Invite code visibility -----------------------------------------------------------------------------------
select tests.as_user('alice');
select results_eq(
  $$ select code from public.group_invites where group_id = tests.id('Lilas') $$,
  $$ values ('QWERTY23') $$, 'the admin reads the invite code');
select tests.as_user('bob');
select is_empty($$ select code from public.group_invites where group_id = tests.id('Lilas') $$,
  'a member gets 0 rows for the invite code');
select tests.as_user('eve');
select is_empty($$ select code from public.group_invites $$, 'a non-member sees no invite code');
select throws_ok($$ update public.group_invites set code = 'ABCDEFGH' $$, '42501',
  'permission denied for table group_invites', 'invite codes cannot be written directly');

-- join_group_by_code -----------------------------------------------------------------------------------------
select tests.as_user('eve');
select is(
  public.join_group_by_code('  qwer-ty23 '),
  jsonb_build_object('status', 'joined', 'group_id', tests.id('Lilas'), 'group_name', 'Lilas'),
  'the code is normalized (lowercase, dash, spaces) and the user joins');
select results_eq(
  $$ select role::text from public.group_members where group_id = tests.id('Lilas') and user_id = tests.id('eve') $$,
  $$ values ('member') $$, 'the new member has role member');
select is(
  (select count(*)::int from public.groups where id = tests.id('Lilas')),
  1, 'the new member now sees the group');
select is(
  public.join_group_by_code('QWERTY23'),
  jsonb_build_object('status', 'already_member', 'group_id', tests.id('Lilas'), 'group_name', 'Lilas'),
  'joining again returns already_member');
select is(
  public.join_group_by_code('ZZZZZZZZ'),
  jsonb_build_object('status', 'invalid_code', 'group_id', null, 'group_name', null),
  'an unknown code returns invalid_code');
select is(public.join_group_by_code('QWE')->>'status', 'invalid_code', 'a malformed code returns invalid_code');
select is(public.join_group_by_code('QWERTY2O')->>'status', 'invalid_code',
  'a code with a character outside the alphabet returns invalid_code');
select is(public.join_group_by_code(null)->>'status', 'invalid_code', 'a NULL code returns invalid_code');

select tests.as_postgres();
select is(tests.attempts('eve', true), 2, 'successful attempts are logged');
select is(tests.attempts('eve', false), 4, 'failed attempts are logged (the invalid_code result is not rolled back)');

-- not_authenticated
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok($$ select public.join_group_by_code('QWERTY23') $$, 'P0001', 'not_authenticated',
  'join_group_by_code without a user raises not_authenticated');
select tests.as_postgres();

-- Rate limit: more than 10 failed attempts within the last hour are refused. ----------------------------------
-- Old attempts (> 1 hour) do not count and are purged.
insert into private.join_attempts (user_id, attempted_at, succeeded)
select tests.id('mallory'), now() - interval '2 hours', false from generate_series(1, 20);

select tests.as_user('mallory');
select is(
  (select count(*)::int from generate_series(1, 9) as i
   where public.join_group_by_code('AAAAAAA' || i::text)->>'status' = 'invalid_code'),
  9, 'failed attempts 1–9 return invalid_code');
select is(
  public.join_group_by_code('DDDDDDDD')->>'status', 'invalid_code', 'failed attempt 10 still returns invalid_code');
select throws_ok($$ select public.join_group_by_code('ZZZZZZZZ') $$, 'P0001', 'rate_limited',
  'the 11th attempt after 10 failures within an hour is rate limited');
select throws_ok($$ select public.join_group_by_code('QWERTY23') $$, 'P0001', 'rate_limited',
  'a rate-limited user cannot join even with a valid code');
select is(
  (select count(*)::int from public.group_members where group_id = tests.id('Lilas') and user_id = tests.id('mallory')),
  0, 'the rate-limited user did not join');

select tests.as_postgres();
select is(tests.attempts('mallory', false), 10, 'attempts older than one hour were purged; 10 failures remain');
update private.join_attempts set attempted_at = now() - interval '61 minutes' where user_id = tests.id('mallory');
select tests.as_user('mallory');
select is(public.join_group_by_code('QWERTY23')->>'status', 'joined', 'after an hour the user can try again');

-- Successful attempts do not count as failures.
select tests.as_postgres();
select tests.create_user('trudy');
insert into private.join_attempts (user_id, succeeded)
select tests.id('trudy'), true from generate_series(1, 30);
insert into private.join_attempts (user_id, succeeded)
select tests.id('trudy'), false from generate_series(1, 9);
select tests.as_user('trudy');
select is(public.join_group_by_code('QWERTY23')->>'status', 'joined', 'successes do not count towards the limit');
select is(public.join_group_by_code('BBBBBBBB')->>'status', 'invalid_code', '10th failure is still answered');
select throws_ok($$ select public.join_group_by_code('QWERTY23') $$, 'P0001', 'rate_limited',
  'then the user is rate limited');
select tests.as_user('bob');
select is(public.join_group_by_code('CCCCCCCC')->>'status', 'invalid_code', 'the limit is per user');

-- regenerate_invite_code ---------------------------------------------------------------------------------------
select tests.as_user('bob');
select throws_ok(format($$ select public.regenerate_invite_code(%L) $$, tests.id('Lilas')), '42501', 'forbidden',
  'a member cannot regenerate the code');
select tests.as_user('mallory');
select throws_ok(format($$ select public.regenerate_invite_code(%L) $$, gen_random_uuid()), '42501', 'forbidden',
  'an unknown group raises forbidden');
select tests.as_postgres();
select tests.create_user('outsider');
select tests.as_user('outsider');
select throws_ok(format($$ select public.regenerate_invite_code(%L) $$, tests.id('Lilas')), '42501', 'forbidden',
  'a non-member cannot regenerate the code');

select tests.as_user('alice');
insert into tests.results values ('new_code', to_jsonb(public.regenerate_invite_code(tests.id('Lilas'))));
select matches((select value #>> '{}' from tests.results where name = 'new_code'), '^[A-HJ-NP-Z2-9]{8}$',
  'the admin gets a new well-formed code');
select isnt((select value #>> '{}' from tests.results where name = 'new_code'), 'QWERTY23', 'the new code differs');
select results_eq(
  $$ select code from public.group_invites where group_id = tests.id('Lilas') $$,
  $$ select value #>> '{}' from tests.results where name = 'new_code' $$,
  'the stored code is the new one');
select tests.as_user('outsider');
select is(public.join_group_by_code('QWERTY23')->>'status', 'invalid_code', 'the old code no longer works');
select is(
  public.join_group_by_code(lower((select value #>> '{}' from tests.results where name = 'new_code'))),
  jsonb_build_object('status', 'joined', 'group_id', tests.id('Lilas'), 'group_name', 'Lilas'),
  'the new code works');

-- Invite code format constraint.
select tests.as_postgres();
select throws_ok(format($$ update public.group_invites set code = 'ABCDEFG0' where group_id = %L $$, tests.id('Lilas')),
  '23514', null, 'the code must use the unambiguous alphabet (check constraint)');
select throws_ok(format($$ update public.group_invites set code = 'ABCDEFG' where group_id = %L $$, tests.id('Lilas')),
  '23514', null, 'the code must have 8 characters (check constraint)');
select is(
  (select count(distinct private.generate_invite_code())::int from generate_series(1, 50)),
  50, 'generated codes are random');
select is(
  (select count(*)::int from generate_series(1, 200) where private.generate_invite_code() !~ '^[A-HJ-NP-Z2-9]{8}$'),
  0, 'generated codes always match the format');

select * from finish();
rollback;
