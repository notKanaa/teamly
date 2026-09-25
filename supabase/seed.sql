-- Équipe — demo data (docs/CONTRACTS.md §8). Loaded by `supabase db reset` (local only).
-- Password of every demo user: motdepasse123. Dates are relative to now() in Europe/Paris.

-- The local stack and CI never send ntfy pushes (pgTAP turns them on inside its own transaction).
update private.settings set value = null where key = 'ntfy_base_url';

-- Users -------------------------------------------------------------------------------------------------
-- GoTrue scans several token/text columns into non-nullable strings: they must be '' (not NULL) or the
-- users cannot sign in. Profiles are created by the on_auth_user_created trigger from display_name.

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  email_change_token_current, phone_change, phone_change_token, reauthentication_token
)
select
  '00000000-0000-0000-0000-000000000000'::uuid,
  u.id,
  'authenticated',
  'authenticated',
  u.email,
  extensions.crypt('motdepasse123', extensions.gen_salt('bf')),
  now() - interval '30 days',
  '{"provider": "email", "providers": ["email"]}'::jsonb,
  jsonb_build_object('display_name', u.display_name),
  now() - interval '30 days',
  now() - interval '30 days',
  '', '', '', '', '', '', '', ''
from (values
  ('11111111-1111-4111-8111-111111111111'::uuid, 'camille@example.com', 'Camille Martin'),
  ('22222222-2222-4222-8222-222222222222'::uuid, 'lucas@example.com', 'Lucas Bernard'),
  ('33333333-3333-4333-8333-333333333333'::uuid, 'ines@example.com', 'Inès Dubois')
) as u (id, email, display_name);

insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select
  u.id::text,
  u.id,
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true, 'phone_verified', false),
  'email',
  now() - interval '30 days',
  now() - interval '30 days',
  now() - interval '30 days'
from auth.users u
where u.id in (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333'
);

-- Groups, members, invite codes ----------------------------------------------------------------------------

insert into public.groups (id, name, created_by, created_at, last_activity_at) values
  ('a0000000-0000-4000-8000-000000000001', 'Coloc'' rue des Lilas', '11111111-1111-4111-8111-111111111111',
   now() - interval '10 days', now() - interval '10 days'),
  ('a0000000-0000-4000-8000-000000000002', 'Projet Asso Sport', '22222222-2222-4222-8222-222222222222',
   now() - interval '20 days', now() - interval '20 days');

