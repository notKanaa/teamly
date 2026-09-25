-- v2 refinements (docs/CONTRACTS-V2.md §0, §2, §5, §6, §7, §11): (A) a turn holder who stops being a member hands the
-- turn over at once; (B) a display name or avatar change bumps the user's groups; (C) a v1 update_task that clears the
-- due date of a recurring task makes it a plain task.
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
create function tests.task(p_name text) returns public.tasks language sql security definer as $$
  select * from public.tasks where id = tests.id(p_name)
$$;
create function tests.assignees(p_task text) returns text language sql security definer as $$
  select coalesce(string_agg(tests.name(ta.user_id) || '<' || tests.name(ta.assigned_by) || '>', ',' order by tests.name(ta.user_id)), '')
  from public.task_assignees ta where ta.task_id = tests.id(p_task)
$$;
create function tests.rotation(p_task text) returns text language sql security definer as $$
  select coalesce((select string_agg(tests.name(r.id), ',' order by r.ord)
                   from unnest((tests.task(p_task)).rotation) with ordinality as r (id, ord)), 'null')
         || ' turn=' || tests.name((tests.task(p_task)).turn_user_id)
$$;
-- A weekly rotating task of p_group (trusted fixture): p_turn's turn, assigned by the creator.
create function tests.rotating_task(p_name text, p_group text, p_creator text, p_rotation text[], p_turn text,
                                    p_status public.task_status default 'todo') returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into public.tasks (group_id, title, created_by, status, due_at, repeat_freq, repeat_tz, rotation, turn_user_id)
  values (tests.id(p_group), p_name, tests.id(p_creator), p_status, '2041-03-04 07:00+00', 'weekly', 'Europe/Paris',
          array(select tests.id(r) from unnest(p_rotation) with ordinality as x (r, o) order by o), tests.id(p_turn))
  returning id into v_id;
  insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
  values (v_id, tests.id(p_group), tests.id(p_turn), tests.id(p_creator));
  insert into tests.ids values (p_name, v_id);
  return v_id;
end $$;
-- Events of a group written after the mark p_mark: "kind actor subject" (ids as names), oldest first.
create function tests.feed(p_group text, p_mark text) returns text language sql security definer as $$
  select coalesce(string_agg(a.kind || ' ' || tests.name(a.actor_id) || ' ' || tests.name(a.subject_id), ' | ' order by a.id), '')
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

select tests.create_user(u) from unnest(array['adminA', 'a1', 'a2', 'a3', 'adminB', 'b1', 'b2', 'b3', 'b4', 'adminC', 'c1', 'c2',
  'adminD', 'd1', 'd2', 'adminE', 'e1', 'e2', 'eGone', 'adminF', 'f1', 'f2', 'f3', 'pb', 'cx', 'cy', 'cz']) as u;

-- (A) Turn handover (§6) -------------------------------------------------------------------------------------------------
select tests.create_group('GA', 'adminA');
select tests.add_member('GA', u) from unnest(array['a1', 'a2', 'a3']) as u;
select tests.rotating_task('TA', 'GA', 'adminA', array['a1', 'a2', 'a3'], 'a2');
insert into public.tasks (group_id, title, created_by) values (tests.id('GA'), 'Sans tour', tests.id('adminA'));
insert into tests.ids select 'PA', id from public.tasks where title = 'Sans tour' and group_id = tests.id('GA');
insert into public.task_assignees (task_id, group_id, user_id, assigned_by) values (tests.id('PA'), tests.id('GA'), tests.id('a2'), tests.id('adminA'));
insert into public.push_subscriptions (user_id, topic) values (tests.id('a3'), 'equipe-aaaaaaaaaaaaaaaaaaaaaaaa');
update private.settings set value = 'https://ntfy.example.test/' where key = 'ntfy_base_url';
insert into tests.results values ('queue start', to_jsonb((select coalesce(max(q.id), 0) from net.http_request_queue q)));
select tests.mark('A');

select tests.as_user('a2');
select public.leave_group(tests.id('GA'));
select tests.as_postgres();
select is(tests.rotation('TA'), 'a1,a2,a3 turn=a3', 'the turn holder leaves: the next member takes the turn (a2 stays listed)');
select is(tests.assignees('TA'), 'a3<null>', 'the new turn holder is the only assignee, assigned_by NULL');
select is(tests.feed('GA', 'A'), 'member_left a2 a2 | turn_started null a3', 'member_left, then turn_started for the new turn holder');
select is((select task_id from public.group_activity where group_id = tests.id('GA') and kind = 'turn_started'), tests.id('TA'),
  'turn_started references the pending occurrence');
