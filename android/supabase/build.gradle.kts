// Supabase adapters implementing the :core services (Android port of TeamTasksSupabase).
// Pure JVM so it can be tested against the local Supabase stack without an emulator; the app resolves the
// Android variants of supabase-kt. Ktor engine: OkHttp (JVM and Android).
plugins {
    `java-library`
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

dependencies {
    api(project(":core"))

    implementation(platform(libs.supabase.bom))
    implementation(libs.supabase.auth)
    implementation(libs.supabase.postgrest)
    implementation(libs.supabase.realtime)
    implementation(platform(libs.ktor.bom))
    implementation(libs.ktor.client.okhttp)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
