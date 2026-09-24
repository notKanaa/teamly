// Backend-agnostic contract scenarios (Android port of TeamTasksContract), run against :mocks and :supabase.
plugins {
    `java-library`
    alias(libs.plugins.kotlin.jvm)
}

dependencies {
    api(project(":core"))

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