select is((select count(*)::int from tests.pushes()), 1, 'one ntfy push, to the new turn holder');
select is((select body ->> 'message' from tests.pushes()), E'C’est ton tour dans « GA »',
  'the handover is pushed as a rotation turn');
select is(tests.assignees('PA'), '', 'a task without rotation: the assignment is simply gone (v1)');
select tests.as_user('a3');
select public.set_task_status(tests.id('TA'), 'done');
select tests.as_postgres();
insert into tests.ids select 'TA2', (tests.task('TA')).next_occurrence_id;
select is(tests.rotation('TA2'), 'a1,a3 turn=a1', 'the next spawn removes the departed user from the rotation');

-- Removal, wrap-around, departed members skipped; a listed member who is not the turn holder changes nothing.
select tests.create_group('GB', 'adminB');
select tests.add_member('GB', u) from unnest(array['b1', 'b2', 'b3', 'b4']) as u;
select tests.rotating_task('TB', 'GB', 'adminB', array['b1', 'b2', 'b3', 'b4'], 'b4');
select tests.as_user('b1');
select public.leave_group(tests.id('GB'));
select tests.as_postgres();
select is(tests.rotation('TB') || ' ' || tests.assignees('TB'), 'b1,b2,b3,b4 turn=b4 b4<adminB>',
  'a listed member who is not the turn holder leaves: nothing changes');
select tests.as_user('adminB');
select public.remove_member(tests.id('GB'), tests.id('b4'));
select tests.as_postgres();
select is(tests.rotation('TB') || ' ' || tests.assignees('TB'), 'b1,b2,b3,b4 turn=b2 b2<null>',
  'the turn holder is removed: the turn wraps around and skips b1, who left');

-- Fewer than 2 members of the rotation left: the rotation and the turn are dropped.
select tests.create_group('GC', 'adminC');
select tests.add_member('GC', u) from unnest(array['c1', 'c2']) as u;
select tests.rotating_task('TC', 'GC', 'adminC', array['c1', 'c2'], 'c1');
select tests.rotating_task('TCdone', 'GC', 'adminC', array['c1', 'c2'], 'c1', 'done');
select tests.mark('C');
select tests.as_user('c1');
select public.leave_group(tests.id('GC'));
select tests.as_postgres();
select results_eq(
  $$ select rotation, turn_user_id, repeat_freq, series_id = id from public.tasks where id = tests.id('TC') $$,
  $$ values (null::uuid[], null::uuid, 'weekly', true) $$,
  'one member left: the rotation and the turn are dropped, the task still repeats');
select is(tests.assignees('TC'), 'c2<null>', 'the remaining member becomes the assignee, assigned_by NULL');
select is(tests.feed('GC', 'C'), 'member_left c1 c1', 'no turn_started without a rotation');
select is(tests.rotation('TCdone'), 'c1,c2 turn=c1', 'a done occurrence is not touched');

select tests.create_group('GD', 'adminD');
select tests.add_member('GD', u) from unnest(array['d1', 'd2']) as u;
select tests.rotating_task('TD', 'GD', 'adminD', array['d1', 'd2'], 'd1');
delete from public.group_members where group_id = tests.id('GD') and user_id = tests.id('d2');
select is(tests.rotation('TD'), 'd1,d2 turn=d1', 'd2 (not the turn holder) left: nothing changes');
delete from public.group_members where group_id = tests.id('GD') and user_id = tests.id('d1');
select is(tests.rotation('TD') || ' [' || tests.assignees('TD') || ']', 'null turn=null []',
  'no member of the rotation left: no rotation, no assignee');

-- Account deletion of the turn holder.
select tests.create_group('GE', 'adminE');
select tests.add_member('GE', u) from unnest(array['e1', 'e2', 'eGone']) as u;
select tests.rotating_task('TE', 'GE', 'adminE', array['e1', 'eGone', 'e2'], 'eGone');
select tests.mark('E');
select tests.as_user('eGone');
select lives_ok($$ select public.delete_my_account() $$, 'the turn holder deletes their account');
select tests.as_postgres();
select is(tests.rotation('TE'), 'e1,eGone,e2 turn=e2', 'the turn goes to the member after them, never to NULL');
select is(tests.assignees('TE'), 'e2<null>', 'assigned to the new turn holder, assigned_by NULL');
select is(tests.feed('GE', 'E'), 'member_left null null | turn_started null e2', 'account deletion: member_left, then turn_started');

