JSON used by the decoding and error-mapping unit tests.

- Captured from the local stack (`npx supabase start`, seed data, PostgREST / Supabase Auth): `my_groups`,
  `members`, `group_tasks`, `my_tasks`, `assignments`, `profile`, `invite_code` (reads of the seed user Camille),
  `create_group`, `create_task`, `set_task_status`, `regenerate`, `join_invalid_code` (RPC results of a throwaway
  account), `postgrest_errors` and `auth_errors` (error bodies with their HTTP status and the expected `AppError`).
- Captured from the local stack with the v2 migrations (docs/CONTRACTS-V2.md), for throwaway accounts « Camille / Lucas /
  Inès Fixture » in a group « Coloc fixture » (coral, 🏠): `v2_create_group`, `v2_update_avatar`, `v2_profile`,
  `v2_members`, `v2_create_task` (weekly, rotation Lucas → Camille, 3 checklist items), `v2_checklist_item` (Lucas
  checks « Laver »), `v2_set_task_status` (Lucas completes his turn: next occurrence for Camille), `v2_group_tasks`,
  `v2_my_tasks`, `v2_assignments`, `v2_activity`, `v2_completions` (reads after « Essuyer » was deleted, a monthly
  task on the 31st was created, a plain task was completed, Lucas assigned Camille a task and Inès left), and
  `postgrest_errors_v2` (every v2 error code). The ids are listed in `V2Seed` (V2DecodingTests.swift).
- Written by hand from the Supabase Auth error codes of a hosted project: the last three `auth_errors` entries
  (`email_address_not_authorized`, `signup_disabled`, `reauthentication_needed`).
- Written by hand in the same format: `join_joined`, `join_already_member`, `task_fractional_digits` (timestamps
  with 0 to 6 fractional digits) and `timestamps` (reference values computed independently of the Swift parser).
