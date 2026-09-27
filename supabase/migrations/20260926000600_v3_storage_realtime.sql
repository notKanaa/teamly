-- Teamly v3 — task photo storage (docs/CONTRACTS-V3.md §6) and the Realtime publication (§11).

-- Bucket `task-photos` ------------------------------------------------------------------------------------------------------
-- Private (signed URLs only), 5 MiB (5 242 880 bytes) per object, JPEG / PNG / HEIC. Created here rather than in
-- supabase/config.toml so that production gets it too; the local stack needs `[storage] enabled = true`.
-- Object path: `<group_id>/<task_id>/<uuid>.<ext>`, ids in lowercase (Postgres uuid::text).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('task-photos', 'task-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Policies on storage.objects, for this bucket only ----------------------------------------------------------------------------
-- The first path segment is compared as text with the caller's group ids (no uuid cast: a malformed name never raises).
-- There is no UPDATE policy: an object is never overwritten (no upsert) nor moved.
-- - select (download, signed URLs) and insert (upload): the first segment is one of my groups;
-- - delete: while a member of that group, the object's owner (owner_id = the uploader's id) or an admin of the group.

create policy task_photos_objects_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'task-photos'
    and (storage.foldername(name))[1] in (select g.id::text from private.my_group_ids() as g (id))
  );

create policy task_photos_objects_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'task-photos'
    and (storage.foldername(name))[1] in (select g.id::text from private.my_group_ids() as g (id))
  );

create policy task_photos_objects_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'task-photos'
    and (storage.foldername(name))[1] in (select g.id::text from private.my_group_ids() as g (id))
    and (
      owner_id = (select auth.uid()::text)
      or (storage.foldername(name))[1] in (select g.id::text from private.my_admin_group_ids() as g (id))
    )
  );

-- Realtime publication ------------------------------------------------------------------------------------------------------------
-- v1 (groups, profiles, task_assignees) plus task_nudges, turn_swaps, activity_reactions and task_comments. INSERT and UPDATE
-- only, as in v1: Realtime cannot apply RLS to DELETE events. Realtime applies the SELECT policies of these tables to every
-- subscriber. (`set table` keeps the publish list, which is set explicitly again.)

do $$
begin
  if exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime set table
      public.groups, public.profiles, public.task_assignees,
      public.task_nudges, public.turn_swaps, public.activity_reactions, public.task_comments;
  else
    create publication supabase_realtime for table
      public.groups, public.profiles, public.task_assignees,
      public.task_nudges, public.turn_swaps, public.activity_reactions, public.task_comments;
  end if;
  alter publication supabase_realtime set (publish = 'insert, update');
end;
$$;
