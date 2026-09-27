-- v3 cross-cutting checks (docs/CONTRACTS-V3.md §7, §11, conventions): the activity kinds and the member_away range, the RLS
-- policies of the new tables, the Realtime publication, and `not_authenticated` for every new RPC (no JWT, or the JWT of a
-- deleted account).
begin;
select plan(23);

-- Test helpers (created inside this transaction, rolled back at the end) ----------------------------
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
create function tests.create_group(p_name text, p_admin text) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into public.groups (name, created_by) values (p_name, tests.id(p_admin)) returning id into v_id;
  insert into public.group_members (group_id, user_id, role) values (v_id, tests.id(p_admin), 'admin');
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
-- The error of a statement as "SQLSTATE message", or 'ok'.
create function tests.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ' ' || sqlerrm;
end $$;
-- -------------------------------------------------------------------------------------------------------

select tests.create_user('alice');
select tests.create_group('G', 'alice');

-- Activity kinds and columns (§7) ----------------------------------------------------------------------------------------
select lives_ok(format($$
  insert into public.group_activity (group_id, kind) select %L, k from unnest(array[
    'task_created', 'task_completed', 'turn_started', 'checklist_item_done', 'member_joined', 'member_left',
    'task_nudged', 'member_away', 'turn_swapped', 'comment_added', 'photo_added']) as k $$, tests.id('G')),
  'the kind check accepts the v2 kinds and the five v3 kinds');
select throws_ok(format($$ insert into public.group_activity (group_id, kind) values (%L, 'task_liked') $$, tests.id('G')),
  '23514', null, 'an unknown kind is refused');
select throws_ok(format($$ insert into public.group_activity (group_id, kind, starts_on) values (%L, 'member_away', '2041-01-01') $$, tests.id('G')),
  '23514', null, 'starts_on and ends_on: both or neither');
select throws_ok(format($$ insert into public.group_activity (group_id, kind, starts_on, ends_on) values (%L, 'task_created', '2041-01-01', '2041-01-02') $$,
    tests.id('G')),
  '23514', null, 'a date range only on member_away');
select throws_ok(format($$ insert into public.group_activity (group_id, kind, starts_on, ends_on) values (%L, 'member_away', '2041-01-02', '2041-01-01') $$,
    tests.id('G')),
  '23514', null, 'ends_on >= starts_on');
select private.write_activity(tests.id('G'), 'member_away', tests.id('alice'), tests.id('alice'), null, null, null, '2041-01-01', '2041-01-02');
select private.log_activity(tests.id('G'), 'member_joined', tests.id('alice'), tests.id('alice'), null, null, null);
select results_eq(
  $$ select kind, starts_on, ends_on from public.group_activity where group_id = tests.id('G') and actor_id is not null order by id $$,
  $$ values ('member_away', '2041-01-01'::date, '2041-01-02'::date), ('member_joined', null, null) $$,
  'write_activity stores the range; log_activity (v2 signature) stores none');
select tests.as_user('alice');
select lives_ok($$ select id, kind, actor_id, subject_id, task_id, task_title, item_title, created_at, starts_on, ends_on
                   from public.group_activity where group_id = tests.id('G') order by id desc limit 50 $$,
  'the feed read with the v3 columns');
select tests.as_postgres();

-- RLS of the new tables ---------------------------------------------------------------------------------------------------------
select results_eq(
  $$ select c.relname::text collate "default", c.relrowsecurity from pg_class c
     where c.oid in ('public.task_nudges'::regclass, 'public.turn_swaps'::regclass, 'public.activity_reactions'::regclass,
                     'public.task_comments'::regclass, 'public.task_photos'::regclass)
     order by 1 $$,
  $$ values ('activity_reactions', true), ('task_comments', true), ('task_nudges', true), ('task_photos', true), ('turn_swaps', true) $$,
  'RLS is enabled on the five new tables');
select results_eq(
  $$ select tablename::text collate "default", policyname::text collate "default", cmd::text collate "default", roles::text collate "default" from pg_policies
     where schemaname = 'public' and tablename in ('task_nudges', 'turn_swaps', 'activity_reactions', 'task_comments', 'task_photos')
     order by 1 $$,
  $$ values ('activity_reactions', 'activity_reactions_select', 'SELECT', '{authenticated}'),
            ('task_comments', 'task_comments_select', 'SELECT', '{authenticated}'),
            ('task_nudges', 'task_nudges_select', 'SELECT', '{authenticated}'),
            ('task_photos', 'task_photos_select', 'SELECT', '{authenticated}'),
            ('turn_swaps', 'turn_swaps_select', 'SELECT', '{authenticated}') $$,
  'one SELECT policy each, for authenticated only: no write policy');
select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'public' and tablename in ('task_nudges', 'turn_swaps', 'activity_reactions', 'task_comments', 'task_photos')
       and qual !~ 'my_group_ids' $$,
  'every policy goes through the definer helper private.my_group_ids() (no recursion)');
select fk_ok('public', 'task_comments', array['task_id', 'group_id'], 'public', 'tasks', array['id', 'group_id'],
  'task_comments → tasks(id, group_id): task reads embed comments:task_comments(count)');
select fk_ok('public', 'task_photos', array['task_id', 'group_id'], 'public', 'tasks', array['id', 'group_id'],
  'task_photos → tasks(id, group_id): task reads embed photos:task_photos(...)');
