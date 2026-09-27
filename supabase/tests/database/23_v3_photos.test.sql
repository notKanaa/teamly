-- v3 « Photo preuve » (docs/CONTRACTS-V3.md §6): the private bucket, the storage.objects policies, attach_task_photo
-- (permissions, path validation against storage.objects, the limit of 5), delete_task_photo, cascades and the RLS of
-- task_photos.
begin;
select plan(52);

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
-- `<group>/<task>/<file>` with lowercase ids, stored under the name p_name in tests.results.
create function tests.path(p_name text, p_group text, p_task text, p_file text) returns text language plpgsql as $$
declare v_path text := tests.id(p_group)::text || '/' || tests.id(p_task)::text || '/' || p_file;
begin
  insert into tests.results values (p_name, to_jsonb(v_path));
  return v_path;
end $$;
create function tests.p(p_name text) returns text language sql stable as $$
  select value #>> '{}' from tests.results where name = p_name
$$;
-- A stored object (trusted fixture, as the Storage API would write it): bucket task-photos, owner p_owner.
create function tests.object(p_path text, p_owner text) returns void language sql as $$
  insert into storage.objects (bucket_id, name, owner_id) values ('task-photos', p_path, tests.id(p_owner)::text);
$$;
-- attach_task_photo as p_user; the photo row is named p_name.
create function tests.attach(p_name text, p_user text, p_task text, p_path text) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  perform tests.as_user(p_user);
  select tp.id into v_id from public.attach_task_photo(tests.id(p_task), p_path) tp;
  perform tests.as_postgres();
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
create function tests.mark(p_name text) returns void language sql security definer as $$
  insert into tests.results values (p_name, to_jsonb((select coalesce(max(id), 0) from public.group_activity)));
$$;
create function tests.since(p_mark text) returns bigint language sql stable as $$
  select (r.value #>> '{}')::bigint from tests.results r where r.name = p_mark
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

select tests.create_user(u) from unnest(array['admin', 'creator', 'bob', 'carol', 'outsider']) as u;
select tests.create_group('G', 'admin');
select tests.add_member('G', u) from unnest(array['creator', 'bob', 'carol']) as u;
select tests.create_group('Other', 'outsider');
insert into public.tasks (group_id, title, created_by) values (tests.id('G'), 'Salle de bain', tests.id('creator')), (tests.id('G'), 'Cuisine', tests.id('creator'));
insert into tests.ids select 'T', id from public.tasks where title = 'Salle de bain';
insert into tests.ids select 'U', id from public.tasks where title = 'Cuisine';
insert into public.tasks (group_id, title, created_by) values (tests.id('Other'), 'Ailleurs', tests.id('outsider'));
insert into tests.ids select 'OT', id from public.tasks where title = 'Ailleurs';
insert into public.task_assignees (task_id, group_id, user_id, assigned_by) values (tests.id('T'), tests.id('G'), tests.id('bob'), tests.id('creator'));

-- The bucket and its policies (§6) ----------------------------------------------------------------------------------------------
select results_eq(
  $$ select public, file_size_limit, allowed_mime_types from storage.buckets where id = 'task-photos' $$,
  $$ values (false, 5242880::bigint, array['image/jpeg', 'image/png', 'image/heic']) $$,
  'the private bucket task-photos: 5 MiB, JPEG / PNG / HEIC');
select set_eq(
  $$ select polname::text || ':' || polcmd::text || ':' || array_to_string(polroles::regrole[], ',') from pg_policy
     where polrelid = 'storage.objects'::regclass and polname like 'task_photos_objects_%' $$,
  array['task_photos_objects_select:r:authenticated', 'task_photos_objects_insert:a:authenticated',
        'task_photos_objects_delete:d:authenticated'],
  'select, insert and delete policies for authenticated; no update policy');

select tests.path('f1', 'G', 'T', 'aaaaaaaa-0000-4000-8000-000000000001.jpg');
select tests.path('fo', 'Other', 'OT', 'aaaaaaaa-0000-4000-8000-0000000000ff.jpg');
select tests.object(tests.p('fo'), 'outsider');
select tests.as_user('carol');
select lives_ok(format($$ insert into storage.objects (bucket_id, name, owner_id) values ('task-photos', %L, auth.uid()::text) $$, tests.p('f1')),
  'a member uploads into their group''s folder');
select throws_ok(format($$ insert into storage.objects (bucket_id, name, owner_id) values ('task-photos', %L, auth.uid()::text) $$,
    tests.id('Other') || '/' || tests.id('OT') || '/aaaaaaaa-0000-4000-8000-0000000000fe.jpg'),
  '42501', 'new row violates row-level security policy for table "objects"', 'not into another group''s folder');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id) values ('task-photos', 'pas-un-uuid/photo.jpg', auth.uid()::text) $$,
  '42501', 'new row violates row-level security policy for table "objects"', 'a malformed first segment is refused without error');
