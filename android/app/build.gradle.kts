import java.io.StringReader
import java.util.Base64
import java.util.Properties

// Android application « Équipe » (Compose, Material 3). AGP 9 compiles Kotlin itself (built-in Kotlin):
// org.jetbrains.kotlin.android must not be applied.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// region Build-time settings (never commit a value: pass them as Gradle properties or environment variables)

/** Gradle property [property] (`-P…`, `~/.gradle/gradle.properties`), else environment variable [variable], else "". */
fun buildSetting(property: String, variable: String): String =
    providers.gradleProperty(property).orElse(providers.environmentVariable(variable)).orElse("").get().trim()

/**
 * A Supabase key that must never ship in an app: a secret key (`sb_secret_…`) or a legacy JWT whose `role` is not
 * `anon`. Same rules as `SupabaseBackend.isSecretKey` (checked again at run time): such a key is never embedded.
 */
fun isSecretSupabaseKey(key: String): Boolean {
    if (key.startsWith("sb_" + "secret_")) return true
    val parts = key.split('.')
    if (parts.size != 3) return false
    val payload = try {
        String(Base64.getUrlDecoder().decode(parts[1]), Charsets.UTF_8).trim()
    } catch (error: IllegalArgumentException) {
        return false
    }
    if (!payload.startsWith("{")) return false
    val role = Regex("\"role\"\\s*:\\s*\"([^\"]*)\"").find(payload)?.groupValues?.get(1)
    return role != "anon"
}

/** A Java string literal for `buildConfigField`. */
fun javaStringLiteral(value: String): String =
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "") + "\""

/** Project URL, e.g. `https://abcdefgh.supabase.co` (local stack from the emulator: `http://10.0.2.2:54321`). */
val supabaseUrl = buildSetting("equipe.supabaseUrl", "SUPABASE_URL")

/** Publishable key (`sb_publishable_…`). A secret key is replaced by "" and flagged (« Configuration manquante »). */
val supabaseKey = buildSetting("equipe.supabaseKey", "SUPABASE_PUBLISHABLE_KEY")
val supabaseKeyIsSecret = isSecretSupabaseKey(supabaseKey)
if (supabaseKeyIsSecret) {
    logger.warn(
        "w: SUPABASE_PUBLISHABLE_KEY / equipe.supabaseKey holds a secret key: it is NOT embedded in the app, which " +
            "will show « Configuration manquante ». Use the publishable key (sb_publishable_…).",
    )
}

/** Debug builds only: `-Pequipe.mockScenario=populated` (or signedOut, emptyGroups) always runs on the mock backend. */
val debugMockScenario = providers.gradleProperty("equipe.mockScenario").orElse("").get().trim()

/**
 * Release signing: `-Pequipe.signingPropertiesFile=<path>` (absolute, or relative to android/) naming a properties file
 * with storeFile (absolute, or relative to that file), storePassword, keyAlias and keyPassword. Without it the release
 * APK is unsigned.
 */
val signingPropertiesPath =
    providers.gradleProperty("equipe.signingPropertiesFile").orNull?.trim()?.takeIf { it.isNotEmpty() }

// endregion

android {
    namespace = "io.github.notkanaa.equipe"
    compileSdk {
        version = release(37) {
            minorApiLevel = 0
        }
    }
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "io.github.notkanaa.equipe"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "1.0.0"

        buildConfigField("String", "SUPABASE_URL", javaStringLiteral(supabaseUrl))
        buildConfigField(
            "String",
            "SUPABASE_PUBLISHABLE_KEY",
            javaStringLiteral(if (supabaseKeyIsSecret) "" else supabaseKey),
        )
        buildConfigField("boolean", "SUPABASE_KEY_IS_SECRET", supabaseKeyIsSecret.toString())
    }

    signingConfigs {
        if (signingPropertiesPath != null) {
            create("release") {
                val propertiesFile = rootProject.layout.projectDirectory.file(signingPropertiesPath)
                val source = propertiesFile.asFile
                val text = providers.fileContents(propertiesFile).asText.orNull
                    ?: throw GradleException("equipe.signingPropertiesFile: $source does not exist.")
                val properties = Properties().apply { load(StringReader(text)) }
                fun required(name: String): String =
                    properties.getProperty(name)?.trim()?.takeIf { it.isNotEmpty() }
                        ?: throw GradleException("equipe.signingPropertiesFile: « $name » is missing in $source.")
                val keystore = File(required("storeFile")).let { file ->
                    if (file.isAbsolute) file else source.parentFile.resolve(file.path)
                }
                if (!keystore.isFile) {
                    throw GradleException("equipe.signingPropertiesFile: the keystore $keystore does not exist.")
                }
                storeFile = keystore
                storePassword = required("storePassword")
                keyAlias = required("keyAlias")
                keyPassword = required("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // Constant (unlike BuildConfig.DEBUG): the mock code paths are compiled out of release builds by R8.
            buildConfigField("boolean", "MOCK_BACKEND_AVAILABLE", "true")
            buildConfigField("String", "MOCK_SCENARIO", javaStringLiteral(debugMockScenario))
        }
        release {
            // Mock launches are debug-only: release builds have no mock scenario and ignore the launch extras.
            buildConfigField("boolean", "MOCK_BACKEND_AVAILABLE", "false")
            buildConfigField("String", "MOCK_SCENARIO", javaStringLiteral(""))
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Unsigned unless equipe.signingPropertiesFile is given.
            signingConfig = signingConfigs.findByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    androidResources {
        // French-only app: keep the default resources and the French translations of the libraries.
        localeFilters += listOf("fr")
    }
}

dependencies {
    implementation(project(":core"))
    // In-memory backend of the debug `mockScenario` launches (unreachable in release builds: R8 removes it).
    implementation(project(":mocks"))
    implementation(project(":supabase"))

    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.work.runtime.ktx)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
}