-- The other order of the account-deletion cascade: turn_user_id already set to NULL when the membership goes.
select tests.create_group('GF', 'adminF');
select tests.add_member('GF', u) from unnest(array['f1', 'f2', 'f3']) as u;
select tests.rotating_task('TF', 'GF', 'adminF', array['f1', 'f2', 'f3'], 'f2', 'in_progress');
update public.tasks set turn_user_id = null where id = tests.id('TF');
delete from public.group_members where group_id = tests.id('GF') and user_id = tests.id('f2');
select is(tests.rotation('TF') || ' ' || tests.assignees('TF'), 'f1,f2,f3 turn=f3 f3<null>',
  'turn already NULL: the handover starts from the departed user''s position (an in_progress occurrence is pending too)');
select is((select count(*)::int from public.tasks t
           where t.status <> 'done' and t.rotation is not null
             and t.group_id in (tests.id('GA'), tests.id('GB'), tests.id('GC'), tests.id('GD'), tests.id('GE'), tests.id('GF'))
             and not exists (select 1 from public.group_members gm where gm.group_id = t.group_id and gm.user_id = t.turn_user_id)),
  0, 'every pending rotating occurrence has a member as turn holder');

-- A group deletion with rotating tasks: nothing to hand over.
select tests.as_user('adminB');
select lives_ok(format($$ select public.delete_group(%L) $$, tests.id('GB')), 'delete_group with a rotating task');
select tests.as_postgres();
update private.settings set value = null where key = 'ntfy_base_url';

-- (B) A display name or avatar change bumps the user's groups (§2) -----------------------------------------------------------
select tests.create_group('GP1', 'pb');
select tests.create_group('GP2', 'adminA');
select tests.add_member('GP2', 'pb');
select tests.create_group('GP3', 'adminA');
update public.profiles set memberships_changed_at = '2000-01-01', onboarded_at = null where id = tests.id('pb');
select tests.rewind();
select tests.as_user('pb');
update public.profiles set display_name = 'Pierre B.' where id = auth.uid();
select tests.as_postgres();
select results_eq(
  $$ select tests.events_for('GP1'), tests.events_for('GP2'), tests.events_for('GP3') $$,
  $$ values (1, 1, 0) $$,
  'a display name change bumps every group of the user (one groups UPDATE each), no other group');
select is((select last_activity_at from public.groups where id = tests.id('GP2')), now(), 'last_activity_at = now()');
select is((select memberships_changed_at from public.profiles where id = tests.id('pb')), '2000-01-01'::timestamptz,
  'memberships_changed_at is not touched (v1 rule)');
select tests.as_user('pb');
update public.profiles set display_name = 'Pierre Bis' where id = auth.uid();
select tests.as_postgres();
select results_eq(
  $$ select tests.events_for('GP1'), tests.events_for('GP2') $$,
  $$ values (1, 1) $$,
  'a second change in the same transaction: still one bump per group');
select tests.rewind();
select tests.as_user('pb');
update public.profiles set avatar_color = 'amber' where id = auth.uid();
select tests.as_postgres();
select is(tests.events_for('GP1') + tests.events_for('GP2'), 2, 'an avatar color change bumps the groups');
select tests.rewind();
select tests.as_user('pb');
update public.profiles set avatar_emoji = '🦉' where id = auth.uid();
select tests.as_postgres();
select is(tests.events_for('GP1') + tests.events_for('GP2'), 2, 'an avatar emoji change bumps the groups');
select tests.rewind();
select tests.as_user('pb');
update public.profiles set display_name = 'Pierre Bis', avatar_color = 'amber', avatar_emoji = '🦉' where id = auth.uid();
select public.complete_onboarding();
select tests.as_postgres();
select is(tests.events_for('GP1') + tests.events_for('GP2'), 0, 'identical values and onboarded_at bump nothing');

-- (C) A v1 update_task that clears the due date of a recurring task (§0, §5) ---------------------------------------------------
select tests.create_group('GX', 'cx');
select tests.add_member('GX', u) from unnest(array['cy', 'cz']) as u;
select tests.as_user('cx');
insert into tests.ids select 'TX', id from public.create_task(tests.id('GX'), 'Rotation', null, 'high', '2041-03-04 07:00+00', '{}',
  '{"freq": "weekly", "weekdays": [1, 4], "tz": "Europe/Paris"}', array[tests.id('cy'), tests.id('cz')], array['Un', 'Deux']);