select results_eq($$ select name from storage.objects where bucket_id = 'task-photos' $$, $$ values (tests.p('f1')) $$,
  'a member reads the objects of their groups only');
select tests.as_user('outsider');
select results_eq($$ select name from storage.objects where bucket_id = 'task-photos' $$, $$ values (tests.p('fo')) $$,
  'and a non-member does not read them');
select tests.as_postgres();

-- attach_task_photo (§6) ---------------------------------------------------------------------------------------------------------------
select tests.object(tests.path('p1', 'G', 'T', 'bbbbbbbb-0000-4000-8000-000000000001.jpg'), 'bob');
select tests.object(tests.path('p2', 'G', 'T', 'bbbbbbbb-0000-4000-8000-000000000002.png'), 'creator');
select tests.object(tests.path('p3', 'G', 'T', 'bbbbbbbb-0000-4000-8000-000000000003.heic'), 'admin');
select tests.object(tests.path('p4', 'G', 'T', 'bbbbbbbb-0000-4000-8000-000000000004.jpeg'), 'bob');
select tests.object(tests.path('p5', 'G', 'T', 'bbbbbbbb-0000-4000-8000-000000000005.jpg'), 'bob');
select tests.object(tests.path('p6', 'G', 'T', 'bbbbbbbb-0000-4000-8000-000000000006.jpg'), 'bob');
select tests.object(tests.path('pu', 'G', 'U', 'bbbbbbbb-0000-4000-8000-000000000007.jpg'), 'bob');
select tests.object(tests.path('pbad', 'G', 'T', 'photo.jpg'), 'bob');
select tests.object(tests.path('pgif', 'G', 'T', 'bbbbbbbb-0000-4000-8000-000000000008.gif'), 'bob');
select tests.object(tests.path('pnest', 'G', 'T', 'sub/bbbbbbbb-0000-4000-8000-000000000009.jpg'), 'bob');
select tests.object(tests.path('pfile', 'G', 'T', 'BBBBBBBB-0000-4000-8000-00000000000A.jpg'), 'bob');
insert into tests.results values ('pupper', to_jsonb(upper(tests.id('G')::text) || '/' || upper(tests.id('T')::text) || '/bbbbbbbb-0000-4000-8000-00000000000b.jpg'));
select tests.object(tests.p('pupper'), 'bob');
select tests.path('pmissing', 'G', 'T', 'bbbbbbbb-0000-4000-8000-00000000000c.jpg');

select tests.as_user('outsider');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('p1')), 'P0001', 'task_not_found',
  'a non-member: task_not_found');
select throws_ok(format($$ select public.attach_task_photo(gen_random_uuid(), %L) $$, tests.p('p1')), 'P0001', 'task_not_found',
  'an unknown task: task_not_found');
select tests.as_user('carol');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('p1')), '42501', 'forbidden',
  'a member without « change status » rights: forbidden');
select throws_ok(format($$ select public.attach_task_photo(%L, 'n''importe quoi') $$, tests.id('T')), '42501', 'forbidden',
  'forbidden comes before invalid_photo');
