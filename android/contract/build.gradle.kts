// Backend-agnostic contract scenarios (Android port of TeamTasksContract), run against :mocks and :supabase.
// Plain suspend functions throwing ContractFailure: no test-framework dependency in main.
plugins {
    `java-library`
    alias(libs.plugins.kotlin.jvm)
}

dependencies {
    api(project(":core"))

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
