-- Teamly v3 — RPCs (docs/CONTRACTS-V3.md §1–§6), the group signal of the new tables and the ntfy pushes of nudges and
-- mentions. Every RPC is security definer with an empty search_path and is granted to `authenticated` only.
-- Business errors: P0001 with the error code as message. Permission errors: 42501 `forbidden`. `*_not_found` = the row
-- does not exist or is not visible to the caller (not a member of its group).

-- Relancer (§1) ------------------------------------------------------------------------------------------------------------
-- Any member of the task's group. Order: task_not_found → task_done → nudge_no_recipient → nudge_rate_limited.
-- Recipients: the current assignees except the caller. Rate limit: one nudge per (task, caller) in the last 20 hours, window
-- inclusive (a nudge exactly 20 hours old still counts). Writes one task_nudges row and one task_nudged event per
-- recipient (in user id order); the rows bump the group and queue the pushes (triggers below). Returns the number of people
-- nudged.
create function public.nudge_task(p_task_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_task public.tasks;
  v_recipients uuid[];
  v_recipient uuid;
begin
  select * into v_task from public.tasks t where t.id = p_task_id;
  if not found or not private.is_group_member(v_task.group_id) then
    raise exception using errcode = 'P0001', message = 'task_not_found';
  end if;
  if v_task.status = 'done' then
    raise exception using errcode = 'P0001', message = 'task_done';
  end if;

  -- Serializes the nudges of one caller on one task, so that concurrent calls cannot bypass the rate limit.
  perform pg_advisory_xact_lock(hashtextextended('nudge_task:' || p_task_id::text || ':' || v_uid::text, 0));

  select coalesce(array_agg(ta.user_id order by ta.user_id), '{}')
  into v_recipients
  from public.task_assignees ta
  where ta.task_id = p_task_id
    and ta.user_id <> v_uid;
  if cardinality(v_recipients) = 0 then
    raise exception using errcode = 'P0001', message = 'nudge_no_recipient';
  end if;

  if exists (
    select 1
    from public.task_nudges n
    where n.task_id = p_task_id
      and n.from_user = v_uid
      and n.created_at >= now() - interval '20 hours'
  ) then
    raise exception using errcode = 'P0001', message = 'nudge_rate_limited';
  end if;

  foreach v_recipient in array v_recipients loop
    insert into public.task_nudges (task_id, group_id, from_user, to_user)
    values (p_task_id, v_task.group_id, v_uid, v_recipient);
    perform private.log_activity(v_task.group_id, 'task_nudged', v_uid, v_recipient, p_task_id, v_task.title, null);
  end loop;

  return cardinality(v_recipients);
end;
$$;

-- Mode absent (§2) ---------------------------------------------------------------------------------------------------------
-- set_away: p_from <= p_until, p_until >= today − 1 and at most 366 days, both ends included (p_until − p_from <= 365), else
-- invalid_away (NULL dates too). « today » is the UTC date ((now() at time zone 'UTC')::date): the result does not depend on
-- the session time zone. A NULL p_announce counts as true (the default).
-- Writes, in this order: the profile (away_from, away_until; the profile UPDATE and the bump of the user's groups are the
-- signals), a member_away event per group of the caller when announcing (actor = subject = caller, starts_on, ends_on), then
-- the handover of every pending occurrence of a rotating task where the caller holds the turn and whose local due date
-- falls in the range: the next member after the caller who is not away that day (the next member when everyone is away)
-- becomes the turn holder and the only assignee with assigned_by NULL, and a turn_started event is written. An occurrence
-- whose rotation lists no other member keeps its turn.
create function public.set_away(p_from date, p_until date, p_announce boolean default true)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_today date := (now() at time zone 'UTC')::date;
  v_group_id uuid;
  v_task record;
  v_members uuid[];
  v_turn uuid;
  v_profile public.profiles;
begin
  if p_from is null
     or p_until is null
     or p_from > p_until
     or p_until < v_today - 1
     or p_until - p_from > 365 then
    raise exception using errcode = 'P0001', message = 'invalid_away';
  end if;

  update public.profiles p
  set away_from = p_from,
      away_until = p_until
  where p.id = v_uid;

  if coalesce(p_announce, true) then
    for v_group_id in
      select gm.group_id from public.group_members gm where gm.user_id = v_uid order by gm.group_id
    loop
      perform private.write_activity(v_group_id, 'member_away', v_uid, v_uid, null, null, null, p_from, p_until);
    end loop;
  end if;

  for v_task in
    select t.id, t.group_id, t.title, t.rotation, (t.due_at at time zone t.repeat_tz)::date as day
    from public.tasks t
    where t.turn_user_id = v_uid
      and t.status <> 'done'
      and t.rotation is not null
      and (t.due_at at time zone t.repeat_tz)::date between p_from and p_until
    order by t.due_at, t.id
    for update
  loop
    -- Members of the group still listed, in rotation order.
    select coalesce(array_agg(r.user_id order by r.ord), '{}')
    into v_members
    from unnest(v_task.rotation) with ordinality as r (user_id, ord)
    where exists (
      select 1
      from public.group_members gm
      where gm.group_id = v_task.group_id
        and gm.user_id = r.user_id
    );

    -- The caller is away that day, so skipped; they come last in the cyclic order.
    v_turn := private.pick_turn(v_task.rotation, v_members, v_uid, v_task.day);
    continue when v_turn is null or v_turn = v_uid;

    update public.tasks t set turn_user_id = v_turn where t.id = v_task.id;

    delete from public.task_assignees ta
    where ta.task_id = v_task.id
      and ta.user_id <> v_turn;
    insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
    values (v_task.id, v_task.group_id, v_turn, null)
    on conflict (task_id, user_id) do nothing;

    perform private.log_activity(v_task.group_id, 'turn_started', null, v_turn, v_task.id, v_task.title, null);
  end loop;

  select * into v_profile from public.profiles p where p.id = v_uid;
  return v_profile;
end;
$$;

-- clear_away: both columns NULL. No event, no turn moved back; no write (no signal) when the caller is not away.
create function public.clear_away()
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_profile public.profiles;
begin
  update public.profiles p
  set away_from = null,
      away_until = null
  where p.id = v_uid
    and (p.away_from is not null or p.away_until is not null);

  select * into v_profile from public.profiles p where p.id = v_uid;
  return v_profile;
end;
$$;

-- Échanger mon tour (§3) -----------------------------------------------------------------------------------------------------
-- Lock order everywhere: the occurrence (tasks row), then the swap, as in the triggers that cancel pending swaps.

-- The caller holds the turn of a pending rotating occurrence and offers it to another member listed in the rotation.
-- Order: task_not_found → not_your_turn → invalid_rotation (NULL, the caller, not listed, or no longer a member) →
-- swap_pending.
create function public.request_turn_swap(p_task_id uuid, p_to_user uuid)
returns public.turn_swaps
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_task public.tasks;
  v_swap public.turn_swaps;
begin
  select * into v_task from public.tasks t where t.id = p_task_id;
  if not found or not private.is_group_member(v_task.group_id) then
    raise exception using errcode = 'P0001', message = 'task_not_found';
  end if;

  select * into v_task from public.tasks t where t.id = p_task_id for update;

  if v_task.status = 'done' or v_task.rotation is null or v_task.turn_user_id is distinct from v_uid then
    raise exception using errcode = 'P0001', message = 'not_your_turn';
  end if;
  if p_to_user is null
     or p_to_user = v_uid
     or not (p_to_user = any (v_task.rotation))
     or not exists (
       select 1
       from public.group_members gm
       where gm.group_id = v_task.group_id
         and gm.user_id = p_to_user
     ) then
    raise exception using errcode = 'P0001', message = 'invalid_rotation';
  end if;
  if exists (select 1 from public.turn_swaps s where s.task_id = p_task_id and s.status = 'pending') then
    raise exception using errcode = 'P0001', message = 'swap_pending';
  end if;

  insert into public.turn_swaps (task_id, group_id, series_id, from_user, to_user)
  values (p_task_id, v_task.group_id, v_task.series_id, v_uid, p_to_user)
  returning * into v_swap;

  return v_swap;
end;
$$;

-- Only to_user. Order: swap_not_found → forbidden → invalid_input (NULL p_accept, 23502) → swap_not_pending.
-- Decline: `declined`. Accept: `accepted`, then the occurrence's turn and its only assignee become to_user (assigned_by =
-- to_user: no notification), a turn_swapped event (actor = to_user, subject = from_user). responded_at = now() in both
-- cases. Both bump the group (turn_swaps trigger).
create function public.respond_turn_swap(p_swap_id uuid, p_accept boolean)
returns public.turn_swaps
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_swap public.turn_swaps;
  v_task public.tasks;
