# Équipe — Android

Native Android version of « Équipe » (Kotlin, Jetpack Compose, Material 3). It uses the **same Supabase backend**
as the iOS app and must behave like it: [`docs/CONTRACTS.md`](../docs/CONTRACTS.md) is authoritative.

## Modules

| Module | Kind | Content | iOS counterpart |
|---|---|---|---|
| `:core` | Kotlin/JVM | Models, service interfaces, `AppError`, `BackendErrorMapper`, permissions, `Limits`, `InviteCode`, `InputValidation`, `NameOrder`, platform ports (package `io.github.notkanaa.equipe.core`); pure logic in `core.logic`: filters, sorting, due buckets, French dates, reminders, assignment notifications, change feed, realtime coordinator | `TeamTasksCore` |
| `:mocks` | Kotlin/JVM | In-memory backend implementing the `:core` services with the SQL semantics; demo data identical to `supabase/seed.sql`; `MockEnvironment` scenarios | `TeamTasksMocks` |
| `:contract` | Kotlin/JVM | The 56 backend-agnostic contract scenarios (same names as iOS), run against the mocks and the Supabase adapters | `TeamTasksContract` |
| `:supabase` | Kotlin/JVM | Adapters on supabase-kt (Auth, Realtime) + an own PostgREST client on Ktor OkHttp; `SupabaseBackend.makeServices`; unit tests and, with SUPABASE_URL/SUPABASE_KEY set, the 56 contract scenarios against a real Supabase | `TeamTasksSupabase` |
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
node D:\mobileApp\_wt\gradle-locked.mjs test                  # every module (app: UI flows and screenshots too)
node D:\mobileApp\_wt\gradle-locked.mjs :app:assembleDebug    # android/app/build/outputs/apk/debug/app-debug.apk
```

Requirements: JDK 17 (`JAVA_HOME`), Android SDK with `platforms;android-37.0` and `build-tools;37.0.0`
(`ANDROID_HOME`, or `sdk.dir` in `android/local.properties`). `gradle.properties` is tuned for 8 GB of RAM
(2 GB Gradle daemon, 1 GB Kotlin daemon, 2 workers).

### App tests (Robolectric, no emulator)

`:app:testDebugUnitTest` (part of `test`; the release build type has no unit tests) runs the app's tests on the JVM
with Robolectric (Android 15 SDK, a 411 × 891 dp phone: `app/src/test/resources/robolectric.properties`):

- `flows.FlowTest`: end-to-end flows through the real shell (`EquipeRoot` / `MainShell`) on the in-memory backend of
  `:mocks`, driven by the iOS accessibility identifiers (test tags), like `App/UITests/FlowTests.swift`;
- `screenshots.ScreenshotTest`: the 10 screens of the iOS suite with the same file names (`01-connexion.png` …
  `10-reglages-compte.png`), `-sombre` (dark) variants of 02, 06 and 07, and `07-mes-taches-police-xl.png` (font scale
  1.8). Roborazzi records them at every run into `app/build/outputs/roborazzi/` (outputs of the test task), with the
  component captures of the groups screens in `groups/`. Robolectric has no system bars: the tests give the window a
  32 dp status bar and a 24 dp navigation bar; dialogs and bottom sheets are drawn without their device margins;
- screen and logic tests (`ui.groups`, `ui.components.tasks`, `config`).

Robolectric downloads its Android SDK jars (~200 MB) into `~/.m2/repository` on first use. To keep them elsewhere (on
this machine: `D:\Dev\robolectric-m2`), add `-Pequipe.robolectricRepository=<folder>` to the command, or set
`equipe.robolectricRepository` in `~/.gradle/gradle.properties`.

### CI

[`.github/workflows/android.yml`](../.github/workflows/android.yml) runs `./gradlew test :app:assembleDebug` (the
`:supabase` integration tests are skipped there: they need `SUPABASE_KEY` and a local stack) and uploads the debug APK
(`Equipe-android-debug`) and the screenshots (`Equipe-android-screenshots`). On `main`, a separate job, the only one
with a write token, force-pushes the screenshots to the orphan branch `ci-screenshots-android`:
`https://raw.githubusercontent.com/notKanaa/teamly/ci-screenshots-android/<name>.png`.

### Signed release APK

`-Pequipe.signingPropertiesFile=<file>` names a properties file kept outside the repository (`storeFile`,
`storePassword`, `keyAlias`, `keyPassword`); `-Pequipe.supabaseUrl` and `-Pequipe.supabaseKey` (the publishable key)
select the backend:

```powershell
node D:\mobileApp\_wt\gradle-locked.mjs :app:assembleRelease "-Pequipe.signingPropertiesFile=<file>" "-Pequipe.supabaseUrl=https://<ref>.supabase.co" "-Pequipe.supabaseKey=<sb_publishable_…>"
```

The APK is `app/build/outputs/apk/release/app-release.apk` (R8, French resources only).

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
