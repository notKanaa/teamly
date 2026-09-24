package io.github.notkanaa.equipe.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.realtime.Realtime
import io.ktor.client.engine.okhttp.OkHttp

/**
 * Placeholder of the Supabase adapters (Android port of TeamTasksSupabase): builds the supabase-kt client (Auth,
 * PostgREST, Realtime) on the OkHttp engine, which works on the JVM and on Android. The adapters implementing the
 * :core services (docs/CONTRACTS.md §4, §6, §9) are built on it.
 */
object SupabaseClientFactory {
    fun create(url: String, anonKey: String): SupabaseClient = createSupabaseClient(url, anonKey) {
        httpEngine = OkHttp.create()
        install(Auth)
        install(Postgrest)
        install(Realtime)
    }
}
