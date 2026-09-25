-- v2 activity feed (docs/CONTRACTS-V2.md §7): every kind, snapshots, retention, RLS, account deletion; and
-- tasks.completed_by (§2).
begin;
select plan(47);

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

create function tests.name(p_id uuid) returns text language sql stable as $$
  select coalesce((select i.name from tests.ids i where i.id = p_id order by i.name limit 1), 'null')
$$;
create function tests.task(p_name text) returns public.tasks language sql security definer as $$
  select * from public.tasks where id = tests.id(p_name)
$$;
-- The events of a group written after the mark p_mark (an activity id), oldest first:
-- "kind actor subject [task_title] [item_title]" (ids as names, NULL as null).
create function tests.feed(p_group text, p_mark text default null) returns text language sql security definer as $$
  select coalesce(string_agg(
    a.kind || ' ' || tests.name(a.actor_id) || ' ' || tests.name(a.subject_id)
      || coalesce(' «' || a.task_title || '»', '') || coalesce(' «' || a.item_title || '»', ''),
    ' | ' order by a.id), '')
  from public.group_activity a
  where a.group_id = tests.id(p_group)
    and a.id > coalesce((select (r.value #>> '{}')::bigint from tests.results r where r.name = p_mark), 0)
$$;
create function tests.mark(p_name text) returns void language sql security definer as $$
  insert into tests.results values (p_name, to_jsonb((select coalesce(max(id), 0) from public.group_activity)));
$$;

select tests.create_user(u) from unnest(array['alice', 'bob', 'carol', 'dave', 'eve', 'frank', 'gina']) as u;

-- member_joined (§7) -------------------------------------------------------------------------------------------------
select tests.mark('start');
select tests.as_user('alice');
insert into tests.ids select 'G', id from public.create_group('Coloc');
select tests.as_postgres();
select is(tests.feed('G', 'start'), '', 'create_group: the creator''s own membership is not a join');
update public.group_invites set code = 'ACTV2345' where group_id = tests.id('G');
select tests.as_user('bob');
select public.join_group_by_code('actv-2345');
select is(tests.feed('G', 'start'), 'member_joined bob bob', 'join_group_by_code: member_joined, actor = subject = the member');
select public.join_group_by_code('ACTV2345');
select is(tests.feed('G', 'start'), 'member_joined bob bob', 'already_member writes nothing');
select tests.as_postgres();
select tests.add_member('G', 'carol');
select tests.add_member('G', 'dave');
select tests.add_member('G', 'frank');
select is(tests.feed('G', 'start'), 'member_joined bob bob | member_joined carol carol | member_joined dave dave | member_joined frank frank',
  'a trusted membership insert is a join too');
select tests.create_group('Solo', 'frank');
select is(tests.feed('Solo', 'start'), '', 'the first member of a group (its creator) is not a join');

-- task_created / task_completed ---------------------------------------------------------------------------------------
select tests.mark('tasks');
select tests.as_user('bob');
insert into tests.ids select 'T', id from public.create_task(tests.id('G'), '  Vaisselle ', null, 'medium', null, array[tests.id('carol')]);
select tests.as_user('carol');
insert into public.tasks (group_id, title) values (tests.id('G'), 'Directe');
insert into tests.ids select 'D', id from public.tasks where title = 'Directe';
select tests.as_postgres();
insert into public.tasks (group_id, title, created_by) values (tests.id('G'), 'Import', tests.id('bob'));
insert into tests.ids select 'I', id from public.tasks where title = 'Import';
select is(tests.feed('G', 'tasks'), 'task_created bob null «Vaisselle» | task_created carol null «Directe»',
  'task_created: create_task and a direct INSERT by end users (trimmed title snapshot); not a trusted insert');
select results_eq(
  $$ select task_id, created_at from public.group_activity where group_id = tests.id('G') and kind = 'task_created' and actor_id = tests.id('bob') $$,
  $$ values (tests.id('T'), now()) $$,
  'task_created references the task');

select tests.mark('done');
select tests.as_user('carol');
select public.set_task_status(tests.id('T'), 'done');
select public.set_task_status(tests.id('T'), 'done');
select is(tests.feed('G', 'done'), 'task_completed carol null «Vaisselle»', 'task_completed once (done → done writes nothing)');
select public.set_task_status(tests.id('T'), 'in_progress');
update public.tasks set status = 'done' where id = tests.id('T');
select tests.as_postgres();
update public.tasks set status = 'done' where id = tests.id('I');
select is(tests.feed('G', 'done'),
  'task_completed carol null «Vaisselle» | task_completed carol null «Vaisselle» | task_completed null null «Import»',
  'task_completed again after a reopen (direct PATCH); a trusted completion has no actor');

-- completed_by (§2) -----------------------------------------------------------------------------------------------------
select is((tests.task('T')).completed_by, tests.id('carol'), 'completed_by = the user whose change made the status done');
select tests.as_user('bob');
select public.set_task_status(tests.id('T'), 'done');
select is((tests.task('T')).completed_by, tests.id('carol'), 'done → done keeps completed_by');
select public.update_task(tests.id('T'), 'Vaisselle', null, 'medium', null, null);
select is((tests.task('T')).completed_by, tests.id('carol'), 'editing a done task keeps completed_by');
select public.set_task_status(tests.id('T'), 'todo');
select is((tests.task('T')).completed_by, null, 'leaving done clears completed_by');
select public.set_task_status(tests.id('T'), 'done');
select is((tests.task('T')).completed_by, tests.id('bob'), 'the next completion records the new completer');
select throws_ok(format($$ update public.tasks set completed_by = %L where id = %L $$, tests.id('carol'), tests.id('T')),
  '42501', 'permission denied for table tasks', 'completed_by is not writable by users');
select tests.as_postgres();
select is((tests.task('I')).completed_by, null, 'a trusted completion without explicit value: completed_by NULL');
update public.tasks set status = 'todo' where id = tests.id('I');
update public.tasks set status = 'done', completed_by = tests.id('dave') where id = tests.id('I');
select is((tests.task('I')).completed_by, tests.id('dave'), 'a trusted context may set completed_by explicitly');
insert into public.tasks (group_id, title, status, completed_by, created_by)
values (tests.id('G'), 'Déjà faite', 'done', tests.id('dave'), tests.id('bob'));
select is((select completed_by from public.tasks where title = 'Déjà faite'), tests.id('dave'),
  'a trusted insert of a done task keeps its explicit completed_by');
alter table public.tasks disable trigger tasks_before_update;
select throws_ok(format($$ update public.tasks set status = 'todo', completed_at = null where id = %L $$, tests.id('I')),
  '23514', null, 'check constraint: completed_by only on done tasks');
alter table public.tasks enable trigger tasks_before_update;

-- checklist_item_done ------------------------------------------------------------------------------------------------------
select tests.as_user('bob');
insert into tests.ids select 'item', id from public.add_checklist_item(tests.id('T'), 'Les verres');
select tests.mark('items');
select tests.as_user('carol');
select public.set_checklist_item_done(tests.id('item'), true);
select public.set_checklist_item_done(tests.id('item'), true);
select public.set_checklist_item_done(tests.id('item'), false);
select public.set_checklist_item_done(tests.id('item'), true);
select is(tests.feed('G', 'items'), 'checklist_item_done carol null «Vaisselle» «Les verres» | checklist_item_done carol null «Vaisselle» «Les verres»',
  'checklist_item_done when an item becomes done (not on a no-op, not on uncheck)');
select results_eq(
  $$ select task_id from public.group_activity where group_id = tests.id('G') and kind = 'checklist_item_done' limit 1 $$,
  $$ values (tests.id('T')) $$,
  'checklist_item_done references the task');

-- Snapshots survive renames and deletions --------------------------------------------------------------------------------
select tests.as_user('bob');
select public.update_task(tests.id('T'), 'Vaisselle du soir', null, 'medium', null, null);
select public.rename_checklist_item(tests.id('item'), 'Les assiettes');
select public.delete_task(tests.id('T'));
select tests.as_postgres();
select is((select count(*)::int from public.group_activity
           where task_id = tests.id('T') and task_title = 'Vaisselle' and kind in ('task_created', 'task_completed', 'checklist_item_done')), 6,
  'events keep their snapshots and task_id after the task is renamed and deleted');

-- turn_started (a spawn with a turn holder) and no task_created for spawns --------------------------------------------------
select tests.as_user('bob');
insert into tests.ids select 'R', id from public.create_task(tests.id('G'), 'Poubelles', null, 'medium', '2041-03-02 19:00+00', '{}',
  '{"freq": "weekly", "tz": "Europe/Paris"}', array[tests.id('bob'), tests.id('carol')]);
select tests.mark('turn');
select public.set_task_status(tests.id('R'), 'done');
select tests.as_postgres();
select is(tests.feed('G', 'turn'), 'task_completed bob null «Poubelles» | turn_started null carol «Poubelles»',
  'completing a rotating occurrence: task_completed then turn_started (no task_created for the spawn)');
select is((select task_id from public.group_activity where kind = 'turn_started' and group_id = tests.id('G')),
  (tests.task('R')).next_occurrence_id, 'turn_started references the new occurrence');

-- member_left --------------------------------------------------------------------------------------------------------------
select tests.mark('left');
select tests.as_user('dave');
select public.leave_group(tests.id('G'));
select tests.as_user('alice');
select public.remove_member(tests.id('G'), tests.id('carol'));
select tests.as_postgres();
select is(tests.feed('G', 'left'), 'member_left dave dave | member_left alice carol',
  'member_left: leave (actor = subject) and removal (actor = the admin)');

-- Account deletion: frank is a member of G and alone in Solo.
select tests.mark('deleted');
select tests.as_user('frank');
select lives_ok($$ select public.delete_my_account() $$, 'an account with activity is deleted (no foreign key error)');
select tests.as_postgres();
select is(tests.feed('G', 'deleted'), 'member_left null null', 'account deletion: member_left with the deleted profile as NULL');
select is((select count(*)::int from public.group_activity where group_id = tests.id('Solo')), 0,
  'the deleted user''s solo group is gone with its events');
select is((select count(*)::int from public.group_activity where actor_id = tests.id('frank') or subject_id = tests.id('frank')), 0,
  'earlier events of the deleted user keep no reference to them (ON DELETE SET NULL)');
select is((select count(*)::int from public.group_activity where group_id = tests.id('G') and kind = 'member_joined' and actor_id is null), 1,
  'frank''s member_joined event stays, anonymous');

-- A group that is deleted: no member_left, the events go with the group.
select tests.as_user('alice');
insert into tests.ids select 'H', id from public.create_group('Éphémère');
select tests.as_postgres();
select tests.add_member('H', 'gina');
select tests.as_user('alice');
select public.delete_group(tests.id('H'));
select tests.as_postgres();
select is((select count(*)::int from public.group_activity where group_id = tests.id('H')), 0, 'delete_group: the events are deleted');
select tests.as_user('gina');
insert into tests.ids select 'K', id from public.create_group('Seule');
select public.leave_group(tests.id('K'));
select tests.as_postgres();
select is((select count(*)::int from public.group_activity where group_id = tests.id('K')), 0,
  'the last member leaving deletes the group: no member_left');

-- Retention: events older than 90 days of the same group are deleted when a new event is written -------------------------
select tests.as_user('gina');
insert into tests.ids select 'Other', id from public.create_group('Autre');
select tests.as_postgres();
insert into public.group_activity (group_id, kind, actor_id, created_at) values
  (tests.id('G'), 'member_joined', tests.id('bob'), now() - interval '91 days'),
  (tests.id('G'), 'member_joined', tests.id('bob'), now() - interval '90 days 1 second'),
  (tests.id('G'), 'member_joined', tests.id('bob'), now() - interval '90 days'),
  (tests.id('G'), 'member_joined', tests.id('bob'), now() - interval '89 days'),
  (tests.id('Other'), 'member_joined', tests.id('gina'), now() - interval '100 days');
select is((select count(*)::int from public.group_activity where group_id = tests.id('G') and created_at < now() - interval '88 days'), 4,
  'old events are kept until a new event is written');
select tests.add_member('G', 'eve');
select results_eq(
  $$ select now() - created_at from public.group_activity where group_id = tests.id('G') and created_at < now() - interval '88 days'
     order by created_at $$,
  $$ values (interval '90 days'), (interval '89 days') $$,
  'a new event deletes the group''s events older than 90 days (exactly 90 days old is kept)');
select is((select count(*)::int from public.group_activity where group_id = tests.id('Other')), 1, 'other groups are untouched');
delete from public.group_members where group_id = tests.id('G') and user_id = tests.id('eve');

-- Writing an event does not bump the group (the triggering write does).
update public.groups set last_activity_at = '2000-01-01' where id = tests.id('G');
select private.log_activity(tests.id('G'), 'member_joined', tests.id('bob'), tests.id('bob'), null, null, null);
select is((select last_activity_at from public.groups where id = tests.id('G')), '2000-01-01'::timestamptz,
  'writing an event does not bump the group');
select private.log_activity(gen_random_uuid(), 'member_joined', null, null, null, null, null);
select pass('an event for a group that does not exist is skipped');

-- RLS and privileges (§2) -------------------------------------------------------------------------------------------------
select tests.as_user('bob');
select ok((select count(*) from public.group_activity where group_id = tests.id('G')) > 0, 'members read the feed');
select results_eq(
  $$ select count(*)::int from (
       select id, kind, actor_id, subject_id, task_id, task_title, item_title, created_at
       from public.group_activity where group_id = tests.id('G') order by id desc limit 50) s $$,
  $$ select least(count(*), 50)::int from public.group_activity where group_id = tests.id('G') $$,
  'the contract read (§7) works');
select tests.as_user('eve');
select is((select count(*)::int from public.group_activity where group_id = tests.id('G')), 0, 'non-members read nothing');
select tests.as_user('bob');
select throws_ok(format($$ insert into public.group_activity (group_id, kind) values (%L, 'member_joined') $$, tests.id('G')),
  '42501', 'permission denied for table group_activity', 'no direct INSERT');
select throws_ok($$ update public.group_activity set kind = 'member_left' $$,
  '42501', 'permission denied for table group_activity', 'no direct UPDATE');
select throws_ok($$ delete from public.group_activity $$,
  '42501', 'permission denied for table group_activity', 'no direct DELETE');
select tests.as_anon();
select throws_ok($$ select count(*) from public.group_activity $$,
  '42501', 'permission denied for table group_activity', 'anon cannot read the feed');
select tests.as_postgres();
select ok(not has_function_privilege('authenticated', 'private.log_activity(uuid, text, uuid, uuid, uuid, text, text)', 'EXECUTE'),
  'API roles cannot write events');
select is((select count(*)::int from pg_publication_tables where pubname = 'supabase_realtime' and tablename in ('group_activity', 'task_checklist_items')), 0,
  'nothing new is published to Realtime');
select is((select array_agg(distinct kind order by kind) from public.group_activity where group_id = tests.id('G')),
  array['checklist_item_done', 'member_joined', 'member_left', 'task_completed', 'task_created', 'turn_started'],
  'every kind was written');

select * from finish();
rollback;
