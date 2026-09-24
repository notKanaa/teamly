# Équipe — Android

Native Android version of « Équipe » (Kotlin, Jetpack Compose, Material 3). It uses the **same Supabase backend**
as the iOS app and must behave like it: [`docs/CONTRACTS.md`](../docs/CONTRACTS.md) is authoritative.

## Modules

| Module | Kind | Content | iOS counterpart |
|---|---|---|---|
| `:core` | Kotlin/JVM | Models, service interfaces, `AppError`, `BackendErrorMapper`, permissions, `Limits`, `InviteCode`, `InputValidation`, `NameOrder`, platform ports (package `io.github.notkanaa.equipe.core`) | `TeamTasksCore` |
| `:mocks` | Kotlin/JVM | In-memory backend implementing the `:core` services (placeholder) | `TeamTasksMocks` |
| `:contract` | Kotlin/JVM | Backend-agnostic contract scenarios (placeholder) | `TeamTasksContract` |
| `:supabase` | Kotlin/JVM | Adapters on supabase-kt (Auth, PostgREST, Realtime) + Ktor OkHttp engine (placeholder) | `TeamTasksSupabase` |
| `:app` | Android app | Compose UI, `io.github.notkanaa.equipe`, minSdk 26, target/compile SDK 37, French only | `App/` |

The JVM modules also run on Android, so they are compiled against the **Java 8 API** (`-Xjdk-release=1.8`, set in
the root `build.gradle.kts`): a Java 9+ call missing on Android 8.0 (API 26), such as `LocalDate.ofInstant` or
`List.of`, does not compile. Use `java.time` for dates and `java.util.UUID` for ids. Strings are compared and
measured in code points like Postgres and Swift (see `Unicode.kt`); ids are ordered by `uuidString` (upper case),
never by `UUID.compareTo`.

## Build and test locally

The machine is shared with other builds: always go through the lock wrapper, from the repository root.

```powershell
node D:\mobileApp\_wt\gradle-locked.mjs :core:test            # :core unit tests
node D:\mobileApp\_wt\gradle-locked.mjs test                  # every module
node D:\mobileApp\_wt\gradle-locked.mjs :app:assembleDebug    # android/app/build/outputs/apk/debug/app-debug.apk
```

Requirements: JDK 17 (`JAVA_HOME`), Android SDK with `platforms;android-37.0` and `build-tools;37.0.0`
(`ANDROID_HOME`, or `sdk.dir` in `android/local.properties`). `gradle.properties` is tuned for 8 GB of RAM
(2 GB Gradle daemon, 1 GB Kotlin daemon, 2 workers).

CI: [`.github/workflows/android.yml`](../.github/workflows/android.yml) runs `./gradlew test :app:assembleDebug`
and publishes the debug APK as the `Equipe-android-debug` artifact.

## Versions

| Tool / library | Version |
|---|---|
| Gradle (wrapper, checksum pinned) | 9.7.1 |
| Android Gradle Plugin (built-in Kotlin: no `org.jetbrains.kotlin.android`) | 9.4.1 |
| Kotlin (+ Compose compiler and serialization plugins) | 2.4.20 |
| Compose BOM | 2026.09.00 |
| supabase-kt BOM (auth-kt, postgrest-kt, realtime-kt) | 3.8.0 |
| Ktor (OkHttp engine, aligned on supabase-kt 3.8.0) | 3.5.1 |
| kotlinx-coroutines / kotlinx-serialization-json | 1.11.0 / 1.11.0 |
| AndroidX: core-ktx, activity-compose, lifecycle, navigation-compose, work, datastore | 1.19.1, 1.13.0, 2.11.0, 2.10.2, 2.12.0, 1.2.1 |
| Tests: JUnit 4, Turbine, Robolectric, Roborazzi | 4.13.2, 1.2.1, 4.17, 1.75.0 |

All versions live in [`gradle/libs.versions.toml`](gradle/libs.versions.toml).
