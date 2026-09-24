-- Équipe — delete_my_account also erases the account's Auth audit trail (docs/CONTRACTS.md §2).
--
-- Supabase Auth logs every sign-up, sign-in, token refresh, password change… in auth.audit_log_entries with
-- the account's e-mail (`payload.actor_username`) and IP address. Deleting auth.users does not touch that
-- table, so the e-mail of a deleted account stayed in the database. Same body as the previous version plus
-- the audit deletion, which is best effort: if the platform denies it (or the table changes), the account is
-- still deleted.

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_group_id uuid;
  v_role public.member_role;
  v_members integer;
  v_admins integer;
  v_next uuid;
begin
  for v_group_id, v_role in
    select gm.group_id, gm.role
    from public.group_members gm
    where gm.user_id = v_uid
    order by gm.group_id
  loop
    perform 1 from public.groups g where g.id = v_group_id for update;

    select count(*), count(*) filter (where gm.role = 'admin')
    into v_members, v_admins
    from public.group_members gm
    where gm.group_id = v_group_id;

    if v_members = 1 then
      delete from public.groups g where g.id = v_group_id;
    elsif v_role = 'admin' and v_admins = 1 then
      select gm.user_id into v_next
      from public.group_members gm
      where gm.group_id = v_group_id
        and gm.user_id <> v_uid
      order by gm.joined_at, gm.user_id
      limit 1;

      update public.group_members
      set role = 'admin'
      where group_id = v_group_id
        and user_id = v_next;
    end if;
  end loop;

  delete from private.join_attempts ja where ja.user_id = v_uid;

  begin
    delete from auth.audit_log_entries a where a.payload ->> 'actor_id' = v_uid::text;
  exception when others then
    raise warning 'delete_my_account: audit log not erased (%)', sqlstate;
  end;

  delete from auth.users u where u.id = v_uid;
end;
$$;