insert into public.group_members (group_id, user_id, role, joined_at) values
  ('a0000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'admin', now() - interval '10 days'),
  ('a0000000-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'member', now() - interval '9 days'),
  ('a0000000-0000-4000-8000-000000000001', '33333333-3333-4333-8333-333333333333', 'member', now() - interval '8 days'),
  ('a0000000-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222', 'admin', now() - interval '20 days'),
  ('a0000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'member', now() - interval '15 days');

insert into public.group_invites (group_id, code, created_by, created_at) values
  ('a0000000-0000-4000-8000-000000000001', 'LYLAS234', '11111111-1111-4111-8111-111111111111', now() - interval '10 days'),
  ('a0000000-0000-4000-8000-000000000002', 'SPRT5678', '22222222-2222-4222-8222-222222222222', now() - interval '20 days');

-- Tasks -------------------------------------------------------------------------------------------------

with paris as (
  select (now() at time zone 'Europe/Paris')::date as today
)
insert into public.tasks (id, group_id, title, details, status, priority, due_at, created_by, created_at, updated_at, completed_at)
select t.id, t.group_id, t.title, t.details, t.status, t.priority, t.due_at, t.created_by, t.created_at, t.created_at, t.completed_at
from paris, lateral (values
  -- « Coloc' rue des Lilas »
  ('b0000000-0000-4000-8000-000000000001'::uuid, 'a0000000-0000-4000-8000-000000000001'::uuid,
   'Sortir les poubelles', 'Poubelle jaune et poubelle verte.',
   'todo'::public.task_status, 'high'::public.task_priority,
   (paris.today + time '20:00') at time zone 'Europe/Paris',
   '11111111-1111-4111-8111-111111111111'::uuid, now() - interval '3 days', null::timestamptz),
  ('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001',
   'Faire les courses', 'Lait, pâtes, lessive et papier toilette.',
   'in_progress', 'medium',
   (paris.today + 1 + time '18:00') at time zone 'Europe/Paris',
   '22222222-2222-4222-8222-222222222222', now() - interval '2 days', null),
  ('b0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000001',
   'Payer le loyer', null,
   'todo', 'high',
   (paris.today - 1 + time '18:00') at time zone 'Europe/Paris',
   '11111111-1111-4111-8111-111111111111', now() - interval '6 days', null),
  ('b0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000001',
   'Réparer la fuite du lavabo', 'Le joint sous le lavabo de la salle de bain goutte.',
   'todo', 'low',
   null,
   '33333333-3333-4333-8333-333333333333', now() - interval '5 days', null),
  ('b0000000-0000-4000-8000-000000000005', 'a0000000-0000-4000-8000-000000000001',
   'Nettoyer la cuisine', null,
   'done', 'medium',
   null,
   '22222222-2222-4222-8222-222222222222', now() - interval '4 days',
   (paris.today - 1 + time '19:00') at time zone 'Europe/Paris'),
  -- « Projet Asso Sport »
  ('b0000000-0000-4000-8000-000000000006', 'a0000000-0000-4000-8000-000000000002',
   'Réserver le gymnase', 'Samedi après-midi, pour le tournoi.',
   'todo', 'high',
   (paris.today + 3 + time '18:00') at time zone 'Europe/Paris',
   '22222222-2222-4222-8222-222222222222', now() - interval '7 days', null),
  ('b0000000-0000-4000-8000-000000000007', 'a0000000-0000-4000-8000-000000000002',
   'Créer l''affiche du tournoi', null,
   'in_progress', 'low',
   (paris.today + 7 + time '12:00') at time zone 'Europe/Paris',
   '22222222-2222-4222-8222-222222222222', now() - interval '7 days', null)
) as t (id, group_id, title, details, status, priority, due_at, created_by, created_at, completed_at);

insert into public.task_assignees (task_id, group_id, user_id, assigned_by, assigned_at) values
  ('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001',
   '11111111-1111-4111-8111-111111111111', '11111111-1111-4111-8111-111111111111', now() - interval '3 days'),
  ('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001',
   '22222222-2222-4222-8222-222222222222', '22222222-2222-4222-8222-222222222222', now() - interval '2 days'),
  ('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001',
   '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', now() - interval '2 days'),
  ('b0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000001',
   '33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111', now() - interval '6 days'),
  ('b0000000-0000-4000-8000-000000000005', 'a0000000-0000-4000-8000-000000000001',
   '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', now() - interval '4 days'),
  ('b0000000-0000-4000-8000-000000000006', 'a0000000-0000-4000-8000-000000000002',
   '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', now() - interval '7 days'),
  ('b0000000-0000-4000-8000-000000000007', 'a0000000-0000-4000-8000-000000000002',
   '22222222-2222-4222-8222-222222222222', '22222222-2222-4222-8222-222222222222', now() - interval '7 days');

-- v2 decorations (docs/CONTRACTS-V2.md §12) ---------------------------------------------------------------------
-- Separate updates: the v1 rows above stay as they are (the v1 scenarios and the seed parity tests read them).

update public.groups set color = 'coral', emoji = '🏠' where id = 'a0000000-0000-4000-8000-000000000001';
update public.groups set color = 'green', emoji = '⚽' where id = 'a0000000-0000-4000-8000-000000000002';

-- Demo accounts are onboarded (as the migration does for the accounts that existed before v2).
update public.profiles set onboarded_at = created_at
where id in (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333'
);

-- The fixture inserts above wrote member_joined events; they are not user actions: the demo feed starts empty.
delete from public.group_activity;