begin
  select * into v_swap from public.turn_swaps s where s.id = p_swap_id;
  if not found or not private.is_group_member(v_swap.group_id) then
    raise exception using errcode = 'P0001', message = 'swap_not_found';
  end if;
  if v_swap.to_user <> v_uid then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;
  if p_accept is null then
    raise exception using errcode = '23502', message = 'invalid_input';
  end if;

  select * into v_task from public.tasks t where t.id = v_swap.task_id for update;
  select * into v_swap from public.turn_swaps s where s.id = p_swap_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'swap_not_found';
  end if;
  if v_swap.status <> 'pending' then
    raise exception using errcode = 'P0001', message = 'swap_not_pending';
  end if;

  if not p_accept then
    update public.turn_swaps s
    set status = 'declined',
        responded_at = now()
    where s.id = p_swap_id
    returning * into v_swap;
    return v_swap;
  end if;

  -- A pending swap is still valid (the triggers cancel it otherwise); checked again, defensively.
  if v_task.status = 'done'
     or v_task.rotation is null
     or v_task.turn_user_id is distinct from v_swap.from_user
     or not (v_swap.to_user = any (v_task.rotation)) then
    raise exception using errcode = 'P0001', message = 'swap_not_pending';
  end if;

  -- Accepted first, so that moving the turn below does not cancel it.
  update public.turn_swaps s
  set status = 'accepted',
      responded_at = now()
  where s.id = p_swap_id
  returning * into v_swap;

  update public.tasks t set turn_user_id = v_swap.to_user where t.id = v_swap.task_id;

  delete from public.task_assignees ta
  where ta.task_id = v_swap.task_id
    and ta.user_id <> v_swap.to_user;
  insert into public.task_assignees (task_id, group_id, user_id, assigned_by)
  values (v_swap.task_id, v_swap.group_id, v_swap.to_user, v_swap.to_user)
  on conflict (task_id, user_id) do nothing;

  perform private.log_activity(
    v_swap.group_id, 'turn_swapped', v_swap.to_user, v_swap.from_user, v_swap.task_id, v_task.title, null
  );

  return v_swap;
