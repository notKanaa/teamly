-- ntfy push on new assignments (docs/CONTRACTS.md §7): what pg_net queues and for whom, the abuse limits,
-- and failures that must never block an assignment. Nothing leaves the database: the transaction is rolled
-- back, and the base URL points to a reserved test domain.
begin;
select plan(43);

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
create function tests.as_postgres() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
end $$;
create function tests.add_member(p_group text, p_user text, p_role public.member_role default 'member') returns void
language sql as $$
  insert into public.group_members (group_id, user_id, role) values (tests.id(p_group), tests.id(p_user), p_role);
$$;
-- Requests queued by this transaction (the queue is transactional: other sessions never see them).
create function tests.pushes() returns table (url text, method text, headers jsonb, body jsonb, raw_body text, timeout_ms integer)
language sql as $$
  select q.url, q.method::text, q.headers, convert_from(q.body, 'UTF8')::jsonb, convert_from(q.body, 'UTF8'),
         q.timeout_milliseconds
  from net.http_request_queue q
  where q.id > (select (r.value #>> '{}')::bigint from tests.results r where r.name = 'queue start')
  order by q.id
$$;
create function tests.push_count() returns integer language sql as $$
  select count(*)::int from tests.pushes()
$$;
create function tests.topic_of_push(p_index integer) returns text language sql as $$
  select p.body ->> 'topic' from tests.pushes() p offset p_index - 1 limit 1
$$;
-- -------------------------------------------------------------------------------------------------------

select tests.create_user('alice');
select tests.create_user('bob');
select tests.create_user('carol');
select tests.create_user('dave');

-- The group name has quotes on purpose (JSON escaping of the message).
with g as (
  insert into public.groups (name, created_by) values ('Coloc'' "rue" des Lilas', tests.id('alice')) returning id
)
insert into tests.ids select 'G', g.id from g;
select tests.add_member('G', 'alice', 'admin');
select tests.add_member('G', 'bob');
select tests.add_member('G', 'carol');
select tests.add_member('G', 'dave');

-- alice, bob and dave are subscribed; carol is not.
insert into public.push_subscriptions (user_id, topic) values
  (tests.id('alice'), 'equipe-aaaaaaaaaaaaaaaaaaaaaaaa'),
  (tests.id('bob'), 'equipe-bbbbbbbbbbbbbbbbbbbbbbbb'),
  (tests.id('dave'), 'equipe-dddddddddddddddddddddddd');

-- The seed turns push off locally (NULL base URL): turn it on for this transaction only.
update private.settings set value = 'https://ntfy.example.test/' where key = 'ntfy_base_url';
insert into tests.results values ('queue start', to_jsonb((select coalesce(max(q.id), 0) from net.http_request_queue q)));

-- Structure --------------------------------------------------------------------------------------------------
select has_extension('pg_net'::name, 'pg_net is installed'::text);
select has_trigger('public', 'task_assignees', 'task_assignees_after_insert_push', 'task_assignees has the push trigger');
select is_definer('private', 'notify_assignment_push', array[]::name[], 'the push trigger function is security definer');
select ok(
  not has_function_privilege('authenticated', 'private.notify_assignment_push()', 'EXECUTE')
  and not has_function_privilege('anon', 'private.notify_assignment_push()', 'EXECUTE'),
  'API roles cannot execute the push trigger function');
select is((select count(*)::int from private.settings where key in ('ntfy_base_url', 'push_max_per_hour')), 2,
  'the push settings exist');

-- create_task by alice for herself (subscribed), bob (subscribed) and carol (no subscription) ---------------------
select tests.as_user('alice');
insert into tests.ids values ('T1', (public.create_task(tests.id('G'), 'Titre secret 42', 'Détails secrets', 'high', null,
  array[tests.id('alice'), tests.id('bob'), tests.id('carol')])).id);
select tests.as_postgres();

select is(tests.push_count(), 1, 'one push is queued: bob only (no self-assignment push, carol has no subscription)');
select results_eq($$ select url, method from tests.pushes() $$,
  $$ values ('https://ntfy.example.test/'::text, 'POST'::text) $$,
  'POST to the configured base URL: the topic is not part of the URL');
select is((select headers from tests.pushes()), '{"Content-Type": "application/json"}'::jsonb, 'JSON content type');
select is((select body from tests.pushes()),
  jsonb_build_object(
    'topic', 'equipe-bbbbbbbbbbbbbbbbbbbbbbbb',
    'title', 'Équipe',
    'message', 'Nouvelle tâche assignée dans « Coloc'' "rue" des Lilas »',
    'click', 'equipe://task/' || tests.id('G')::text || '/' || tests.id('T1')::text),
  'ntfy JSON body: topic, title, message with the group name, click deep link');
select is((select timeout_ms from tests.pushes()), 5000, '5 s timeout');
select ok((select bool_and(position('Titre secret' in raw_body) = 0 and position('Détails secrets' in raw_body) = 0)
           from tests.pushes()),
  'the task title and details are never sent');
select is((select count(*)::int from private.push_log where user_id = tests.id('bob') and task_id = tests.id('T1')), 1,
  'the push is logged');
select is((select count(*)::int from public.task_assignees where task_id = tests.id('T1')), 3, 'the 3 assignments exist');

-- Editing the assignees: existing rows are kept (ON CONFLICT DO NOTHING), only new assignees are notified ---
select tests.as_user('alice');
select public.set_task_assignees(tests.id('T1'), array[tests.id('bob'), tests.id('dave')]);
select tests.as_postgres();
select is(tests.push_count(), 2, 'keeping bob and adding dave queues exactly one more push');
select is(tests.topic_of_push(2), 'equipe-dddddddddddddddddddddddd', 'for dave');

select tests.as_user('alice');
select public.update_task(tests.id('T1'), 'Titre secret 42', null, 'high', null, array[tests.id('bob'), tests.id('dave')]);
select tests.as_postgres();
select is(tests.push_count(), 2, 'update_task with the same assignees queues nothing');

-- Abuse control: one push per (user, task) per hour -----------------------------------------------------------
select tests.as_user('alice');
select public.set_task_assignees(tests.id('T1'), array[tests.id('dave')]);
select public.set_task_assignees(tests.id('T1'), array[tests.id('dave'), tests.id('bob')]);
select tests.as_postgres();
select is(tests.push_count(), 2, 'removing and re-adding bob within the hour does not push again');
select is((select count(*)::int from public.task_assignees where task_id = tests.id('T1') and user_id = tests.id('bob')), 1,
  'but bob is assigned again');

update private.push_log set queued_at = now() - interval '1 hour' where user_id = tests.id('bob');
select tests.as_user('alice');
select public.set_task_assignees(tests.id('T1'), array[tests.id('dave')]);
select public.set_task_assignees(tests.id('T1'), array[tests.id('dave'), tests.id('bob')]);
select tests.as_postgres();
select is(tests.push_count(), 2, 'a push exactly one hour old still counts');

update private.push_log set queued_at = now() - interval '1 hour 1 second' where user_id = tests.id('bob');
select tests.as_user('alice');
select public.set_task_assignees(tests.id('T1'), array[tests.id('dave')]);
select public.set_task_assignees(tests.id('T1'), array[tests.id('dave'), tests.id('bob')]);
select tests.as_postgres();
select is(tests.push_count(), 3, 'after one hour, a re-assignment pushes again');
select is(tests.topic_of_push(3), 'equipe-bbbbbbbbbbbbbbbbbbbbbbbb', 'to bob');
select is((select count(*)::int from private.push_log where user_id = tests.id('bob')), 1,
  'log rows older than one hour are pruned');

-- Abuse control: at most push_max_per_hour (30) pushes per user per hour ------------------------------------------
select is((select value from private.settings where key = 'push_max_per_hour'), '30', 'default: 30 pushes per user per hour');
-- dave already has 1 push in the last hour: 29 more make 30.
insert into private.push_log (user_id, task_id, queued_at)
select tests.id('dave'), gen_random_uuid(), now() - interval '30 minutes' from generate_series(1, 29);
select tests.as_user('alice');
insert into tests.ids values ('T2', (public.create_task(tests.id('G'), 'Deuxième', null, 'low', null,
  array[tests.id('dave'), tests.id('bob')])).id);
select tests.as_postgres();
select is(tests.push_count(), 4, 'dave reached 30 pushes this hour: only bob is notified for T2');
select is(tests.topic_of_push(4), 'equipe-bbbbbbbbbbbbbbbbbbbbbbbb', 'the new push is bob''s');
select is((select count(*)::int from public.task_assignees where task_id = tests.id('T2')), 2, 'dave is still assigned');

update private.settings set value = '31' where key = 'push_max_per_hour';
select tests.as_user('alice');
insert into tests.ids values ('T3', (public.create_task(tests.id('G'), 'Troisième', null, 'low', null, array[tests.id('dave')])).id);
select tests.as_postgres();
select is(tests.push_count(), 5, 'the per-user limit is read from private.settings');

update private.settings set value = 'n/a' where key = 'push_max_per_hour';
select tests.as_user('alice');
insert into tests.ids values ('T4', (public.create_task(tests.id('G'), 'Quatrième', null, 'low', null, array[tests.id('dave')])).id);
select tests.as_postgres();
select is(tests.push_count(), 5, 'an invalid limit falls back to the default (30)');
update private.settings set value = '30' where key = 'push_max_per_hour';

-- Push turned off: NULL or empty base URL --------------------------------------------------------------------------
update private.settings set value = null where key = 'ntfy_base_url';
select tests.as_user('alice');
insert into tests.ids values ('T5', (public.create_task(tests.id('G'), 'Cinquième', null, 'low', null, array[tests.id('bob')])).id);
select tests.as_postgres();
select is(tests.push_count(), 5, 'no push while the base URL is NULL (local stack, CI)');
update private.settings set value = '' where key = 'ntfy_base_url';
select tests.as_user('alice');
insert into tests.ids values ('T6', (public.create_task(tests.id('G'), 'Sixième', null, 'low', null, array[tests.id('bob')])).id);
select tests.as_postgres();
select is(tests.push_count(), 5, 'nor while it is empty');
select is((select count(*)::int from public.task_assignees where task_id in (tests.id('T5'), tests.id('T6'))), 2,
  'the assignments are saved');
select is((select count(*)::int from private.push_log where task_id in (tests.id('T5'), tests.id('T6'))), 0,
  'and nothing is logged');
update private.settings set value = 'https://ntfy.example.test/' where key = 'ntfy_base_url';

-- No assignee, subscription changes ---------------------------------------------------------------------------------
select tests.as_user('alice');
insert into tests.ids values ('T7', (public.create_task(tests.id('G'), 'Septième', null, 'low', null, '{}')).id);
select tests.as_postgres();
select is(tests.push_count(), 5, 'a task without assignees queues nothing');

select tests.as_user('bob');
select public.disable_push();
select tests.as_user('alice');
insert into tests.ids values ('T8', (public.create_task(tests.id('G'), 'Huitième', null, 'low', null, array[tests.id('bob')])).id);
select tests.as_postgres();
select is(tests.push_count(), 5, 'no push after disable_push');

select tests.as_user('carol');
insert into tests.results values ('carol topic', to_jsonb(public.enable_push()));
select tests.as_user('alice');
insert into tests.ids values ('T9', (public.create_task(tests.id('G'), 'Neuvième', null, 'low', null, array[tests.id('carol')])).id);
select tests.as_postgres();
select is(tests.push_count(), 6, 'a push after enable_push');
select is(tests.topic_of_push(6), (select value #>> '{}' from tests.results where name = 'carol topic'), 'to the new topic');

-- Failures never block the assignment ---------------------------------------------------------------------------------
-- Any error inside the push block (here: the log insert) rolls back that block only, including the queued request.
alter table private.push_log add constraint tests_always_fails check (user_id is null) not valid;
select tests.as_user('alice');
select lives_ok(
  format($$ insert into tests.ids values ('T10', (public.create_task(%L, 'Dixième', null, 'low', null, array[%L]::uuid[])).id) $$,
         tests.id('G'), tests.id('carol')),
  'a failure while queuing the push does not fail create_task');
select tests.as_postgres();
select is((select count(*)::int from public.task_assignees where task_id = tests.id('T10')), 1, 'the assignment is saved');
select is(tests.push_count(), 6, 'and no request is left in the queue');
alter table private.push_log drop constraint tests_always_fails;

-- Account deletion removes the user's push log (cascade from the profile).
delete from auth.users where id = tests.id('dave');
select is((select count(*)::int from private.push_log where user_id = tests.id('dave')), 0,
  'deleting an account deletes its push log');

-- pg_net missing (e.g. disabled from the dashboard): assignments still work. Keep this block last.
drop extension pg_net;
select tests.as_user('alice');
select lives_ok(
  format($$ insert into tests.ids values ('T11', (public.create_task(%L, 'Onzième', null, 'low', null, array[%L]::uuid[])).id) $$,
         tests.id('G'), tests.id('carol')),
  'create_task still works without pg_net');
select public.set_task_assignees(tests.id('T11'), '{}');
select lives_ok(format($$ select public.set_task_assignees(%L, array[%L]::uuid[]) $$, tests.id('T11'), tests.id('carol')),
  'set_task_assignees too');
select tests.as_postgres();
select is((select count(*)::int from public.task_assignees where task_id = tests.id('T11')), 1, 'the assignment is saved');

select * from finish();
rollback;
