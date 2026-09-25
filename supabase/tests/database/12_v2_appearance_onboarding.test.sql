-- v2 schema (docs/CONTRACTS-V2.md §2), group and avatar appearance (§1, §3, §5), onboarding (§2, §5, §9).
begin;
select plan(80);

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
-- -------------------------------------------------------------------------------------------------------

-- Every UPDATE of groups / profiles (what Realtime would broadcast).
create table tests.events (tbl text, id uuid);
grant insert on tests.events to authenticated;
create function tests.log_event() returns trigger language plpgsql security definer as $$
begin
  insert into tests.events values (tg_table_name, new.id);
  return null;
end $$;
create trigger log_groups_update after update on public.groups for each row execute function tests.log_event();
create trigger log_profiles_update after update on public.profiles for each row execute function tests.log_event();
create function tests.events_for(p_name text) returns integer language sql security definer as $$
  select count(*)::int from tests.events where id = tests.id(p_name)
$$;
-- The normalized emoji, or the error message.
create function tests.emoji(p_value text) returns text language plpgsql as $$
begin
  return coalesce(private.normalize_emoji(p_value), '<null>');
exception when others then
  return sqlerrm;
end $$;

select tests.create_user('alice');
select tests.create_user('bob');
select tests.create_user('eve');

-- Schema (§2) ------------------------------------------------------------------------------------------------
select columns_are('public', 'groups',
  array['id', 'name', 'created_by', 'created_at', 'last_activity_at', 'color', 'emoji'], 'groups columns (v1 + v2)');
select columns_are('public', 'profiles',
  array['id', 'display_name', 'memberships_changed_at', 'created_at', 'updated_at', 'avatar_color', 'avatar_emoji', 'onboarded_at'],
  'profiles columns (v1 + v2)');
select columns_are('public', 'tasks',
  array['id', 'group_id', 'title', 'details', 'status', 'priority', 'due_at', 'created_by', 'created_at', 'updated_at',
        'completed_at', 'repeat_freq', 'repeat_interval', 'repeat_weekdays', 'repeat_month_day', 'repeat_tz', 'series_id',
        'next_occurrence_id', 'rotation', 'turn_user_id', 'completed_by'],
  'tasks columns (v1 + v2)');
select columns_are('public', 'task_checklist_items',
  array['id', 'task_id', 'group_id', 'title', 'position', 'done', 'done_at', 'done_by', 'created_at'],
  'task_checklist_items columns');
select columns_are('public', 'group_activity',
  array['id', 'group_id', 'kind', 'actor_id', 'subject_id', 'task_id', 'task_title', 'item_title', 'created_at'],
  'group_activity columns');
select results_eq(
  $$ select a.attname::text collate "default", format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid) collate "default"
     from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
     where a.attrelid = 'public.tasks'::regclass
       and a.attname in ('repeat_freq', 'repeat_interval', 'repeat_weekdays', 'repeat_month_day', 'repeat_tz', 'series_id',
                         'next_occurrence_id', 'rotation', 'turn_user_id', 'completed_by')
     order by a.attnum $$,
  $$ values ('repeat_freq', 'text', false, null::text), ('repeat_interval', 'smallint', true, '1'),
            ('repeat_weekdays', 'smallint[]', false, null), ('repeat_month_day', 'smallint', false, null),
            ('repeat_tz', 'text', false, null), ('series_id', 'uuid', false, null), ('next_occurrence_id', 'uuid', false, null),
            ('rotation', 'uuid[]', false, null), ('turn_user_id', 'uuid', false, null), ('completed_by', 'uuid', false, null) $$,
  'tasks v2 columns: types, nullability, defaults');
select fk_ok('public', 'task_checklist_items', array['task_id', 'group_id'], 'public', 'tasks', array['id', 'group_id'],
  'task_checklist_items → tasks(id, group_id)');
select fk_ok('public', 'tasks', 'turn_user_id', 'public', 'profiles', 'id', 'tasks.turn_user_id → profiles');
select fk_ok('public', 'tasks', 'completed_by', 'public', 'profiles', 'id', 'tasks.completed_by → profiles');
select fk_ok('public', 'group_activity', 'group_id', 'public', 'groups', 'id', 'group_activity → groups');
select results_eq(
  $$ select (c.conrelid::regclass::text || '.' || c.conname::text) collate "default", c.confdeltype::text
     from pg_constraint c
     where c.contype = 'f'
       and c.conrelid in ('public.tasks'::regclass, 'public.task_checklist_items'::regclass, 'public.group_activity'::regclass)
       and c.conname in ('tasks_turn_user_id_fkey', 'tasks_completed_by_fkey', 'task_checklist_items_task_fkey',
                         'task_checklist_items_done_by_fkey', 'group_activity_group_id_fkey', 'group_activity_actor_id_fkey',
                         'group_activity_subject_id_fkey')
     order by (c.conrelid::regclass::text || '.' || c.conname::text) collate "C" $$,
  $$ values ('group_activity.group_activity_actor_id_fkey', 'n'), ('group_activity.group_activity_group_id_fkey', 'c'),
            ('group_activity.group_activity_subject_id_fkey', 'n'), ('task_checklist_items.task_checklist_items_done_by_fkey', 'n'),
            ('task_checklist_items.task_checklist_items_task_fkey', 'c'), ('tasks.tasks_completed_by_fkey', 'n'),
            ('tasks.tasks_turn_user_id_fkey', 'n') $$,
  'v2 foreign keys: cascade with the group / task, SET NULL for profiles');
