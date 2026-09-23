-- Profiles: creation trigger (never fails), display name validation, visibility, column grants.
begin;
select plan(28);

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

create function tests.raw_user(p_name text, p_email text, p_meta jsonb) returns uuid
language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', p_email, '', '{}', p_meta, now(), now());
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
create function tests.display_name(p_name text) returns text language sql stable as $$
  select display_name from public.profiles where id = tests.id(p_name)
$$;

-- Creation trigger ----------------------------------------------------------------------------------------
select tests.raw_user('trimmed', 'trimmed@test.local', '{"display_name": "  Alice Martin \n"}');
select is(tests.display_name('trimmed'), 'Alice Martin', 'display_name is trimmed');

select tests.raw_user('long', 'long@test.local', jsonb_build_object('display_name', repeat('a', 49) || ' ' || repeat('b', 20)));
select is(tests.display_name('long'), repeat('a', 49), 'display_name is truncated to 50 chars (then trimmed)');

select tests.raw_user('accents', 'accents@test.local', jsonb_build_object('display_name', ' ' || repeat('é', 60)));
select is(tests.display_name('accents'), repeat('é', 50), 'truncation counts characters, not bytes');

select tests.raw_user('blank', 'jean.dupont@test.local', '{"display_name": "   "}');
select is(tests.display_name('blank'), 'jean.dupont', 'blank display_name falls back to the e-mail local part');

select tests.raw_user('nometa', 'sans.meta@test.local', null);
select is(tests.display_name('nometa'), 'sans.meta', 'NULL metadata falls back to the e-mail local part');

select tests.raw_user('longmail', repeat('x', 60) || '@test.local', '{}');
select is(tests.display_name('longmail'), repeat('x', 50), 'e-mail local part is truncated to 50 chars');

select tests.raw_user('phone', null, '{}');
select is(tests.display_name('phone'), 'Utilisateur', 'no name and no e-mail falls back to Utilisateur');

select tests.raw_user('weird', '@weird.test', '{"display_name": 42}');
select is(tests.display_name('weird'), '42', 'non-string display_name is used as text');

select tests.raw_user('array', '@array.test', '["not", "an", "object"]');
select is(tests.display_name('array'), 'Utilisateur', 'non-object metadata and empty local part fall back to Utilisateur');

select is(
  (select count(*)::int from public.profiles p join tests.ids i on i.id = p.id),
  9, 'every inserted auth user got a profile');

-- clean_text trims exactly Swift's `CharacterSet.whitespacesAndNewlines` (docs/CONTRACTS.md §1): U+0009–U+000D,
-- U+0020, U+0085, U+00A0, U+1680, U+2000–U+200B, U+2028, U+2029, U+202F, U+205F, U+3000 — not U+001C–U+001F.
-- Same probe list as the Swift side: U+0001–U+3000 plus U+180E, U+200B, U+FEFF.
select is(
  (select string_agg(to_hex(s.cp), ',' order by s.cp)
   from (select generate_series(1, 12288) union values (6158), (8203), (65279)) as s (cp)
   where private.clean_text('a' || chr(s.cp)) = 'a' and private.clean_text(chr(s.cp) || 'a') = 'a'),
  '9,a,b,c,d,20,85,a0,1680,2000,2001,2002,2003,2004,2005,2006,2007,2008,2009,200a,200b,2028,2029,202f,205f,3000',
  'clean_text trims exactly the whitespacesAndNewlines code points, at both ends');

-- Display name updates -----------------------------------------------------------------------------------
select tests.create_user('alice', 'Alice');
select tests.create_user('bob', 'Bob');
select tests.create_user('carol', 'Carol');
update public.profiles set updated_at = '2000-01-01' where id = tests.id('alice');

select tests.as_user('alice');
select is(
  tests.affected($$ update public.profiles set display_name = '  Alice Durand  ' where id = tests.id('alice') $$),
  1, 'a user can update their own display name');
select is(
  (select display_name from public.profiles where id = tests.id('alice')),
  'Alice Durand', 'the new display name is trimmed');
select is(
  (select updated_at from public.profiles where id = tests.id('alice')),
  now(), 'updated_at is maintained');
select throws_ok(
  $$ update public.profiles set display_name = '   ' where id = tests.id('alice') $$,
  'P0001', 'invalid_display_name', 'blank display name is rejected');
select throws_ok(
  format($$ update public.profiles set display_name = %L where id = tests.id('alice') $$, repeat('a', 51)),
  'P0001', 'invalid_display_name', '51-char display name is rejected');
select lives_ok(
  format($$ update public.profiles set display_name = %L where id = tests.id('alice') $$, repeat('a', 50)),
  '50-char display name is accepted');
select is(
  tests.affected($$ update public.profiles set display_name = 'Pirate' where id = tests.id('bob') $$),
  0, 'updating another user''s profile affects 0 rows');
select throws_ok(
  $$ update public.profiles set memberships_changed_at = now() where id = tests.id('alice') $$,
  '42501', 'permission denied for table profiles', 'memberships_changed_at is not updatable by users');
select throws_ok(
  $$ insert into public.profiles (id, display_name) values (gen_random_uuid(), 'X') $$,
  '42501', 'permission denied for table profiles', 'users cannot insert profiles');
select throws_ok(
  $$ delete from public.profiles where id = tests.id('alice') $$,
  '42501', 'permission denied for table profiles', 'users cannot delete profiles');

-- Visibility: self or co-member ------------------------------------------------------------------------------
select set_eq(
  $$ select id from public.profiles $$,
  $$ select tests.id('alice') $$,
  'without groups a user only sees their own profile');

select tests.as_postgres();
select tests.create_group('Groupe', 'alice');
select tests.add_member('Groupe', 'bob');

select tests.as_user('alice');
select set_eq(
  $$ select id from public.profiles $$,
  $$ values (tests.id('alice')), (tests.id('bob')) $$,
  'a user sees the profiles of co-members, not strangers');
select tests.as_user('carol');
select set_eq(
  $$ select id from public.profiles $$,
  $$ select tests.id('carol') $$,
  'a stranger sees only their own profile');

-- The profile follows the auth user.
select tests.as_postgres();
delete from auth.users where id = tests.id('carol');
select is(
  (select count(*)::int from public.profiles where id = tests.id('carol')),
  0, 'deleting the auth user deletes the profile');

-- Signals: joining bumps memberships_changed_at once; a display name change does not.
update public.profiles set memberships_changed_at = '2000-01-01' where id = tests.id('bob');
select tests.add_member('Groupe', 'long');
select is(
  (select memberships_changed_at from public.profiles where id = tests.id('bob')),
  '2000-01-01'::timestamptz, 'another user joining does not bump my memberships_changed_at');
select tests.as_user('bob');
select lives_ok($$ update public.profiles set display_name = 'Bobby' where id = tests.id('bob') $$, 'bob renames himself');
select tests.as_postgres();
select is(
  (select memberships_changed_at from public.profiles where id = tests.id('bob')),
  '2000-01-01'::timestamptz, 'a display name change does not touch memberships_changed_at');

select * from finish();
rollback;
