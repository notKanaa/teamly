-- Schema, privileges, private schema isolation, publication, ping.
begin;
select plan(41);

-- Test helpers (created inside this transaction, rolled back at the end) ----------------------------
create schema tests;
grant usage on schema tests to anon, authenticated;
create table tests.ids (name text primary key, id uuid not null);
grant select on tests.ids to anon, authenticated;
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
-- -------------------------------------------------------------------------------------------------------

-- Helper self-check: role switching works in both directions.
select tests.create_user('alice');
select tests.as_user('alice');
select is(current_user::text, 'authenticated', 'helper: as_user switches to authenticated');
select is(auth.uid(), tests.id('alice'), 'helper: as_user sets the JWT sub');
select tests.as_postgres();
select is(current_user::text, 'postgres', 'helper: as_postgres switches back');
select is(auth.uid(), null, 'helper: as_postgres clears the JWT claims');

-- Schema ------------------------------------------------------------------------------------------------
select tables_are('public',
  array['profiles', 'groups', 'group_invites', 'group_members', 'tasks', 'task_assignees', 'push_subscriptions',
        'task_checklist_items', 'group_activity'],
  'public tables are exactly the contract tables (v1 + v2)');
select tables_are('private', array['join_attempts', 'settings', 'push_log', 'write_log'], 'private tables');
select enum_has_labels('public', 'member_role', array['admin', 'member'], 'member_role labels');
select enum_has_labels('public', 'task_status', array['todo', 'in_progress', 'done'], 'task_status labels');
select enum_has_labels('public', 'task_priority', array['low', 'medium', 'high'], 'task_priority labels');
select col_is_pk('public', 'group_members', array['group_id', 'user_id'], 'group_members pk');
select col_is_pk('public', 'task_assignees', array['task_id', 'user_id'], 'task_assignees pk');
select fk_ok('public', 'task_assignees', array['task_id', 'group_id'], 'public', 'tasks', array['id', 'group_id'],
  'task_assignees → tasks(id, group_id)');
select fk_ok('public', 'task_assignees', array['group_id', 'user_id'], 'public', 'group_members', array['group_id', 'user_id'],
  'task_assignees → group_members(group_id, user_id)');
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'private') and c.relkind = 'r' and not c.relrowsecurity),
  0, 'RLS is enabled on every table');

-- Table privileges --------------------------------------------------------------------------------------
select is_empty($$
  select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'private') and c.relkind = 'r'
    and (has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         or has_any_column_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES'))
$$, 'anon has no privilege on any table');
select table_privs_are('public', 'profiles', 'authenticated', array['SELECT'], 'profiles: authenticated table privileges');
select table_privs_are('public', 'groups', 'authenticated', array['SELECT'], 'groups: authenticated table privileges');
select table_privs_are('public', 'group_invites', 'authenticated', array['SELECT'], 'group_invites: authenticated table privileges');
select table_privs_are('public', 'group_members', 'authenticated', array['SELECT'], 'group_members: authenticated table privileges');
select table_privs_are('public', 'tasks', 'authenticated', array['SELECT', 'DELETE'], 'tasks: authenticated table privileges');
select table_privs_are('public', 'task_assignees', 'authenticated', array['SELECT'], 'task_assignees: authenticated table privileges');
select table_privs_are('public', 'push_subscriptions', 'authenticated', array['SELECT'], 'push_subscriptions: authenticated table privileges');
select table_privs_are('public', 'task_checklist_items', 'authenticated', array['SELECT'], 'task_checklist_items: authenticated table privileges');
select table_privs_are('public', 'group_activity', 'authenticated', array['SELECT'], 'group_activity: authenticated table privileges');
select set_eq($$
  select c.relname || '.' || a.attname || ':' || p.priv
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  cross join (values ('INSERT'), ('UPDATE')) as p (priv)
  where n.nspname = 'public' and c.relkind = 'r' and has_column_privilege('authenticated', c.oid, a.attnum, p.priv)
$$, array[
  'profiles.display_name:UPDATE', 'profiles.avatar_color:UPDATE', 'profiles.avatar_emoji:UPDATE',
  'tasks.group_id:INSERT', 'tasks.title:INSERT', 'tasks.details:INSERT', 'tasks.priority:INSERT', 'tasks.due_at:INSERT',
  'tasks.title:UPDATE', 'tasks.details:UPDATE', 'tasks.status:UPDATE', 'tasks.priority:UPDATE', 'tasks.due_at:UPDATE'
], 'authenticated column-level INSERT/UPDATE grants are exactly the contract ones');
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'private' and c.relkind = 'r' and has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE')),
  0, 'authenticated has no privilege on private tables');

