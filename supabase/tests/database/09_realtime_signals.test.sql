-- Realtime change signals: groups.last_activity_at and profiles.memberships_changed_at are bumped by
-- AFTER triggers, at most once per row per transaction; cascades (group deletion) keep working.
begin;
select plan(29);

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
select tests.create_group('G', 'alice', 'RTQWXY23');
select tests.add_member('G', 'bob');
select tests.create_group('Other', 'carol');

-- Every UPDATE event Realtime would broadcast for the signal tables.
create table tests.events (tbl text, id uuid);
grant insert on tests.events to authenticated;
create function tests.log_event() returns trigger language plpgsql security definer as $$
begin
  insert into tests.events values (tg_table_name, new.id);
  return null;
end $$;
create trigger log_groups_update after update on public.groups for each row execute function tests.log_event();
create trigger log_profiles_update after update on public.profiles for each row execute function tests.log_event();

-- Puts every signal in the past and forgets the logged events.
create function tests.rewind() returns void language plpgsql security definer as $$
begin
  update public.groups set last_activity_at = '2000-01-01' where id in (select id from tests.ids);
  update public.profiles set memberships_changed_at = '2000-01-01' where id in (select id from tests.ids);
  delete from tests.events where true;
end $$;
create function tests.events_for(p_name text) returns integer language sql security definer as $$
  select count(*)::int from tests.events where id = tests.id(p_name)
$$;
create function tests.activity(p_group text) returns timestamptz language sql security definer as $$
  select last_activity_at from public.groups where id = tests.id(p_group)
$$;
create function tests.changed(p_user text) returns timestamptz language sql security definer as $$
  select memberships_changed_at from public.profiles where id = tests.id(p_user)
$$;

-- Publication ------------------------------------------------------------------------------------------------
select set_eq(
  $$ select tablename::text from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' $$,
  array['groups', 'profiles', 'task_assignees'], 'publication: exactly groups, profiles, task_assignees');
select is(
  (select count(*)::int from pg_publication_tables where pubname = 'supabase_realtime'),
  3, 'publication: nothing else is published');

-- Tasks and assignees bump the group once per transaction ----------------------------------------------------------
select tests.rewind();
select tests.as_user('bob');
insert into tests.ids select 'T', id
from public.create_task(tests.id('G'), 'Signal', null, 'medium', null, array[tests.id('alice'), tests.id('bob')]);
select is(tests.activity('G'), now(), 'create_task (1 task + 2 assignees) bumps last_activity_at');
select is(tests.events_for('G'), 1, 'create_task produces exactly one groups UPDATE');
select lives_ok(format($$ select public.set_task_status(%L, 'done') $$, tests.id('T')), 'status change');
select lives_ok(format($$ select public.set_task_assignees(%L, array[%L]::uuid[]) $$, tests.id('T'), tests.id('bob')),
  'assignee change');
select is(tests.events_for('G'), 1, 'further changes in the same transaction do not produce more events');
select is(tests.events_for('Other'), 0, 'other groups are untouched');
select is(tests.events_for('bob') + tests.events_for('alice'), 0, 'task changes do not touch profiles');

select tests.as_postgres();
select tests.rewind();
select tests.as_user('bob');
select lives_ok(format($$ select public.set_task_status(%L, 'todo') $$, tests.id('T')), 'status change');
select is(tests.activity('G'), now(), 'a status change bumps the group');
select tests.as_postgres();
select tests.rewind();
select tests.as_user('bob');
select lives_ok(format($$ select public.set_task_assignees(%L, array[%L, %L]::uuid[]) $$,
  tests.id('T'), tests.id('bob'), tests.id('alice')), 'assignee change');
select is(tests.events_for('G'), 1, 'an assignee change bumps the group');
select tests.as_postgres();
select tests.rewind();
select tests.as_user('bob');
select lives_ok(format($$ select public.delete_task(%L) $$, tests.id('T')), 'task deletion');
select is(tests.events_for('G'), 1, 'a task deletion (with cascaded assignees) bumps the group once');

-- Rename -----------------------------------------------------------------------------------------------------------
select tests.as_postgres();
select tests.rewind();
select tests.as_user('alice');
select lives_ok(format($$ select public.rename_group(%L, 'Renommé') $$, tests.id('G')), 'rename');
select is(tests.events_for('G'), 1, 'rename_group produces one groups UPDATE');
select is(tests.activity('G'), now(), 'rename_group bumps last_activity_at');

-- Memberships bump the group and the member's profile ----------------------------------------------------------------
select tests.as_postgres();
select tests.rewind();
select tests.as_user('carol');
select lives_ok($$ select public.join_group_by_code('RTQWXY23') $$, 'carol joins');
select is(tests.changed('carol'), now(), 'joining bumps the joiner''s memberships_changed_at');
select is(tests.events_for('carol'), 1, 'one profiles UPDATE for the joiner');
select is(tests.events_for('G'), 1, 'joining bumps the group once');
select is(tests.events_for('alice') + tests.events_for('bob'), 0, 'other members'' profiles are untouched');

select tests.as_postgres();
select tests.rewind();
select tests.as_user('alice');
select lives_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, tests.id('G'), tests.id('bob')), 'promote bob');
select lives_ok(format($$ select public.remove_member(%L, %L) $$, tests.id('G'), tests.id('carol')), 'remove carol');
select is(tests.events_for('bob') || '/' || tests.events_for('carol') || '/' || tests.events_for('G'), '1/1/1',
  'role change and removal bump the targets'' profiles and the group once each');

-- Group deletion: every member is signalled and the cascade is not broken by the signal triggers --------------------
select tests.as_postgres();
select tests.create_task('T2', 'G', 'bob', array['alice', 'bob']);
select tests.rewind();
select tests.as_user('bob');
select lives_ok(format($$ select public.delete_group(%L) $$, tests.id('G')), 'delete_group with tasks, assignees, members');
select is(tests.changed('alice') || ' ' || tests.changed('bob'), now() || ' ' || now(),
  'every former member gets memberships_changed_at bumped');
select is(tests.events_for('G'), 0, 'no UPDATE is emitted for the deleted group');

select * from finish();
rollback;