select tests.as_user('bob');
select throws_ok(format($$ select public.attach_task_photo(%L, null) $$, tests.id('T')), 'P0001', 'invalid_photo', 'a NULL path');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('pu')), 'P0001', 'invalid_photo',
  'an object of another task''s folder');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('pupper')), 'P0001', 'invalid_photo',
  'uppercase ids in the path');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('pbad')), 'P0001', 'invalid_photo',
  'a file name that is not <uuid>.<ext>');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('pfile')), 'P0001', 'invalid_photo',
  'an uppercase file name');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('pgif')), 'P0001', 'invalid_photo',
  'an extension outside jpg, jpeg, png, heic');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('pnest')), 'P0001', 'invalid_photo',
  'a nested folder');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('pmissing')), 'P0001', 'invalid_photo',
  'no such object in the bucket');
select tests.as_postgres();

select tests.rewind();
select tests.mark('attach');
select tests.attach('P1', 'bob', 'T', tests.p('p1'));
select results_eq(
  $$ select task_id, group_id, path, uploaded_by, created_at from public.task_photos where id = tests.id('P1') $$,
  $$ values (tests.id('T'), tests.id('G'), tests.p('p1'), tests.id('bob'), now()) $$,
  'an assignee attaches a photo');
select results_eq(
  $$ select kind, actor_id, subject_id, task_id, task_title, item_title from public.group_activity where id > tests.since('attach') $$,
  $$ values ('photo_added', tests.id('bob'), null::uuid, tests.id('T'), 'Salle de bain', null::text) $$,
  'a photo_added event: actor = caller, task_title snapshot');
select is(tests.events_for('G'), 1, 'attaching bumps the group');
select tests.as_user('bob');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('p1')), 'P0001', 'invalid_photo',
  'a path already attached: invalid_photo');
select tests.as_postgres();
select tests.attach('P2', 'creator', 'T', tests.p('p2'));
select tests.attach('P3', 'admin', 'T', tests.p('p3'));
select tests.attach('P4', 'bob', 'T', tests.p('p4'));
select tests.attach('P5', 'bob', 'T', tests.p('p5'));
select is((select string_agg(tests.name(uploaded_by) || ':' || split_part(path, '.', 2), ',' order by path) from public.task_photos
           where task_id = tests.id('T')), 'bob:jpg,creator:png,admin:heic,bob:jpeg,bob:jpg',
  'the creator and an admin attach too; png, heic and jpeg are accepted');
select tests.as_user('bob');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('p6')), 'P0001', 'photo_limit',
  'a 6th photo: photo_limit');
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('pmissing')), 'P0001', 'invalid_photo',
  'invalid_photo comes before photo_limit');
select tests.as_anon();
select throws_ok(format($$ select public.attach_task_photo(%L, %L) $$, tests.id('T'), tests.p('p6')),
  '42501', 'permission denied for function attach_task_photo', 'anon cannot attach');
select tests.as_postgres();
select throws_ok(format($$ insert into public.task_photos (task_id, group_id, path) values (%L, %L, 'x/y.jpg') $$, tests.id('T'), tests.id('G')),
  '23514', null, 'check constraint: the path starts with <group_id>/<task_id>/');

-- delete_task_photo: the uploader or an admin ---------------------------------------------------------------------------------------------
select tests.as_user('outsider');
select throws_ok(format($$ select public.delete_task_photo(%L) $$, tests.id('P1')), 'P0001', 'photo_not_found', 'a non-member: photo_not_found');
select throws_ok($$ select public.delete_task_photo(gen_random_uuid()) $$, 'P0001', 'photo_not_found', 'an unknown photo');
select tests.as_user('carol');
select throws_ok(format($$ select public.delete_task_photo(%L) $$, tests.id('P1')), '42501', 'forbidden', 'another member: forbidden');
select tests.as_user('creator');
select throws_ok(format($$ select public.delete_task_photo(%L) $$, tests.id('P3')), '42501', 'forbidden',
  'the task''s creator cannot delete an admin''s photo');