-- Function privileges -----------------------------------------------------------------------------------
select set_eq($$
  select p.proname::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'private') and has_function_privilege('anon', p.oid, 'EXECUTE')
$$, array['ping'], 'anon can execute ping only');
select set_eq($$
  select p.proname::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'EXECUTE')
$$, array[
  'create_group', 'join_group_by_code', 'regenerate_invite_code', 'rename_group', 'delete_group', 'set_member_role',
  'remove_member', 'leave_group', 'create_task', 'update_task', 'set_task_status', 'delete_task', 'set_task_assignees',
  'delete_my_account', 'enable_push', 'disable_push', 'ping',
  'set_group_appearance', 'complete_onboarding', 'add_checklist_item', 'rename_checklist_item', 'set_checklist_item_done',
  'delete_checklist_item'
], 'authenticated can execute exactly the contract RPCs (v1 + v2)');
select set_eq($$
  select p.proname::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'private' and has_function_privilege('authenticated', p.oid, 'EXECUTE')
$$, array['my_group_ids', 'my_admin_group_ids', 'my_assigned_task_ids', 'co_member_ids', 'is_group_member', 'is_group_admin'],
  'authenticated can only execute the RLS helpers in private (needed by policies)');
select is_empty($$
  select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
    aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where n.nspname in ('public', 'private') and a.grantee = 0
$$, 'no function is executable by PUBLIC');
select is_empty($$
  select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'private') and not coalesce(p.proconfig, '{}') @> array['search_path=""']
$$, 'every function pins search_path to an empty string');
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef),
  18, 'the 18 definer RPCs are security definer (create_task/update_task/set_task_status/delete_task/ping are invoker)');

-- Private schema is unusable by API roles ----------------------------------------------------------------
select ok(not has_schema_privilege('anon', 'private', 'USAGE'), 'anon has no USAGE on schema private');
select ok(not has_schema_privilege('authenticated', 'private', 'USAGE'), 'authenticated has no USAGE on schema private');
select tests.as_user('alice');
select throws_ok($$ select private.my_group_ids() $$, '42501', 'permission denied for schema private',
  'authenticated cannot call a private helper by name');
select throws_ok($$ select count(*) from private.join_attempts $$, '42501', 'permission denied for schema private',
  'authenticated cannot read private.join_attempts');

-- Anonymous access ---------------------------------------------------------------------------------------
select tests.as_anon();
select is(public.ping(), 'pong', 'anon can call ping');
select throws_ok($$ select count(*) from public.tasks $$, '42501', 'permission denied for table tasks',
  'anon cannot read tasks');
select throws_ok($$ select count(*) from public.profiles $$, '42501', 'permission denied for table profiles',
  'anon cannot read profiles');
select throws_ok($$ select public.create_group('Anonyme') $$, '42501', 'permission denied for function create_group',
  'anon cannot call create_group');
select tests.as_postgres();

-- Realtime publication -----------------------------------------------------------------------------------
select set_eq($$
  select schemaname || '.' || tablename from pg_publication_tables where pubname = 'supabase_realtime'
$$, array['public.groups', 'public.profiles', 'public.task_assignees'],
  'supabase_realtime publishes exactly groups, profiles and task_assignees');

select * from finish();
rollback;