select tests.as_postgres();
update public.tasks set updated_at = '2000-01-01' where id = tests.id('TX');
select tests.as_user('cx');
select public.update_task(tests.id('TX'), 'Rotation (v1)', null, 'high', null, array[tests.id('cy')]);
select results_eq(
  $$ select title, due_at, repeat_freq, repeat_interval, repeat_weekdays, repeat_tz, repeat_month_day, series_id, rotation,
            turn_user_id, updated_at
     from public.tasks where id = tests.id('TX') $$,
  $$ values ('Rotation (v1)', null::timestamptz, null::text, 1::smallint, null::smallint[], null::text, null::smallint, null::uuid,
             null::uuid[], null::uuid, now()) $$,
  'a v1 edit clearing the due date: the task becomes a plain task (rule, rotation and turn cleared)');
select is(tests.assignees('TX'), 'cy<cx>', 'its assignees are kept (the former turn holder, same row)');
select is((select string_agg(title, ',' order by position) from public.task_checklist_items where task_id = tests.id('TX')), 'Un,Deux',
  'its checklist is kept');
select public.set_task_status(tests.id('TX'), 'done');
select is((tests.task('TX')).next_occurrence_id, null, 'completing the plain task spawns nothing');

insert into tests.ids select 'TY', id from public.create_task(tests.id('GX'), 'Quotidienne', null, 'low', '2041-03-04 07:00+00',
  array[tests.id('cy')], '{"freq": "daily", "tz": "UTC"}');
select public.set_task_status(tests.id('TY'), 'done');
insert into tests.ids select 'TY2', (tests.task('TY')).next_occurrence_id;
select public.update_task(tests.id('TY'), 'Quotidienne', null, 'low', null, array[tests.id('cz')]);
select results_eq(
  $$ select status::text, repeat_freq, next_occurrence_id from public.tasks where id = tests.id('TY') $$,
  $$ values ('done', null::text, tests.id('TY2')) $$,
  'a done occurrence too; next_occurrence_id is kept');
select is(tests.assignees('TY'), 'cz<cx>', 'p_assignee_ids then applies as for any plain task');
select is((tests.task('TY2')).repeat_freq, 'daily', 'the pending occurrence of the series is not affected');

insert into tests.ids select 'TZ', id from public.create_task(tests.id('GX'), 'Explicite', null, 'low', '2041-03-04 07:00+00', '{}',
  '{"freq": "weekly", "tz": "UTC"}', array[tests.id('cy'), tests.id('cz')]);
select throws_ok(format($$ select public.update_task(%L, 'Explicite', null, 'low', null, null, '{"freq": "weekly", "tz": "UTC"}') $$,
    tests.id('TZ')),
  'P0001', 'recurrence_requires_due_date', 'an explicit rule with a NULL due date is still refused (v2 client)');
select throws_ok(format($$ select public.update_task(%L, 'Explicite', null, 'low', null, null, null, array[%L, %L]::uuid[]) $$,
    tests.id('TZ'), tests.id('cz'), tests.id('cy')),
  'P0001', 'invalid_rotation', 'a new rotation with the rule cleared by the NULL due date: invalid_rotation');
select throws_ok(format($$ update public.tasks set due_at = null where id = %L $$, tests.id('TZ')),
  'P0001', 'recurrence_requires_due_date', 'a direct PATCH of the due date is still refused');
select lives_ok(format($$ select public.update_task(%L, 'Explicite', null, 'low', null, null, 'null'::jsonb, array[%L, %L]::uuid[]) $$,
    tests.id('TZ'), tests.id('cy'), tests.id('cz')),
  'a JSON null rule with the stored rotation sent back and a NULL due date');
select is(tests.rotation('TZ') || ' ' || coalesce((tests.task('TZ')).repeat_freq, 'plain') || ' ' || tests.assignees('TZ'),
  'null turn=null plain cy<cx>', 'the task becomes a plain task, the former turn holder stays assigned');
insert into tests.ids select 'TW', id from public.create_task(tests.id('GX'), 'Vide', null, 'low', '2041-03-04 07:00+00', '{}',
  '{"freq": "weekly", "tz": "UTC"}', array[tests.id('cy'), tests.id('cz')]);
select lives_ok(format($$ select public.update_task(%L, 'Vide', null, 'low', null, null, null, '{}') $$, tests.id('TW')),
  'no rotation sent with a NULL due date');
select is(coalesce((tests.task('TW')).repeat_freq, 'plain'), 'plain', 'a plain task');
select tests.as_postgres();

select * from finish();
rollback;