select has_index('public', 'group_activity', 'group_activity_group_id_id_idx', array['group_id', 'id'],
  'group_activity index (group_id, id desc)');
select col_is_unique('public', 'task_checklist_items', array['task_id', 'position'], 'checklist positions are unique per task');
select policies_are('public', 'task_checklist_items', array['task_checklist_items_select'], 'task_checklist_items: SELECT policy only');
select policies_are('public', 'group_activity', array['group_activity_select'], 'group_activity: SELECT policy only');

-- Emoji validation (§1) ----------------------------------------------------------------------------------------
select is(tests.emoji(null), '<null>', 'emoji: NULL stays NULL');
select is(tests.emoji(E' \t🏠 '), '🏠', 'emoji: trimmed with clean_text');
select is(tests.emoji(E' ​　 '), '<null>', 'emoji: blank → NULL');
select is(tests.emoji('👨‍👩‍👧‍👦'), '👨‍👩‍👧‍👦', 'emoji: a ZWJ sequence (7 code points) is accepted');
select is(tests.emoji('🇫🇷'), '🇫🇷', 'emoji: a flag is accepted');
select is(tests.emoji('1️⃣'), '1️⃣', 'emoji: a keycap sequence is accepted');
select is(tests.emoji(repeat('😀', 16)), repeat('😀', 16), 'emoji: 16 code points are accepted');
select is(tests.emoji(repeat('😀', 17)), 'invalid_emoji', 'emoji: 17 code points are refused');
select is(tests.emoji('😀 😀'), 'invalid_emoji', 'emoji: an inner space is refused');
select is(tests.emoji(E'😀 😀'), 'invalid_emoji', 'emoji: an inner no-break space (trim set) is refused');
select is(tests.emoji(E'😀​😀'), 'invalid_emoji', 'emoji: an inner zero-width space (trim set) is refused');
select is(tests.emoji(E'😀\u0007'), 'invalid_emoji', 'emoji: a C0 control is refused');
select is(tests.emoji(E'😀\u0085😀'), 'invalid_emoji', 'emoji: a C1 control is refused');
select is(tests.emoji(E'😀\u009f'), 'invalid_emoji', 'emoji: U+009F is refused');
select is(tests.emoji(E'😀\u001f'), 'invalid_emoji', 'emoji: U+001F (not trimmed by clean_text) is refused');

-- create_group with appearance ------------------------------------------------------------------------------------
select tests.as_user('alice');
insert into tests.results select 'lilas', to_jsonb(g) from public.create_group('Coloc', 'coral', ' 🏠 ') as g;
insert into tests.ids select 'Lilas', (value ->> 'id')::uuid from tests.results where name = 'lilas';
select is((select value ->> 'color' from tests.results where name = 'lilas') || ' ' || (select value ->> 'emoji' from tests.results where name = 'lilas'),
  'coral 🏠', 'create_group stores the color and the trimmed emoji');
insert into tests.results select 'v1', to_jsonb(g) from public.create_group(p_name => 'Groupe v1') as g;
select ok((select value ->> 'color' is null and value ->> 'emoji' is null from tests.results where name = 'v1'),
  'a v1 create_group call (p_name only) still works: automatic color, no emoji');
select throws_ok($$ select public.create_group('Rouge', 'red') $$, 'P0001', 'invalid_color', 'an unknown color is refused');
select throws_ok($$ select public.create_group('Corail', 'Coral') $$, 'P0001', 'invalid_color', 'color keys are case sensitive');
select throws_ok($$ select public.create_group('Vide', '') $$, 'P0001', 'invalid_color', 'an empty color is refused (NULL = automatic)');
select throws_ok($$ select public.create_group('Trop', null, repeat('😀', 17)) $$, 'P0001', 'invalid_emoji', 'a long emoji is refused');
select throws_ok($$ select public.create_group('   ', 'red', 'x y') $$, 'P0001', 'invalid_name', 'the name is checked first');
select throws_ok($$ select public.create_group('Deux', 'red', 'x y') $$, 'P0001', 'invalid_color', 'the color before the emoji');

