-- v3 « Bravo » (docs/CONTRACTS-V3.md §4): toggle_reaction (permissions, the five emojis, add / remove, target_user), the
-- group signal, the cascades (retention, deleted accounts) and the RLS of activity_reactions.
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

create function tests.name(p_id uuid) returns text language sql stable as $$
  select coalesce((select i.name from tests.ids i where i.id = p_id order by i.name limit 1), 'null')
$$;
-- An activity event (trusted fixture), named p_name in tests.results.
create function tests.event(p_name text, p_group text, p_kind text, p_actor text, p_subject text default null) returns bigint
language plpgsql security definer as $$
declare v_id bigint;
begin
  perform private.log_activity(tests.id(p_group), p_kind, tests.id(p_actor), tests.id(p_subject), null, 'Titre', null);
  select max(id) into v_id from public.group_activity;
  insert into tests.results values (p_name, to_jsonb(v_id));
  return v_id;
end $$;
create function tests.ev(p_name text) returns bigint language sql stable as $$
  select (value #>> '{}')::bigint from tests.results where name = p_name
$$;
-- The reactions of an event as "user:emoji-codepoints>target", sorted.
create function tests.reactions(p_event text) returns text language sql security definer as $$
  select coalesce(string_agg(x.label, ',' order by x.label), '')
  from (select tests.name(r.user_id) || ':' || (select string_agg(to_hex(ascii(c)), '+') from regexp_split_to_table(r.emoji, '') as c)
               || '>' || tests.name(r.target_user) as label
        from public.activity_reactions r where r.activity_id = tests.ev(p_event)) x
$$;
create table tests.events (id uuid);
create function tests.log_event() returns trigger language plpgsql security definer as $$
begin
  insert into tests.events values (new.id);
  return null;
end $$;
create trigger log_groups_update after update on public.groups for each row execute function tests.log_event();
create function tests.events_for(p_name text) returns integer language sql security definer as $$
  select count(*)::int from tests.events where id = tests.id(p_name)
$$;
create function tests.rewind() returns void language plpgsql security definer as $$
begin
  update public.groups set last_activity_at = '2000-01-01' where id in (select id from tests.ids);
  delete from tests.events where true;
end $$;

select tests.create_user(u) from unnest(array['admin', 'bob', 'carol', 'outsider']) as u;
select tests.create_group('G', 'admin');
select tests.add_member('G', 'bob');
select tests.add_member('G', 'carol');
select tests.create_group('Other', 'outsider');
select tests.event('E1', 'G', 'task_completed', 'bob');
select tests.event('E2', 'G', 'turn_started', null, 'carol');
select tests.event('EO', 'Other', 'task_completed', 'outsider');

-- Errors (§4) ---------------------------------------------------------------------------------------------------------------
select tests.as_user('outsider');
select throws_ok(format($$ select public.toggle_reaction(%s, %L) $$, tests.ev('E1'), chr(128079)), 'P0001', 'activity_not_found',
  'a non-member: activity_not_found');
select throws_ok(format($$ select public.toggle_reaction(%s, %L) $$, tests.ev('E1'), 'x'), 'P0001', 'activity_not_found',
  'the event comes first: activity_not_found before invalid_reaction');
select tests.as_user('carol');
select throws_ok(format($$ select public.toggle_reaction(%s, %L) $$, tests.ev('EO'), chr(128079)), 'P0001', 'activity_not_found',
  'an event of another group: activity_not_found');
select throws_ok(format($$ select public.toggle_reaction(%s, %L) $$, 999999999, chr(128079)), 'P0001', 'activity_not_found',
  'an unknown event: activity_not_found');
select throws_ok(format($$ select public.toggle_reaction(%s, %L) $$, tests.ev('E1'), chr(128077)), 'P0001', 'invalid_reaction',
  'an emoji outside the set (👍): invalid_reaction');
select throws_ok(format($$ select public.toggle_reaction(%s, %L) $$, tests.ev('E1'), chr(10084)), 'P0001', 'invalid_reaction',
  '❤ without the variation selector U+FE0F: invalid_reaction (exact comparison)');
select throws_ok(format($$ select public.toggle_reaction(%s, null) $$, tests.ev('E1')), 'P0001', 'invalid_reaction', 'NULL: invalid_reaction');
select throws_ok(format($$ select public.toggle_reaction(%s, '') $$, tests.ev('E1')), 'P0001', 'invalid_reaction', 'empty: invalid_reaction');
select tests.as_anon();
select throws_ok(format($$ select public.toggle_reaction(%s, %L) $$, tests.ev('E1'), chr(128079)),
  '42501', 'permission denied for function toggle_reaction', 'anon cannot react');
select tests.as_postgres();
select throws_ok(format($$ select public.toggle_reaction(%s, %L) $$, tests.ev('E1'), chr(128079)), 'P0001', 'not_authenticated',
  'no JWT: not_authenticated');

-- Toggle ---------------------------------------------------------------------------------------------------------------------
select tests.rewind();
select tests.as_user('carol');
select is(public.toggle_reaction(tests.ev('E1'), chr(128079)), true, 'toggle_reaction adds a reaction: true');
select tests.as_postgres();
select results_eq(
  $$ select group_id, user_id, target_user, emoji, created_at from public.activity_reactions where activity_id = tests.ev('E1') $$,
  $$ values (tests.id('G'), tests.id('carol'), tests.id('bob'), chr(128079), now()) $$,
  'the row: the event''s group, the caller, target_user = the event''s actor');
select is(tests.events_for('G'), 1, 'a reaction bumps the group');
select tests.as_user('carol');
select is(public.toggle_reaction(tests.ev('E1'), chr(128293)), true, 'another emoji on the same event');
select is(public.toggle_reaction(tests.ev('E1'), chr(10084) || chr(65039)), true, '❤️ (U+2764 U+FE0F)');
select tests.as_user('admin');
select is(public.toggle_reaction(tests.ev('E1'), chr(128079)), true, 'another member, the same emoji');
select tests.as_postgres();
select is(tests.reactions('E1'), 'admin:1f44f>bob,carol:1f44f>bob,carol:1f525>bob,carol:2764+fe0f>bob',
  'one row per (event, user, emoji)');
select tests.rewind();
select tests.as_user('carol');
select is(public.toggle_reaction(tests.ev('E1'), chr(128079)), false, 'toggling again removes it: false');
select tests.as_postgres();
select is(tests.reactions('E1'), 'admin:1f44f>bob,carol:1f525>bob,carol:2764+fe0f>bob', 'only that reaction is removed');
select is(tests.events_for('G'), 1, 'a removal bumps the group too');
select tests.as_user('carol');
select is(public.toggle_reaction(tests.ev('E1'), chr(128079)), true, 'and adding it back: true');

-- An event without actor (turn_started): target_user NULL. The five emojis.
select tests.as_user('bob');
select is(
  (select array_agg(public.toggle_reaction(tests.ev('E2'), e) order by o)
   from unnest(array[chr(128079), chr(128293), chr(128170), chr(10084) || chr(65039), chr(128514)]) with ordinality as x (e, o)),
  array[true, true, true, true, true], 'the five emojis 👏 🔥 💪 ❤️ 😂 are accepted');
select tests.as_postgres();
select is((select count(*)::int from public.activity_reactions where activity_id = tests.ev('E2') and target_user is null), 5,
  'an event without actor: target_user NULL');

-- RLS and privileges -----------------------------------------------------------------------------------------------------------
select tests.as_user('bob');
select is((select count(*)::int from public.activity_reactions), 9, 'members read the reactions of their groups');
select tests.as_user('outsider');
select is((select count(*)::int from public.activity_reactions), 0, 'a non-member reads nothing');
select tests.as_user('carol');
select throws_ok(format($$ insert into public.activity_reactions (activity_id, group_id, user_id, emoji) values (%s, %L, %L, %L) $$,
    tests.ev('E2'), tests.id('G'), tests.id('carol'), chr(128514)),
  '42501', 'permission denied for table activity_reactions', 'no direct INSERT');
select throws_ok($$ update public.activity_reactions set target_user = null $$, '42501', 'permission denied for table activity_reactions',
  'no direct UPDATE');
select throws_ok($$ delete from public.activity_reactions $$, '42501', 'permission denied for table activity_reactions', 'no direct DELETE');
select tests.as_anon();
select throws_ok($$ select count(*) from public.activity_reactions $$, '42501', 'permission denied for table activity_reactions',
  'anon cannot read');
select tests.as_postgres();
select throws_ok(format($$ insert into public.activity_reactions (activity_id, group_id, user_id, emoji) values (%s, %L, %L, %L) $$,
    tests.ev('E2'), tests.id('G'), tests.id('admin'), chr(128077)),
  '23514', null, 'check constraint: the five emojis only');
select col_is_pk('public', 'activity_reactions', array['activity_id', 'user_id', 'emoji'], 'pk (activity_id, user_id, emoji)');
select fk_ok('public', 'activity_reactions', 'activity_id', 'public', 'group_activity', 'id',
  'activity_reactions → group_activity(id): the feed embeds reactions:activity_reactions(user_id,emoji)');
select is((select count(*)::int from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'activity_reactions'), 1,
  'activity_reactions is published to Realtime');

-- Cascades -------------------------------------------------------------------------------------------------------------------------
-- A member who leaves no longer sees the reactions; their rows stay.
delete from public.group_members where group_id = tests.id('G') and user_id = tests.id('carol');
select tests.as_user('carol');
select is((select count(*)::int from public.activity_reactions), 0, 'after leaving, nothing is visible');
select tests.as_postgres();
select is((select count(*)::int from public.activity_reactions where user_id = tests.id('carol')), 3, 'the rows stay');
-- The actor's account is deleted: target_user becomes NULL. The reactor's account is deleted: their reactions go.
delete from auth.users where id = tests.id('bob');
select is((select count(*)::int from public.activity_reactions where activity_id = tests.ev('E1') and target_user is null), 4,
  'the event''s actor deleted: target_user NULL (ON DELETE SET NULL)');
select is((select count(*)::int from public.activity_reactions where activity_id = tests.ev('E2')), 0,
  'the reactor deleted: their reactions are deleted');
delete from auth.users where id = tests.id('carol');
select is(tests.reactions('E1'), 'admin:1f44f>null', 'only the remaining member''s reaction is left');
-- Retention: an event older than 90 days is deleted with its reactions when a new event is written.
update public.group_activity set created_at = now() - interval '91 days' where id = tests.ev('E1');
select tests.event('E3', 'G', 'member_joined', 'admin', 'admin');
select is((select count(*)::int from public.activity_reactions where activity_id = tests.ev('E1')), 0,
  'retention deletes the event and its reactions');
select is((select count(*)::int from public.group_activity where id = tests.ev('E1')), 0, 'the event is gone');

select * from finish();
rollback;
