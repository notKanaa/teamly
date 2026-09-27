-- v3 « Commentaires » (docs/CONTRACTS-V3.md §5): add_task_comment (permissions, body and mention validation, order of the
-- errors), the comment_added event, the group signal, the mention pushes, delete_task_comment, cascades and the RLS of
-- task_comments.
begin;
select plan(44);

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
create function tests.ids_of(p_names text[]) returns uuid[] language sql stable as $$
  select array(select tests.id(n) from unnest(p_names) with ordinality as x (n, o) order by o)
$$;
create function tests.names_of(p_ids uuid[]) returns text language sql stable as $$
  select coalesce(string_agg(tests.name(u.id), ',' order by u.o), '') from unnest(p_ids) with ordinality as u (id, o)
$$;
-- add_task_comment as p_user; the comment is named p_name.
create function tests.comment(p_name text, p_user text, p_task text, p_body text, p_mentions text[] default null) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  perform tests.as_user(p_user);
  select c.id into v_id from public.add_task_comment(tests.id(p_task), p_body,
    case when p_mentions is null then '{}'::uuid[] else tests.ids_of(p_mentions) end) c;
  perform tests.as_postgres();
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
create function tests.row_of(p_name text) returns public.task_comments language sql security definer as $$
  select * from public.task_comments where id = tests.id(p_name)
$$;
create function tests.mark(p_name text) returns void language sql security definer as $$
  insert into tests.results values (p_name, to_jsonb((select coalesce(max(id), 0) from public.group_activity)));
