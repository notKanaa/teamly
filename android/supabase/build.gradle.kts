// Supabase adapters implementing the :core services (Android port of TeamTasksSupabase).
// Pure JVM so it can be tested against the local Supabase stack without an emulator; the app resolves the
// Android variants of supabase-kt. Ktor engine: OkHttp (JVM and Android).
plugins {
    `java-library`
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    compilerOptions {
        // supabase-kt 3.8.0 exposes kotlin.time.Instant / Clock (UserSession.expiresAt).
        optIn.add("kotlin.time.ExperimentalTime")
    }
}

dependencies {
    api(project(":core"))

    implementation(platform(libs.supabase.bom))
    implementation(libs.supabase.auth)
    // Realtime filters (postgrest-kt is also a dependency of realtime-kt); the PostgREST requests themselves are
    // built by the adapters' own RestClient (exact query strings of docs/CONTRACTS.md §4.3).
    implementation(libs.supabase.postgrest)
    implementation(libs.supabase.realtime)
    implementation(platform(libs.ktor.bom))
    implementation(libs.ktor.client.okhttp)

    // Contract scenarios (integration tests against a real Supabase) and the seed data of DemoData.
    testImplementation(project(":contract"))
    testImplementation(project(":mocks"))
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(platform(libs.ktor.bom))
    testImplementation(libs.ktor.client.mock)
}

tasks.withType<Test>().configureEach {
    // The integration tests only run when SUPABASE_URL and SUPABASE_KEY are set (MAILPIT_URL for the recovery
    // e-mail): the environment is an input, so a run with another environment is never answered from the cache.
    for (name in listOf("SUPABASE_URL", "SUPABASE_KEY", "MAILPIT_URL")) {
        inputs.property("env.$name", providers.environmentVariable(name).orElse(""))
    }
}
