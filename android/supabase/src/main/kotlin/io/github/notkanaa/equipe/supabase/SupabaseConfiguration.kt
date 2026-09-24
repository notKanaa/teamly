package io.github.notkanaa.equipe.supabase

/**
 * Connection settings for the Supabase project (publishable key — safe to ship in the app).
 *
 * @property url project URL, e.g. `https://abcdefgh.supabase.co` or `http://127.0.0.1:54321` (local stack), without
 *   a path; trailing slashes are ignored.
 * @property publishableKey `sb_publishable_…` (or a legacy anon JWT). Never a secret key: see
 *   [SupabaseBackend.isSecretKey].
 */
data class SupabaseConfiguration(val url: String, val publishableKey: String)
