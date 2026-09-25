# R8 rules of the release build of « Équipe » (isMinifyEnabled + isShrinkResources, R8 full mode).
#
# Most libraries ship their own consumer rules, which R8 applies automatically:
# - kotlinx-serialization: `Companion` fields, `serializer()` of companion objects and `INSTANCE` of @Serializable
#   classes and objects (META-INF/com.android.tools/r8/kotlinx-serialization-*.pro);
# - kotlinx-coroutines (service loaders, volatile fields), Ktor (engine containers loaded with ServiceLoader, AtomicFU
#   fields: META-INF/proguard/ktor.pro), OkHttp (proguard.txt of okhttp-android);
# - AndroidX: WorkManager keeps the constructors of its workers, AAPT keeps the manifest components (activity,
#   receivers, application class).
# The rules below cover what they do not.

# Readable stack traces in crash reports (line numbers kept, source file names hidden).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# kotlinx.serialization: generic signatures and inner classes are read when a serializer is resolved from a type at
# run time (`serializer(typeOf<T>())`, used by Ktor and supabase-kt to decode HTTP bodies and Realtime messages).
-keepattributes Signature,InnerClasses,EnclosingMethod,RuntimeVisibleAnnotations,AnnotationDefault

# The serializers generated for the app's and the modules' @Serializable classes (persisted notification state, lead
# time, reminder fingerprints, PostgREST rows of :supabase) and for supabase-kt's models (UserSession, UserInfo,
# Realtime messages…): kept with their descriptors so that decoding by name never loses a property.
-keep,includedescriptorclasses class io.github.notkanaa.equipe.**$$serializer { *; }
-keepclassmembers class io.github.notkanaa.equipe.** {
    *** Companion;
}
-keepclasseswithmembers class io.github.notkanaa.equipe.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class io.github.jan.supabase.**$$serializer { *; }
-keepclassmembers class io.github.jan.supabase.** {
    *** Companion;
}
-keepclasseswithmembers class io.github.jan.supabase.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Ktor: the serialization extension providers (kotlinx-json) are loaded with ServiceLoader.
-keep class * implements io.ktor.serialization.kotlinx.KotlinxSerializationExtensionProvider