$$;
create function tests.since(p_mark text) returns bigint language sql stable as $$
  select (r.value #>> '{}')::bigint from tests.results r where r.name = p_mark
$$;
create function tests.pushes() returns table (body jsonb) language sql security definer as $$
  select convert_from(q.body, 'UTF8')::jsonb
  from net.http_request_queue q
  where q.id > (select (r.value #>> '{}')::bigint from tests.results r where r.name = 'queue start')
  order by q.id
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

select tests.create_user('admin', 'Admin');
select tests.create_user('creator', 'Creator');
select tests.create_user('bob', 'Bob');
select tests.create_user('carol', 'Carol Martin');
select tests.create_user('dave', 'Dave');
select tests.create_user('outsider', 'Outsider');
select tests.create_group('G', 'admin');
select tests.add_member('G', u) from unnest(array['creator', 'bob', 'carol', 'dave']) as u;
select tests.create_group('Other', 'outsider');
insert into public.tasks (group_id, title, created_by) values (tests.id('G'), 'Vaisselle', tests.id('creator'));
insert into tests.ids select 'T', id from public.tasks where title = 'Vaisselle';
insert into public.task_assignees (task_id, group_id, user_id, assigned_by) values (tests.id('T'), tests.id('G'), tests.id('bob'), tests.id('creator'));
insert into public.push_subscriptions (user_id, topic) values
  (tests.id('bob'), 'equipe-bbbbbbbbbbbbbbbbbbbbbbbb'),
  (tests.id('carol'), 'equipe-cccccccccccccccccccccccc'),
  (tests.id('dave'), 'equipe-dddddddddddddddddddddddd');
update private.settings set value = 'https://ntfy.example.test/' where key = 'ntfy_base_url';
insert into tests.results values ('queue start', to_jsonb((select coalesce(max(q.id), 0) from net.http_request_queue q)));

-- Errors, in order (§5) ------------------------------------------------------------------------------------------------------
select tests.as_user('outsider');
select throws_ok(format($$ select public.add_task_comment(%L, 'Salut') $$, tests.id('T')), 'P0001', 'task_not_found',
  'a non-member: task_not_found');
select throws_ok(format($$ select public.add_task_comment(%L, '  ') $$, tests.id('T')), 'P0001', 'task_not_found',
  'task_not_found comes before invalid_comment');
select tests.as_user('carol');
select throws_ok($$ select public.add_task_comment(gen_random_uuid(), 'Salut') $$, 'P0001', 'task_not_found', 'an unknown task');
select throws_ok(format($$ select public.add_task_comment(%L, %L) $$, tests.id('T'), E' \n\t' || chr(8203)), 'P0001', 'invalid_comment',
  'a blank body (trim set of CONTRACTS.md §1)');
select throws_ok(format($$ select public.add_task_comment(%L, null) $$, tests.id('T')), 'P0001', 'invalid_comment', 'a NULL body');
select throws_ok(format($$ select public.add_task_comment(%L, %L) $$, tests.id('T'), repeat('é', 1001)), 'P0001', 'invalid_comment',
  '1001 code points');
select throws_ok(format($$ select public.add_task_comment(%L, '  ', array[%L]::uuid[]) $$, tests.id('T'), tests.id('outsider')),
  'P0001', 'invalid_comment', 'invalid_comment comes before invalid_mentions');
select throws_ok(format($$ select public.add_task_comment(%L, 'Salut', array[%L]::uuid[]) $$, tests.id('T'), tests.id('outsider')),
  'P0001', 'invalid_mentions', 'a mentioned non-member: invalid_mentions');
select throws_ok(format($$ select public.add_task_comment(%L, 'Salut', array[%L, null]::uuid[]) $$, tests.id('T'), tests.id('bob')),
  'P0001', 'invalid_mentions', 'a NULL mention: invalid_mentions');
select throws_ok(format($$ select public.add_task_comment(%L, 'Salut', %L::uuid[]) $$, tests.id('T'),
    (select array_agg(gen_random_uuid()) from generate_series(1, 21))),
  'P0001', 'invalid_mentions', 'more than 20 mentions: invalid_mentions');
select throws_ok(format($$ select public.add_task_comment(%L, 'Salut', array[[%L, %L]]::uuid[]) $$, tests.id('T'), tests.id('bob'), tests.id('dave')),
  'P0001', 'invalid_mentions', 'a two-dimensional array: invalid_mentions');
select tests.as_anon();
select throws_ok(format($$ select public.add_task_comment(%L, 'Salut') $$, tests.id('T')),
  '42501', 'permission denied for function add_task_comment', 'anon cannot comment');
select tests.as_postgres();

-- A comment by a plain member (neither editor nor assignee) ---------------------------------------------------------------------
select tests.rewind();
select tests.mark('first');
select tests.comment('C1', 'carol', 'T', E'  Bien joué, @bob !\n', array['bob', 'dave', 'bob', 'carol']);
select results_eq(
  $$ select task_id, group_id, author_id, body, created_at from tests.row_of('C1') $$,
  $$ values (tests.id('T'), tests.id('G'), tests.id('carol'), 'Bien joué, @bob !', now()) $$,
  'any member comments; the body is trimmed');
select is(tests.names_of((tests.row_of('C1')).mentions), 'bob,dave,carol', 'duplicate mentions are dropped, the order is kept');
select results_eq(
  $$ select kind, actor_id, subject_id, task_id, task_title, item_title from public.group_activity where id > tests.since('first') $$,
  $$ values ('comment_added', tests.id('carol'), null::uuid, tests.id('T'), 'Vaisselle', 'Bien joué, @bob !') $$,
  'a comment_added event: actor = author, task_title snapshot, item_title = the body');
select is(tests.events_for('G'), 1, 'a comment bumps the group');

-- Pushes to the mentioned users, never to the author.
select is((select count(*)::int from tests.pushes()), 2, 'two pushes: bob and dave (carol mentioned herself)');
select is((select p.body from tests.pushes() p where p.body ->> 'topic' = 'equipe-dddddddddddddddddddddddd'),
  jsonb_build_object(
    'topic', 'equipe-dddddddddddddddddddddddd',
    'title', 'Teamly',
    'message', 'Carol t' || chr(8217) || 'a mentionné dans «' || chr(160) || 'G' || chr(160) || '»',
    'click', 'equipe://task/' || tests.id('G') || '/' || tests.id('T')),
  'push body: « Carol t’a mentionné dans « G » », no comment text, deep link to the task');
select tests.comment('C2', 'dave', 'T', 'Je m''en occupe demain', array['bob']);
select is((select count(*)::int from tests.pushes()), 2, 'at most one mention push per (user, task) per hour');
select tests.comment('C3', 'bob', 'T', 'OK');
select is((tests.row_of('C3')).mentions, '{}'::uuid[], 'no mention: an empty array');
select tests.as_user('bob');
select is((public.add_task_comment(tests.id('T'), 'Sans mention', null)).mentions, '{}'::uuid[], 'NULL p_mentions: none');
select tests.as_postgres();

-- Limits: 1000 code points; item_title = the first 80 code points; 20 mentions.
select tests.comment('C4', 'admin', 'T', repeat('é', 998) || 'xy');
select is(char_length((tests.row_of('C4')).body), 1000, '1000 code points are accepted');
select is((select item_title from public.group_activity where kind = 'comment_added' and actor_id = tests.id('admin')), repeat('é', 80),
  'item_title keeps the first 80 code points of the body');
select tests.create_user(u) from unnest(array['m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'm8', 'm9', 'm10', 'm11', 'm12', 'm13', 'm14', 'm15']) as u;
select tests.add_member('G', u) from unnest(array['m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'm8', 'm9', 'm10', 'm11', 'm12', 'm13', 'm14', 'm15']) as u;
select tests.comment('C5', 'admin', 'T', 'Tout le monde',
  array['creator', 'bob', 'carol', 'dave', 'admin', 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'm8', 'm9', 'm10', 'm11', 'm12', 'm13', 'm14', 'm15']);
select is(cardinality((tests.row_of('C5')).mentions), 20, '20 mentions are accepted');
select throws_ok(format($$ insert into public.task_comments (task_id, group_id, author_id, body) values (%L, %L, %L, '') $$,
    tests.id('T'), tests.id('G'), tests.id('admin')),
  '23514', null, 'check constraint: 1–1000 characters');

-- RLS and privileges ---------------------------------------------------------------------------------------------------------------
select tests.as_user('m1');
select is((select count(*)::int from public.task_comments where task_id = tests.id('T')), 6,
  'the contract read (task_comments?task_id=eq.<t>) returns every comment to a member');
select tests.as_user('outsider');
select is((select count(*)::int from public.task_comments), 0, 'a non-member reads nothing');
select tests.as_user('carol');
select throws_ok(format($$ insert into public.task_comments (task_id, group_id, author_id, body) values (%L, %L, %L, 'x') $$,
    tests.id('T'), tests.id('G'), tests.id('carol')),
  '42501', 'permission denied for table task_comments', 'no direct INSERT');
select throws_ok($$ update public.task_comments set body = 'x' $$, '42501', 'permission denied for table task_comments', 'no direct UPDATE');
select throws_ok($$ delete from public.task_comments $$, '42501', 'permission denied for table task_comments', 'no direct DELETE');
select tests.as_anon();
select throws_ok($$ select count(*) from public.task_comments $$, '42501', 'permission denied for table task_comments', 'anon cannot read');
select tests.as_postgres();

-- delete_task_comment: the author or an admin ---------------------------------------------------------------------------------------
select tests.as_user('outsider');
select throws_ok(format($$ select public.delete_task_comment(%L) $$, tests.id('C1')), 'P0001', 'comment_not_found',
  'a non-member: comment_not_found');
select throws_ok($$ select public.delete_task_comment(gen_random_uuid()) $$, 'P0001', 'comment_not_found', 'an unknown comment');
select tests.as_user('creator');
select throws_ok(format($$ select public.delete_task_comment(%L) $$, tests.id('C1')), '42501', 'forbidden',
  'the task''s creator (not the author, not an admin): forbidden');
select tests.rewind();
select tests.as_user('carol');
select lives_ok(format($$ select public.delete_task_comment(%L) $$, tests.id('C1')), 'the author deletes their comment');
select tests.as_user('admin');
select lives_ok(format($$ select public.delete_task_comment(%L) $$, tests.id('C2')), 'an admin deletes someone else''s comment');
select tests.as_postgres();
select is((select count(*)::int from public.task_comments where id in (tests.id('C1'), tests.id('C2'))), 0, 'both are gone');
select is(tests.events_for('G'), 1, 'a deletion bumps the group');
select is((select count(*)::int from public.group_activity where kind = 'comment_added' and task_id = tests.id('T')), 6,
  'the comment_added events stay (snapshots)');

-- Cascades ------------------------------------------------------------------------------------------------------------------------------
delete from public.group_members where group_id = tests.id('G') and user_id = tests.id('bob');
select tests.as_user('bob');
select throws_ok(format($$ select public.delete_task_comment(%L) $$, tests.id('C3')), 'P0001', 'comment_not_found',
  'an author who left the group no longer sees their comment');
select tests.as_postgres();
delete from auth.users where id = tests.id('bob');
select is((tests.row_of('C3')).author_id, null, 'a deleted author: the comment stays, author_id NULL');
select tests.as_user('dave');
select throws_ok(format($$ select public.delete_task_comment(%L) $$, tests.id('C3')), '42501', 'forbidden',
  'an anonymous comment: only admins may delete it');
select tests.as_postgres();
delete from public.tasks where id = tests.id('T');
select is((select count(*)::int from public.task_comments where task_id = tests.id('T')), 0, 'deleting the task deletes its comments');
select is((select count(*)::int from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'task_comments'), 1,
  'task_comments is published to Realtime');

select * from finish();
rollback;