-- set_group_appearance -------------------------------------------------------------------------------------------------
select tests.as_postgres();
select tests.add_member('Lilas', 'bob');
update public.groups set last_activity_at = '2000-01-01' where id = tests.id('Lilas');
delete from tests.events;

select tests.as_user('bob');
select throws_ok(format($$ select public.set_group_appearance(%L, 'blue', null) $$, tests.id('Lilas')), '42501', 'forbidden',
  'a member cannot change the appearance');
select tests.as_user('eve');
select throws_ok(format($$ select public.set_group_appearance(%L, 'blue', null) $$, tests.id('Lilas')), '42501', 'forbidden',
  'a non-member cannot change the appearance');
select throws_ok(format($$ select public.set_group_appearance(%L, 'blue', null) $$, gen_random_uuid()), 'P0001', 'group_not_found',
  'an unknown group raises group_not_found');
select tests.as_user('alice');
select throws_ok(format($$ select public.set_group_appearance(%L, 'marron', 'x y') $$, tests.id('Lilas')), 'P0001', 'invalid_color',
  'set_group_appearance: color before emoji');
select throws_ok(format($$ select public.set_group_appearance(%L, 'teal', E'a\u0007') $$, tests.id('Lilas')), 'P0001', 'invalid_emoji',
  'set_group_appearance: invalid emoji');
select tests.as_postgres();
select is(tests.events_for('Lilas'), 0, 'refused calls write nothing');
select tests.as_user('alice');
select results_eq(
  format($$ select color, emoji, last_activity_at from public.set_group_appearance(%L, 'teal', '⚽') $$, tests.id('Lilas')),
  $$ values ('teal', '⚽', now()) $$,
  'the admin sets the color and the emoji; last_activity_at is bumped');
select tests.as_postgres();
select is(tests.events_for('Lilas'), 1, 'one groups UPDATE (Realtime signal)');
select tests.as_user('alice');
select results_eq(
  format($$ select color, emoji from public.set_group_appearance(%L, null, '  ') $$, tests.id('Lilas')),
  $$ values (null::text, null::text) $$,
  'NULL = automatic color, a blank emoji = no emoji');
select throws_ok(format($$ update public.groups set color = 'pink' where id = %L $$, tests.id('Lilas')), '42501',
  'permission denied for table groups', 'groups cannot be updated directly, even by an admin');
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok(format($$ select public.set_group_appearance(%L, null, null) $$, tests.id('Lilas')), 'P0001', 'not_authenticated',
  'set_group_appearance requires a user');
select tests.as_anon();
select throws_ok(format($$ select public.set_group_appearance(%L, null, null) $$, tests.id('Lilas')), '42501',
  'permission denied for function set_group_appearance', 'anon cannot call set_group_appearance');
select tests.as_postgres();

-- The check constraints are the last line of defense.
alter table public.groups disable trigger groups_before_write;
select throws_ok(format($$ update public.groups set color = 'red' where id = %L $$, tests.id('Lilas')), '23514', null,
  'groups_color_key check constraint');
select throws_ok(format($$ update public.groups set emoji = 'a b' where id = %L $$, tests.id('Lilas')), '23514', null,
  'groups_emoji_format check constraint');
alter table public.groups enable trigger groups_before_write;

-- Avatar (profiles) ------------------------------------------------------------------------------------------------
update public.profiles set updated_at = '2000-01-01' where id = tests.id('alice');
select tests.as_user('alice');
select is(
  tests.affected($$ update public.profiles set avatar_color = 'violet', avatar_emoji = E' 🦊\n' where id = auth.uid() $$),
  1, 'a user sets their avatar color and emoji (column grant)');
select results_eq(
  $$ select avatar_color, avatar_emoji, updated_at from public.profiles where id = auth.uid() $$,
  $$ values ('violet', '🦊', now()) $$,
  'the avatar emoji is trimmed; updated_at is maintained');
select throws_ok($$ update public.profiles set avatar_color = 'noir' where id = auth.uid() $$, 'P0001', 'invalid_color',
  'invalid avatar color');
select throws_ok($$ update public.profiles set avatar_emoji = repeat('🦊', 17) where id = auth.uid() $$, 'P0001', 'invalid_emoji',
  'invalid avatar emoji');
select throws_ok($$ update public.profiles set avatar_color = 'noir', avatar_emoji = 'a b' where id = auth.uid() $$, 'P0001',
  'invalid_color', 'avatar: color before emoji');
select throws_ok($$ update public.profiles set display_name = '', avatar_color = 'noir' where id = auth.uid() $$, 'P0001',
  'invalid_display_name', 'avatar: the display name is checked first');
