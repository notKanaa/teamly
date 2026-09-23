-- Équipe — enums, the private schema and shared private utilities.
-- See docs/CONTRACTS.md §1 (validation) and §3 (schema).

-- Enums --------------------------------------------------------------------------------------------

create type public.member_role as enum ('admin', 'member');
create type public.task_status as enum ('todo', 'in_progress', 'done');
create type public.task_priority as enum ('low', 'medium', 'high');

-- Private schema -----------------------------------------------------------------------------------
-- Not exposed through the Data API and not usable by API roles (no USAGE). RLS policies still call the
-- helper functions it contains: policy expressions are stored pre-resolved, so only EXECUTE is checked.

create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon, authenticated;
-- Functions created later in `private` are not executable by PUBLIC by default.
alter default privileges in schema private revoke execute on functions from public;

-- Text normalization -------------------------------------------------------------------------------
-- Trims leading/trailing whitespace and newlines, mirroring Swift's
-- `trimmingCharacters(in: .whitespacesAndNewlines)` (ASCII whitespace, NEL and Unicode Z* spaces).

create function private.clean_text(p_value text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select pg_catalog.regexp_replace(
    p_value,
    '^[\s\u0085   -     　]+|[\s\u0085   -     　]+$',
    '',
    'g'
  );
$$;

-- Business error helpers -----------------------------------------------------------------------------

-- Returns the caller's user id or raises `not_authenticated` (P0001).
create function private.require_uid()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;
  return v_uid;
end;
$$;

-- Random strings -----------------------------------------------------------------------------------

-- `p_length` characters drawn uniformly from `p_alphabet` (at most 256 characters) with a CSPRNG
-- (rejection sampling, no modulo bias).
create function private.random_string(p_alphabet text, p_length integer)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_size constant integer := char_length(p_alphabet);
  v_limit constant integer := 256 - (256 % v_size);
  v_result text := '';
  v_bytes bytea;
  v_byte integer;
begin
  while char_length(v_result) < p_length loop
    v_bytes := extensions.gen_random_bytes(32);
    for i in 0 .. 31 loop
      v_byte := get_byte(v_bytes, i);
      if v_byte < v_limit and char_length(v_result) < p_length then
        v_result := v_result || substr(p_alphabet, (v_byte % v_size) + 1, 1);
      end if;
    end loop;
  end loop;
  return v_result;
end;
$$;

-- A new, currently unused invite code: 8 characters of `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`.
-- Must stay in sync with `InviteCode` (Swift) and the `group_invites.code` check constraint.
create function private.generate_invite_code()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_code text;
begin
  loop
    v_code := private.random_string('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 8);
    exit when not exists (select 1 from public.group_invites gi where gi.code = v_code);
  end loop;
  return v_code;
end;
$$;

-- Nothing in `private` is callable by API roles unless granted explicitly (RLS helpers only).
revoke all on all functions in schema private from public, anon, authenticated;