select fk_ok('public', 'task_nudges', array['task_id', 'group_id'], 'public', 'tasks', array['id', 'group_id'], 'task_nudges → tasks(id, group_id)');
select fk_ok('public', 'turn_swaps', array['task_id', 'group_id'], 'public', 'tasks', array['id', 'group_id'], 'turn_swaps → tasks(id, group_id)');

-- Realtime publication (§11) -------------------------------------------------------------------------------------------------------
select set_eq(
  $$ select tablename::text from pg_publication_tables where pubname = 'supabase_realtime' $$,
  array['groups', 'profiles', 'task_assignees', 'task_nudges', 'turn_swaps', 'activity_reactions', 'task_comments'],
  'the v1 tables plus task_nudges, turn_swaps, activity_reactions, task_comments (task_photos is not published)');
select results_eq(
  $$ select pubinsert, pubupdate, pubdelete, pubtruncate from pg_publication where pubname = 'supabase_realtime' $$,
  $$ values (true, true, false, false) $$,
  'INSERT and UPDATE only: DELETE is never published');

-- not_authenticated for every new RPC (no JWT, then a deleted account's JWT) ---------------------------------------------------------
select results_eq(
  $$ select tests.error_of(s) from unnest(array[
       'select public.nudge_task(gen_random_uuid())',
       'select public.set_away(''2041-01-01'', ''2041-01-02'')',
       'select public.clear_away()',
       'select public.request_turn_swap(gen_random_uuid(), gen_random_uuid())',
       'select public.respond_turn_swap(gen_random_uuid(), true)',
       'select public.cancel_turn_swap(gen_random_uuid())',
       'select public.toggle_reaction(1, ''x'')',
       'select public.add_task_comment(gen_random_uuid(), ''x'')',
       'select public.delete_task_comment(gen_random_uuid())',
       'select public.attach_task_photo(gen_random_uuid(), ''x'')',
       'select public.delete_task_photo(gen_random_uuid())']) with ordinality as x (s, o) order by o $$,
  $$ select 'P0001 not_authenticated' from generate_series(1, 11) $$,
  'every new RPC: not_authenticated without a JWT');
insert into tests.ids values ('ghost', gen_random_uuid());
select tests.as_user('ghost');
select results_eq(
  $$ select tests.error_of(s) from unnest(array[
       'select public.nudge_task(gen_random_uuid())',
       'select public.set_away(''2041-01-01'', ''2041-01-02'')',
       'select public.clear_away()',
       'select public.request_turn_swap(gen_random_uuid(), gen_random_uuid())',
       'select public.respond_turn_swap(gen_random_uuid(), true)',
       'select public.cancel_turn_swap(gen_random_uuid())',
       'select public.toggle_reaction(1, ''x'')',
       'select public.add_task_comment(gen_random_uuid(), ''x'')',
       'select public.delete_task_comment(gen_random_uuid())',
       'select public.attach_task_photo(gen_random_uuid(), ''x'')',
       'select public.delete_task_photo(gen_random_uuid())']) with ordinality as x (s, o) order by o $$,
  $$ select 'P0001 not_authenticated' from generate_series(1, 11) $$,
  'every new RPC: not_authenticated with the JWT of an account that no longer exists');
select tests.as_postgres();

-- Function properties ---------------------------------------------------------------------------------------------------------------
select is_empty(
  $$ select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('nudge_task', 'set_away', 'clear_away', 'request_turn_swap', 'respond_turn_swap', 'cancel_turn_swap',
                         'toggle_reaction', 'add_task_comment', 'delete_task_comment', 'attach_task_photo', 'delete_task_photo')
       and not (p.prosecdef and p.proconfig @> array['search_path=""']) $$,
  'the new RPCs are security definer with an empty search_path');
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('nudge_task', 'set_away', 'clear_away', 'request_turn_swap', 'respond_turn_swap', 'cancel_turn_swap',
                       'toggle_reaction', 'add_task_comment', 'delete_task_comment', 'attach_task_photo', 'delete_task_photo')),
  11, 'no overload: one function per new RPC name');
select results_eq(
  $$ select pg_get_function_identity_arguments(p.oid) collate "default" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('set_away', 'add_task_comment') order by p.proname $$,
  $$ values ('p_task_id uuid, p_body text, p_mentions uuid[]'), ('p_from date, p_until date, p_announce boolean') $$,
  'the signatures of the RPCs with defaults');
select is_empty(
  $$ select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'private'
       and p.proname in ('is_away', 'pick_turn', 'first_name', 'write_activity', 'queue_push', 'push_message', 'tasks_before_insert_v3',
                         'tasks_after_update_v3', 'cancel_turn_swaps_of_departed', 'profiles_after_update_away_signal',
                         'task_nudges_after_insert_push', 'task_comments_after_insert_push')
       and (has_function_privilege('authenticated', p.oid, 'EXECUTE') or has_function_privilege('anon', p.oid, 'EXECUTE')) $$,
  'API roles cannot execute the v3 private helpers');
select results_eq(
  $$ select count(*)::int from pg_trigger t where not t.tgisinternal and t.tgrelid in (
       'public.task_nudges'::regclass, 'public.turn_swaps'::regclass, 'public.activity_reactions'::regclass,
       'public.task_comments'::regclass, 'public.task_photos'::regclass)
     and t.tgname like '%_after_change_signal' $$,
  $$ values (5) $$,
  'every new table bumps its group on write');

select * from finish();
rollback;