select tests.as_postgres();
select tests.rewind();
select tests.as_user('bob');
select lives_ok(format($$ select public.delete_task_photo(%L) $$, tests.id('P1')), 'the uploader deletes their photo');
select tests.as_user('admin');
select lives_ok(format($$ select public.delete_task_photo(%L) $$, tests.id('P2')), 'an admin deletes someone else''s photo');
select tests.as_postgres();
select is((select count(*)::int from public.task_photos where task_id = tests.id('T')), 3, 'two rows deleted');
select is(tests.events_for('G'), 1, 'a deletion bumps the group');
select is((select count(*)::int from storage.objects where name in (tests.p('p1'), tests.p('p2'))), 2,
  'the objects stay: the client deletes them');
select tests.attach('P6', 'bob', 'T', tests.p('p6'));
select is((select count(*)::int from public.task_photos where task_id = tests.id('T')), 4, 'below the limit again');

-- Deleting objects (storage policy): while a member, the owner or an admin of the group ------------------------------------------------------
select set_config('storage.allow_delete_query', 'true', true);
select tests.as_user('carol');
select is(tests.affected(format($$ delete from storage.objects where bucket_id = 'task-photos' and name = %L $$, tests.p('p1'))), 0,
  'a member cannot delete someone else''s object');
select is(tests.affected(format($$ delete from storage.objects where bucket_id = 'task-photos' and name = %L $$, tests.p('f1'))), 1,
  'the owner deletes their object');
select tests.as_user('admin');
select is(tests.affected(format($$ delete from storage.objects where bucket_id = 'task-photos' and name = %L $$, tests.p('p1'))), 1,
  'an admin of the group deletes any object of the group');
select tests.as_user('outsider');
select is(tests.affected(format($$ delete from storage.objects where bucket_id = 'task-photos' and name = %L $$, tests.p('p2'))), 0,
  'a non-member deletes nothing');
select tests.as_postgres();
delete from public.group_members where group_id = tests.id('G') and user_id = tests.id('creator');
select tests.as_user('creator');
select is(tests.affected(format($$ delete from storage.objects where bucket_id = 'task-photos' and name = %L $$, tests.p('p2'))), 0,
  'an owner who left the group deletes nothing');
select tests.as_postgres();

-- RLS and privileges ----------------------------------------------------------------------------------------------------------------------
select tests.as_user('carol');
select is((select count(*)::int from public.task_photos where task_id = tests.id('T')), 4,
  'members read the photos (task reads embed photos:task_photos(id,path,uploaded_by,created_at))');
select throws_ok(format($$ insert into public.task_photos (task_id, group_id, path) values (%L, %L, %L) $$, tests.id('T'), tests.id('G'), tests.p('pu')),
  '42501', 'permission denied for table task_photos', 'no direct INSERT');
select throws_ok($$ update public.task_photos set uploaded_by = null $$, '42501', 'permission denied for table task_photos', 'no direct UPDATE');
select throws_ok($$ delete from public.task_photos $$, '42501', 'permission denied for table task_photos', 'no direct DELETE');
select tests.as_user('outsider');
select is((select count(*)::int from public.task_photos), 0, 'a non-member reads nothing');
select tests.as_anon();
select throws_ok($$ select count(*) from public.task_photos $$, '42501', 'permission denied for table task_photos', 'anon cannot read');
select tests.as_postgres();

-- Cascades ---------------------------------------------------------------------------------------------------------------------------------
delete from auth.users where id = tests.id('bob');
select is((select count(*)::int from public.task_photos where task_id = tests.id('T') and uploaded_by is null), 3,
  'a deleted uploader: uploaded_by NULL, the photos stay');
delete from public.tasks where id = tests.id('T');
select is((select count(*)::int from public.task_photos where task_id = tests.id('T')), 0, 'deleting the task deletes its photo rows');
select ok((select count(*) from storage.objects where name like tests.id('G')::text || '/' || tests.id('T')::text || '/%') > 0,
  'its objects are left behind (orphans, cleaned up later)');

select * from finish();
rollback;
