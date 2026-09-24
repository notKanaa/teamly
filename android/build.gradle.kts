import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension

// Plugins are declared once here (apply false) so every module shares one classloader. Declaring the Kotlin
// plugins here also puts KGP 2.4.20 on the classpath, which AGP 9's built-in Kotlin then uses instead of its
// own runtime dependency (KGP 2.2.10).
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}

// Pure JVM modules (:core, :mocks, :contract, :supabase) also run on Android (minSdk 26). They are built with JDK 17
// but compiled against the Java 8 API (-Xjdk-release=1.8): a Java 9+ call that Android 26 lacks
// (LocalDate.ofInstant, List.of, String.repeat…) fails at compile time instead of crashing on old phones.
subprojects {
    plugins.withId("org.jetbrains.kotlin.jvm") {
        extensions.configure<JavaPluginExtension> {
            toolchain.languageVersion = JavaLanguageVersion.of(17)
            sourceCompatibility = JavaVersion.VERSION_1_8
            targetCompatibility = JavaVersion.VERSION_1_8
        }
        extensions.configure<KotlinJvmProjectExtension> {
            compilerOptions {
                jvmTarget = JvmTarget.JVM_1_8
                freeCompilerArgs.add("-Xjdk-release=1.8")
            }
        }
        tasks.withType<Test>().configureEach {
            useJUnit()
            maxHeapSize = "512m"
            testLogging {
                events("failed")
                exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
            }
        }
    }
}
