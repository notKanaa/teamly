JSON used by the decoding and error-mapping unit tests.

- Captured from the local stack (`npx supabase start`, seed data, PostgREST / Supabase Auth): `my_groups`,
  `members`, `group_tasks`, `my_tasks`, `assignments`, `profile`, `invite_code` (reads of the seed user Camille),
  `create_group`, `create_task`, `set_task_status`, `regenerate`, `join_invalid_code` (RPC results of a throwaway
  account), `postgrest_errors` and `auth_errors` (error bodies with their HTTP status and the expected `AppError`).
- Written by hand in the same format: `join_joined`, `join_already_member`, `task_fractional_digits` (timestamps
  with 0 to 6 fractional digits) and `timestamps` (reference values computed independently of the Swift parser).