end;
$$;

-- Only from_user, while pending. Order: swap_not_found → forbidden → swap_not_pending.
create function public.cancel_turn_swap(p_swap_id uuid)
returns public.turn_swaps
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_swap public.turn_swaps;
begin
  select * into v_swap from public.turn_swaps s where s.id = p_swap_id;
  if not found or not private.is_group_member(v_swap.group_id) then
    raise exception using errcode = 'P0001', message = 'swap_not_found';
  end if;
  if v_swap.from_user <> v_uid then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  perform 1 from public.tasks t where t.id = v_swap.task_id for update;
  select * into v_swap from public.turn_swaps s where s.id = p_swap_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'swap_not_found';
  end if;
  if v_swap.status <> 'pending' then
    raise exception using errcode = 'P0001', message = 'swap_not_pending';
  end if;

  update public.turn_swaps s
  set status = 'cancelled',
      responded_at = now()
  where s.id = p_swap_id
  returning * into v_swap;

  return v_swap;
end;
$$;

-- Bravo (§4) -----------------------------------------------------------------------------------------------------------------
-- Order: activity_not_found (missing, or the caller is not a member of the event's group) → invalid_reaction (NULL or not
-- one of the five emojis, compared exactly). Returns true when the reaction was added (target_user = the event's actor),
-- false when it was removed. Both bump the group (trigger).
create function public.toggle_reaction(p_activity_id bigint, p_emoji text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_activity public.group_activity;
begin
  select * into v_activity from public.group_activity a where a.id = p_activity_id;
  if not found or not private.is_group_member(v_activity.group_id) then
    raise exception using errcode = 'P0001', message = 'activity_not_found';
  end if;
  if p_emoji is null
     or p_emoji not in (U&'\+01F44F', U&'\+01F525', U&'\+01F4AA', U&'\2764\FE0F', U&'\+01F602') then
    raise exception using errcode = 'P0001', message = 'invalid_reaction';
  end if;

  delete from public.activity_reactions r
  where r.activity_id = p_activity_id
    and r.user_id = v_uid
    and r.emoji = p_emoji;
  if found then
    return false;
  end if;

  insert into public.activity_reactions (activity_id, group_id, user_id, target_user, emoji)
  values (p_activity_id, v_activity.group_id, v_uid, v_activity.actor_id, p_emoji)
  on conflict (activity_id, user_id, emoji) do nothing;
  return true;
end;
$$;

-- Commentaires (§5) -------------------------------------------------------------------------------------------------------------
-- Any member. Order: task_not_found → invalid_comment (the body trimmed with private.clean_text, 1–1000 code points) →
-- invalid_mentions. p_mentions: NULL = none; a NULL element, a multi-dimensional array, more than 20 distinct ids or a
-- non-member is refused; duplicates are dropped (first occurrence kept, order kept); mentioning yourself is allowed (no
-- push). Writes a comment_added event (actor = author, task_title, item_title = the first 80 code points of the stored
-- body); the row bumps the group and pushes the mentioned users (triggers below).
create function public.add_task_comment(p_task_id uuid, p_body text, p_mentions uuid[] default '{}')
returns public.task_comments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_task public.tasks;
  v_body text := private.clean_text(p_body);
  v_mentions uuid[];
  v_comment public.task_comments;
begin
  select * into v_task from public.tasks t where t.id = p_task_id;
  if not found or not private.is_group_member(v_task.group_id) then
    raise exception using errcode = 'P0001', message = 'task_not_found';
  end if;
  if v_body is null or char_length(v_body) not between 1 and 1000 then
    raise exception using errcode = 'P0001', message = 'invalid_comment';
  end if;

  -- Dimensions first: array_position raises on a multi-dimensional array.
  if coalesce(array_ndims(p_mentions), 1) <> 1 then
    raise exception using errcode = 'P0001', message = 'invalid_mentions';
  end if;
  if array_position(p_mentions, null) is not null then
    raise exception using errcode = 'P0001', message = 'invalid_mentions';
  end if;
  select coalesce(array_agg(m.id order by m.ord), '{}')
  into v_mentions
  from (
    select u.id, min(u.ord) as ord
    from unnest(coalesce(p_mentions, '{}'::uuid[])) with ordinality as u (id, ord)
    group by u.id
  ) m;
  if cardinality(v_mentions) > 20
     or exists (
       select 1
       from unnest(v_mentions) as u (id)
       where not exists (
         select 1
         from public.group_members gm
         where gm.group_id = v_task.group_id
           and gm.user_id = u.id
       )
     ) then
    raise exception using errcode = 'P0001', message = 'invalid_mentions';
  end if;

  insert into public.task_comments (task_id, group_id, author_id, body, mentions)
  values (p_task_id, v_task.group_id, v_uid, v_body, v_mentions)
  returning * into v_comment;

  perform private.log_activity(v_task.group_id, 'comment_added', v_uid, null, p_task_id, v_task.title, left(v_body, 80));

  return v_comment;
end;
$$;

-- The author or an admin of the group. Order: comment_not_found → forbidden. The comment_added event stays (snapshot).
create function public.delete_task_comment(p_comment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_comment public.task_comments;
begin
  select * into v_comment from public.task_comments c where c.id = p_comment_id;
  if not found or not private.is_group_member(v_comment.group_id) then
    raise exception using errcode = 'P0001', message = 'comment_not_found';
  end if;
  if not (v_comment.author_id is not distinct from v_uid or private.is_group_admin(v_comment.group_id)) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  delete from public.task_comments c where c.id = p_comment_id;
end;
$$;

-- Photo preuve (§6) ----------------------------------------------------------------------------------------------------------------
-- Rights of « change status » (admin, creator still member, assignee). Order: task_not_found → forbidden → invalid_photo →
-- photo_limit.
-- invalid_photo: p_path is not exactly `<group_id>/<task_id>/<file>` with the task's lowercase ids and a file name made of a
-- lowercase UUID and the extension jpg, jpeg, png or heic; or no object of that name exists in the bucket `task-photos`; or
-- the path is already attached. photo_limit: the task already has 5 photos. Writes a photo_added event (actor = caller,
-- task_title); the row bumps the group (trigger).
create function public.attach_task_photo(p_task_id uuid, p_path text)
returns public.task_photos
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_task public.tasks;
  v_prefix text;
  v_photo public.task_photos;
begin
  select * into v_task from public.tasks t where t.id = p_task_id;
  if not found or not private.is_group_member(v_task.group_id) then
    raise exception using errcode = 'P0001', message = 'task_not_found';
  end if;
  if not private.can_change_task_status(v_task.id, v_task.group_id, v_task.created_by) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  v_prefix := v_task.group_id::text || '/' || v_task.id::text || '/';
  if p_path is null
     or not starts_with(p_path, v_prefix)
     or substr(p_path, char_length(v_prefix) + 1)
        !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|heic)$'
     or not exists (select 1 from storage.objects o where o.bucket_id = 'task-photos' and o.name = p_path)
     or exists (select 1 from public.task_photos tp where tp.path = p_path) then
    raise exception using errcode = 'P0001', message = 'invalid_photo';
  end if;

  -- Serializes the attachments of this task (the limit).
  perform 1 from public.tasks t where t.id = p_task_id for update;

  if (select count(*) from public.task_photos tp where tp.task_id = p_task_id) >= 5 then
    raise exception using errcode = 'P0001', message = 'photo_limit';
  end if;

  begin
    insert into public.task_photos (task_id, group_id, path, uploaded_by)
    values (p_task_id, v_task.group_id, p_path, v_uid)
    returning * into v_photo;
  exception when unique_violation then
    -- The same path attached concurrently.
    raise exception using errcode = 'P0001', message = 'invalid_photo';
  end;

  perform private.log_activity(v_task.group_id, 'photo_added', v_uid, null, p_task_id, v_task.title, null);

  return v_photo;
end;
$$;

-- The uploader or an admin of the group. Order: photo_not_found → forbidden. Deletes the row only: the client then deletes
-- the object (storage policy: its owner or an admin of the group).
create function public.delete_task_photo(p_photo_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_photo public.task_photos;
begin
  select * into v_photo from public.task_photos tp where tp.id = p_photo_id;
  if not found or not private.is_group_member(v_photo.group_id) then
    raise exception using errcode = 'P0001', message = 'photo_not_found';
  end if;
  if not (v_photo.uploaded_by is not distinct from v_uid or private.is_group_admin(v_photo.group_id)) then
    raise exception using errcode = '42501', message = 'forbidden';
  end if;

  delete from public.task_photos tp where tp.id = p_photo_id;
end;
$$;

-- Signals ---------------------------------------------------------------------------------------------------------------------------
-- Every write of the new tables bumps its group, like task and checklist writes (at most once per group per transaction):
-- members reload through the existing groups UPDATE signal.

create trigger task_nudges_after_change_signal
  after insert or update or delete on public.task_nudges
  for each row execute function private.on_group_content_change();

create trigger turn_swaps_after_change_signal
  after insert or update or delete on public.turn_swaps
  for each row execute function private.on_group_content_change();

create trigger activity_reactions_after_change_signal
  after insert or update or delete on public.activity_reactions
  for each row execute function private.on_group_content_change();

create trigger task_comments_after_change_signal
  after insert or update or delete on public.task_comments
  for each row execute function private.on_group_content_change();

create trigger task_photos_after_change_signal
  after insert or update or delete on public.task_photos
  for each row execute function private.on_group_content_change();

-- ntfy pushes (§1, §5) ----------------------------------------------------------------------------------------------------------------

-- « <prénom> te relance dans « <groupe> » » to the nudged user.
create function private.task_nudges_after_insert_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.queue_push(
    new.to_user, new.task_id, new.group_id, 'nudge', private.push_message('nudge', new.from_user, new.group_id)
  );
  return null;
end;
$$;

create trigger task_nudges_after_insert_push
  after insert on public.task_nudges
  for each row execute function private.task_nudges_after_insert_push();

-- « <prénom> t’a mentionné dans « <groupe> » » to every mentioned user except the author.
create function private.task_comments_after_insert_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_message text;
begin
  foreach v_user in array new.mentions loop
    continue when v_user is not distinct from new.author_id;
    v_message := coalesce(v_message, private.push_message('mention', new.author_id, new.group_id));
    perform private.queue_push(v_user, new.task_id, new.group_id, 'mention', v_message);
  end loop;
  return null;
end;
$$;

create trigger task_comments_after_insert_push
  after insert on public.task_comments
  for each row execute function private.task_comments_after_insert_push();

-- Privileges -----------------------------------------------------------------------------------------------------------------------------

revoke all on all functions in schema private from public, anon;
revoke all on function private.task_nudges_after_insert_push() from authenticated;
revoke all on function private.task_comments_after_insert_push() from authenticated;

revoke all on function public.nudge_task(uuid) from public, anon;
revoke all on function public.set_away(date, date, boolean) from public, anon;
revoke all on function public.clear_away() from public, anon;
revoke all on function public.request_turn_swap(uuid, uuid) from public, anon;
revoke all on function public.respond_turn_swap(uuid, boolean) from public, anon;
revoke all on function public.cancel_turn_swap(uuid) from public, anon;
revoke all on function public.toggle_reaction(bigint, text) from public, anon;
revoke all on function public.add_task_comment(uuid, text, uuid[]) from public, anon;
revoke all on function public.delete_task_comment(uuid) from public, anon;
revoke all on function public.attach_task_photo(uuid, text) from public, anon;
revoke all on function public.delete_task_photo(uuid) from public, anon;

grant execute on function public.nudge_task(uuid) to authenticated;
grant execute on function public.set_away(date, date, boolean) to authenticated;
grant execute on function public.clear_away() to authenticated;
grant execute on function public.request_turn_swap(uuid, uuid) to authenticated;
grant execute on function public.respond_turn_swap(uuid, boolean) to authenticated;
grant execute on function public.cancel_turn_swap(uuid) to authenticated;
grant execute on function public.toggle_reaction(bigint, text) to authenticated;
grant execute on function public.add_task_comment(uuid, text, uuid[]) to authenticated;
grant execute on function public.delete_task_comment(uuid) to authenticated;
grant execute on function public.attach_task_photo(uuid, text) to authenticated;
grant execute on function public.delete_task_photo(uuid) to authenticated;
