-- v3 « Relancer » (docs/CONTRACTS-V3.md §1): nudge_task permissions, validation and rate limit, the rows, the task_nudged
-- events, the group signal, the ntfy push (first name, wording, limits) and the RLS of task_nudges.
begin;
select plan(48);

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
-- A plain task of p_group created by p_creator (trusted fixture), assigned to p_assignees by p_creator.
create function tests.plain_task(p_name text, p_group text, p_creator text, p_assignees text[] default '{}',
                                 p_status public.task_status default 'todo') returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into public.tasks (group_id, title, created_by, status)
  values (tests.id(p_group), p_name, tests.id(p_creator), p_status) returning id into v_id;
  insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
  select v_id, tests.id(p_group), tests.id(a), tests.id(p_creator) from unnest(p_assignees) as a;
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
-- Events of a group written after the mark p_mark: "kind actor subject «task_title»", oldest first.
create function tests.feed(p_group text, p_mark text) returns text language sql security definer as $$
  select coalesce(string_agg(a.kind || ' ' || tests.name(a.actor_id) || ' ' || tests.name(a.subject_id)
                             || coalesce(' «' || a.task_title || '»', ''), ' | ' order by a.id), '')
  from public.group_activity a
  where a.group_id = tests.id(p_group)
    and a.id > (select (r.value #>> '{}')::bigint from tests.results r where r.name = p_mark)
$$;
create function tests.mark(p_name text) returns void language sql security definer as $$
  insert into tests.results values (p_name, to_jsonb((select coalesce(max(id), 0) from public.group_activity)));
$$;
-- Requests queued by pg_net in this transaction.
create function tests.pushes() returns table (body jsonb) language sql security definer as $$
  select convert_from(q.body, 'UTF8')::jsonb
  from net.http_request_queue q
  where q.id > (select (r.value #>> '{}')::bigint from tests.results r where r.name = 'queue start')
  order by q.id
$$;
-- The nudges of a task as "from>to", sorted.
create function tests.nudges(p_task text) returns text language sql security definer as $$
  select coalesce(string_agg(tests.name(n.from_user) || '>' || tests.name(n.to_user), ',' order by tests.name(n.from_user), tests.name(n.to_user)), '')
  from public.task_nudges n where n.task_id = tests.id(p_task)
$$;
-- Every UPDATE of groups (what Realtime would broadcast).
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

select tests.create_user('admin', 'Camille Martin');
select tests.create_user('creator', 'Jean-Pierre Durand');
select tests.create_user('bob', 'Bob');
select tests.create_user('carol', 'Carol');
select tests.create_user('member', 'Inès Dubois');
select tests.create_user('outsider', 'Outsider');
select tests.create_group('G', 'admin');
select tests.add_member('G', u) from unnest(array['creator', 'bob', 'carol', 'member']) as u;
select tests.create_group('Other', 'outsider');

select tests.plain_task('T', 'G', 'creator', array['bob', 'carol', 'member']);
select tests.plain_task('Done', 'G', 'creator', array['bob'], 'done');
select tests.plain_task('Nobody', 'G', 'creator');
select tests.plain_task('Mine', 'G', 'creator', array['member']);
select tests.plain_task('OtherTask', 'Other', 'outsider', array['outsider']);

-- Push setup: bob and carol are subscribed; member is not.
insert into public.push_subscriptions (user_id, topic) values
  (tests.id('bob'), 'equipe-bbbbbbbbbbbbbbbbbbbbbbbb'),
  (tests.id('carol'), 'equipe-cccccccccccccccccccccccc');
update private.settings set value = 'https://ntfy.example.test/' where key = 'ntfy_base_url';
insert into tests.results values ('queue start', to_jsonb((select coalesce(max(q.id), 0) from net.http_request_queue q)));

-- Permissions and validation ---------------------------------------------------------------------------------------------
select tests.as_user('outsider');
select throws_ok(format($$ select public.nudge_task(%L) $$, tests.id('T')), 'P0001', 'task_not_found',
  'a non-member gets task_not_found');
select throws_ok($$ select public.nudge_task(gen_random_uuid()) $$, 'P0001', 'task_not_found', 'an unknown task: task_not_found');
select tests.as_user('member');
select throws_ok(format($$ select public.nudge_task(%L) $$, tests.id('Done')), 'P0001', 'task_done', 'a done task: task_done');
select throws_ok(format($$ select public.nudge_task(%L) $$, tests.id('Nobody')), 'P0001', 'nudge_no_recipient',
  'a task without assignee: nudge_no_recipient');
select throws_ok(format($$ select public.nudge_task(%L) $$, tests.id('Mine')), 'P0001', 'nudge_no_recipient',
  'a task assigned to the caller only: nudge_no_recipient');
select tests.as_postgres();
select tests.as_anon();
select throws_ok(format($$ select public.nudge_task(%L) $$, tests.id('T')), '42501', 'permission denied for function nudge_task',
  'anon cannot nudge');
select tests.as_postgres();
select throws_ok(format($$ select public.nudge_task(%L) $$, tests.id('T')), 'P0001', 'not_authenticated',
  'no JWT: not_authenticated');

-- A nudge by a plain member (neither editor nor assignee of T) ---------------------------------------------------------------
select tests.rewind();
select tests.mark('first');
select tests.as_user('admin');
select is(public.nudge_task(tests.id('T')), 3, 'any member may nudge: the number of people nudged');
select tests.as_postgres();
select is(tests.nudges('T'), 'admin>bob,admin>carol,admin>member', 'one row per current assignee');
select is((select count(*)::int from public.task_nudges where task_id = tests.id('T') and group_id = tests.id('G') and created_at = now()), 3,
  'rows carry the group and now()');
select bag_eq(
  $$ select a.kind || ' ' || tests.name(a.actor_id) || ' ' || tests.name(a.subject_id) || ' ' || a.task_title from public.group_activity a
     where a.group_id = tests.id('G') and a.id > (select (r.value #>> '{}')::bigint from tests.results r where r.name = 'first') $$,
  array['task_nudged admin bob T', 'task_nudged admin carol T', 'task_nudged admin member T'],
  'one task_nudged event per recipient (user id order): actor = caller, subject = recipient, task_title snapshot');
select is((select count(*)::int from public.group_activity where kind = 'task_nudged' and task_id = tests.id('T')), 3,
  'the events reference the task');
select is(tests.events_for('G'), 1, 'the nudge bumps the group once');

-- The push: « <prénom> te relance dans « <groupe> » » to each subscribed recipient.
select is((select count(*)::int from tests.pushes()), 2, 'two pushes: bob and carol (member has no subscription)');
select is((select p.body from tests.pushes() p where p.body ->> 'topic' = 'equipe-bbbbbbbbbbbbbbbbbbbbbbbb'),
  jsonb_build_object(
    'topic', 'equipe-bbbbbbbbbbbbbbbbbbbbbbbb',
    'title', 'Teamly',
    'message', 'Camille te relance dans «' || chr(160) || 'G' || chr(160) || '»',
    'click', 'equipe://task/' || tests.id('G') || '/' || tests.id('T')),
  'push body: title Teamly, the sender''s first name, no-break spaces inside the guillemets, deep link to the task');
select is((select count(*)::int from private.push_log where task_id = tests.id('T') and kind = 'nudge'), 2, 'the pushes are logged as nudges');

-- Rate limit: one nudge per (task, caller) in 20 hours (inclusive) ---------------------------------------------------------------
select tests.as_user('admin');
select throws_ok(format($$ select public.nudge_task(%L) $$, tests.id('T')), 'P0001', 'nudge_rate_limited',
  'a second nudge within 20 hours: nudge_rate_limited');
select tests.as_postgres();
select is((select count(*)::int from public.task_nudges where task_id = tests.id('T')), 3, 'a refused nudge writes no row');
select is((select count(*)::int from public.group_activity where kind = 'task_nudged'), 3, 'nor any event');
update public.task_nudges set created_at = now() - interval '20 hours' where task_id = tests.id('T');
select tests.as_user('admin');
select throws_ok(format($$ select public.nudge_task(%L) $$, tests.id('T')), 'P0001', 'nudge_rate_limited',
  'a nudge exactly 20 hours old still counts');
select tests.as_postgres();
update public.task_nudges set created_at = now() - interval '20 hours 1 second' where task_id = tests.id('T');
select tests.as_user('admin');
select is(public.nudge_task(tests.id('T')), 3, 'after 20 hours the caller may nudge again');
select tests.as_postgres();
select is((select count(*)::int from tests.pushes()), 2,
  'but each recipient gets at most one nudge push per task per hour (the second nudge is not pushed)');

-- Another member may nudge the same task; the recipients are the assignees except the caller.
select tests.as_user('bob');
select is(public.nudge_task(tests.id('T')), 2, 'bob (an assignee) nudges the two others');
select tests.as_postgres();
select is((select string_agg(tests.name(to_user), ',' order by tests.name(to_user)) from public.task_nudges
           where task_id = tests.id('T') and from_user = tests.id('bob')), 'carol,member', 'the caller is never nudged');
select is((select count(*)::int from tests.pushes()), 2, 'carol was already pushed for this task within the hour');

-- A nudge push is not blocked by an assignment push of the same task (kinds are separate), and uses the first word.
select tests.plain_task('U', 'G', 'creator');
select tests.as_user('creator');
select public.set_task_assignees(tests.id('U'), array[tests.id('bob')]);
select tests.as_postgres();
select is((select count(*)::int from tests.pushes() p where p.body ->> 'message' like 'Nouvelle tâche%'), 1, 'bob got the assignment push');
select tests.as_user('creator');
select public.nudge_task(tests.id('U'));
select tests.as_postgres();
select is((select count(*)::int from tests.pushes() p where p.body ->> 'message' = 'Jean-Pierre te relance dans «' || chr(160) || 'G' || chr(160) || '»'), 1,
  'then the nudge push, « Jean-Pierre » (a hyphenated first name is one word)');

-- The per-user hourly limit counts every kind.
update private.push_log set queued_at = now() - interval '2 hours' where user_id = tests.id('carol');
insert into private.push_log (user_id, task_id, queued_at)
select tests.id('carol'), gen_random_uuid(), now() - interval '10 minutes' from generate_series(1, 30);
select tests.plain_task('V', 'G', 'creator', array['carol']);
insert into tests.results values ('pushes before V', to_jsonb((select count(*) from tests.pushes())));
select tests.as_user('member');
select is(public.nudge_task(tests.id('V')), 1, 'carol is nudged');
select tests.as_postgres();
select is((select count(*)::int from tests.pushes()), (select (value #>> '{}')::int from tests.results where name = 'pushes before V'),
  'but not pushed: she reached push_max_per_hour (30), assignment pushes included');
select is((select count(*)::int from public.task_nudges where task_id = tests.id('V')), 1, 'the nudge row is written anyway');

-- Push off: no request, the nudge still works.
update private.settings set value = null where key = 'ntfy_base_url';
select tests.plain_task('W', 'G', 'creator', array['bob']);
insert into tests.results values ('pushes before W', to_jsonb((select count(*) from tests.pushes())));
select tests.as_user('member');
select is(public.nudge_task(tests.id('W')), 1, 'push turned off: the nudge works');
select tests.as_postgres();
select is((select count(*)::int from tests.pushes()), (select (value #>> '{}')::int from tests.results where name = 'pushes before W'),
  'and nothing is queued');

-- first_name ---------------------------------------------------------------------------------------------------------------
select is(private.first_name(' Camille Martin '), 'Camille', 'first_name: the first word');
select is(private.first_name('Jean-Pierre Durand'), 'Jean-Pierre', 'first_name: a hyphen does not split');
select is(private.first_name('Inès'), 'Inès', 'first_name: a single word');
select is(private.first_name('Anne' || chr(160) || 'Sophie'), 'Anne', 'first_name: a no-break space splits');
select is(private.push_message('mention', tests.id('member'), tests.id('G')),
  'Inès t' || chr(8217) || 'a mentionné dans «' || chr(160) || 'G' || chr(160) || '»', 'the mention wording (U+2019)');

-- RLS and privileges ---------------------------------------------------------------------------------------------------------
select tests.as_user('bob');
select bag_eq($$ select tests.name(from_user) || '>' || tests.name(to_user) from public.task_nudges where task_id = tests.id('T') $$,
  array['admin>bob', 'admin>bob', 'bob>carol', 'bob>member'], 'the recipient and the sender see their own nudges');
select tests.as_user('carol');
select is((select count(*)::int from public.task_nudges where from_user = tests.id('admin') and to_user = tests.id('bob')), 0,
  'a member sees nobody else''s nudges');
select tests.as_user('outsider');
select is((select count(*)::int from public.task_nudges), 0, 'a non-member sees nothing');
select tests.as_user('bob');
select throws_ok(format($$ insert into public.task_nudges (task_id, group_id, from_user, to_user) values (%L, %L, %L, %L) $$,
    tests.id('T'), tests.id('G'), tests.id('bob'), tests.id('carol')),
  '42501', 'permission denied for table task_nudges', 'no direct INSERT');
select throws_ok($$ update public.task_nudges set created_at = now() - interval '1 day' $$,
  '42501', 'permission denied for table task_nudges', 'no direct UPDATE (the rate limit cannot be bypassed)');
select throws_ok($$ delete from public.task_nudges $$, '42501', 'permission denied for table task_nudges', 'no direct DELETE');
select tests.as_anon();
select throws_ok($$ select count(*) from public.task_nudges $$, '42501', 'permission denied for table task_nudges', 'anon cannot read');
select tests.as_postgres();

-- A member who left no longer sees the nudges sent to them.
delete from public.group_members where group_id = tests.id('G') and user_id = tests.id('carol');
select tests.as_user('carol');
select is((select count(*)::int from public.task_nudges), 0, 'after leaving the group, nothing is visible');
select tests.as_postgres();

-- Cascades: deleting the task deletes its nudges; deleting an account deletes theirs.
select tests.as_user('creator');
select public.delete_task(tests.id('T'));
select tests.as_postgres();
select is((select count(*)::int from public.task_nudges where task_id = tests.id('T')), 0, 'deleting the task deletes its nudges');
delete from auth.users where id = tests.id('bob');
select is((select count(*)::int from public.task_nudges where from_user = tests.id('bob') or to_user = tests.id('bob')), 0,
  'deleting an account deletes its nudges');
select is((select count(*)::int from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'task_nudges'), 1,
  'task_nudges is published to Realtime');

select * from finish();
rollback;
