# kotlinx.serialization
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt

-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}

-keep,includedescriptorclasses class ai.oriveo.community.**$$serializer { *; }
-keepclassmembers class ai.oriveo.community.** {
    *** Companion;
}
-keepclasseswithmembers class ai.oriveo.community.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Ktor
-keep class io.ktor.** { *; }
-dontwarn io.ktor.**
-keep class kotlinx.coroutines.** { *; }
-dontwarn kotlinx.coroutines.**

# Room
-keep class * extends androidx.room.RoomDatabase
-keep @androidx.room.Entity class *
-dontwarn androidx.room.paging.**

# Koin
-keep class org.koin.** { *; }
-dontwarn org.koin.**

# OkHttp, used as the Ktor engine
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }

# Optional JPEG 2000 decoder that is not bundled
-dontwarn com.gemalto.jp2.JP2Decoder

# Navigation routes are resolved by fully qualified name, so they must not be renamed
-keep class ai.oriveo.community.core.navigation.** { *; }

# @Serializable enums are looked up by name at runtime
-keep @kotlinx.serialization.Serializable enum ** { *; }

# PdfBox-Android loads its resources and CMaps by reflection
-keep class com.tom_roush.pdfbox.** { *; }
-dontwarn com.tom_roush.pdfbox.**

# Keep line numbers so a stack trace from a release build is still readable
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