select is(tests.affected(format($$ update public.profiles set avatar_color = 'pink' where id = %L $$, tests.id('bob'))), 0,
  'another user''s avatar cannot be changed (0 rows)');
select throws_ok($$ update public.profiles set onboarded_at = now() where id = auth.uid() $$, '42501',
  'permission denied for table profiles', 'onboarded_at is not updatable by users');
select tests.as_user('bob');
select results_eq(
  format($$ select avatar_color, avatar_emoji from public.profiles where id = %L $$, tests.id('alice')),
  $$ values ('violet', '🦊') $$,
  'co-members read the avatar');
select tests.as_postgres();
update public.profiles set updated_at = '2000-01-01' where id = tests.id('alice');
select tests.as_user('alice');
select lives_ok($$ update public.profiles set avatar_color = 'violet', avatar_emoji = '🦊' where id = auth.uid() $$,
  'an identical avatar update');
select is((select updated_at from public.profiles where id = auth.uid()), '2000-01-01'::timestamptz,
  'an identical avatar update keeps updated_at');
select lives_ok($$ update public.profiles set avatar_color = null, avatar_emoji = null where id = auth.uid() $$,
  'NULL = automatic color, no emoji');
select tests.as_postgres();
alter table public.profiles disable trigger profiles_before_write;
select throws_ok(format($$ update public.profiles set avatar_color = 'red' where id = %L $$, tests.id('bob')), '23514', null,
  'profiles_avatar_color_key check constraint');
select throws_ok(format($$ update public.profiles set avatar_emoji = repeat('x', 17) where id = %L $$, tests.id('bob')), '23514', null,
  'profiles_avatar_emoji_format check constraint');
alter table public.profiles enable trigger profiles_before_write;

-- Onboarding (§2, §9) ----------------------------------------------------------------------------------------------
select is((select onboarded_at from public.profiles where id = tests.id('eve')), null, 'a new profile starts with onboarded_at NULL');

-- The migration backfill: onboarded_at = created_at for every profile without one; others are kept.
select tests.create_user('old1');
select tests.create_user('old2');
-- Accounts created before v2 (created_at is immutable: the fixture bypasses the trigger).
alter table public.profiles disable trigger profiles_before_write;
update public.profiles set created_at = '2026-01-05 10:00+00', onboarded_at = null where id = tests.id('old1');
update public.profiles set created_at = '2026-02-01 08:00+00', onboarded_at = '2026-02-03 09:00+00' where id = tests.id('old2');
alter table public.profiles enable trigger profiles_before_write;
select ok(private.backfill_onboarded_at() >= 1, 'the backfill updates the profiles without onboarded_at');
select results_eq(
  $$ select onboarded_at from public.profiles where id in (tests.id('old1'), tests.id('old2')) order by created_at $$,
  $$ values ('2026-01-05 10:00+00'::timestamptz), ('2026-02-03 09:00+00'::timestamptz) $$,
  'backfill: onboarded_at = created_at; an existing value is kept');
select is((select count(*)::int from public.profiles where onboarded_at is null), 0, 'backfill: no profile is left NULL');
select ok(not has_function_privilege('authenticated', 'private.backfill_onboarded_at()', 'EXECUTE'),
  'API roles cannot run the backfill');

update public.profiles set onboarded_at = null where id = tests.id('eve');
delete from tests.events;
select tests.as_user('eve');
select lives_ok($$ select public.complete_onboarding() $$, 'complete_onboarding');
select tests.as_postgres();
select is((select onboarded_at from public.profiles where id = tests.id('eve')), now(), 'onboarded_at = now()');
select is(tests.events_for('eve'), 1, 'one profiles UPDATE (the user''s other devices reload)');
update public.profiles set onboarded_at = '2026-03-01' where id = tests.id('eve');
delete from tests.events;
select tests.as_user('eve');
select lives_ok($$ select public.complete_onboarding() $$, 'complete_onboarding again');
select tests.as_postgres();
select is((select onboarded_at from public.profiles where id = tests.id('eve')), '2026-03-01'::timestamptz,
  'onboarded_at = coalesce(onboarded_at, now()): an existing value is kept');
select is(tests.events_for('eve'), 0, 'and nothing is written');
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok($$ select public.complete_onboarding() $$, 'P0001', 'not_authenticated', 'complete_onboarding requires a user');
select tests.as_postgres();
delete from auth.users where id = tests.id('old1');
select tests.as_user('old1');
select throws_ok($$ select public.complete_onboarding() $$, 'P0001', 'not_authenticated', 'stale JWT: complete_onboarding');
select tests.as_anon();
select throws_ok($$ select public.complete_onboarding() $$, '42501', 'permission denied for function complete_onboarding',
  'anon cannot call complete_onboarding');
select tests.as_postgres();

select * from finish();
rollback;
