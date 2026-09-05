import com.sun.management.OperatingSystemMXBean
import java.lang.management.ManagementFactory

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
}

fun quoted(value: String): String = "\"${value.replace("\"", "\\\"")}\""

/**
 * Base address of the public model catalog, which supplies model capabilities and prices.
 *
 * Override it with `-PORIVEO_METADATA_BASE_URL=https://your.host` to serve the catalog yourself,
 * or with an empty value to build an app that never contacts a catalog at all. There is no bundled
 * fallback, so such a build lists no models for the official providers; every model then comes from
 * a relay, a local engine, or manual entry.
 */
val metadataBaseUrl = providers.gradleProperty("ORIVEO_METADATA_BASE_URL").orNull
    ?: "https://api.oriveoai.com"

/**
 * Release signing comes from Gradle properties so that no keystore path or password is ever
 * committed. Set the four below in `~/.gradle/gradle.properties`; see SIGNING.md.
 */
val releaseKeystorePath = providers.gradleProperty("ORIVEO_RELEASE_KEYSTORE_PATH").orNull
val releaseKeystorePassword = providers.gradleProperty("ORIVEO_RELEASE_KEYSTORE_PASSWORD").orNull
val releaseKeyAlias = providers.gradleProperty("ORIVEO_RELEASE_KEY_ALIAS").orNull
val releaseKeyPassword = providers.gradleProperty("ORIVEO_RELEASE_KEY_PASSWORD").orNull
val releaseSigningReady =
    releaseKeystorePath != null &&
        releaseKeystorePassword != null &&
        releaseKeyAlias != null &&
        releaseKeyPassword != null &&
        file(releaseKeystorePath).exists()

/**
 * How many test JVMs to run at once.
 *
 * Derived from the machine rather than hard-coded, because a fixed number either wastes half a
 * workstation or swaps a laptop to death. Each fork gets one heap plus roughly as much again in
 * JVM overhead, and the reserve keeps the OS, the Gradle daemon and the Kotlin daemon alive.
 */
val testForkHeapGiB = 1L
val testForkOverheadGiB = 1L
val hostReservedGiB = 12L
val hostCores = Runtime.getRuntime().availableProcessors()
val hostMemoryGiB: Long = runCatching {
    val os = ManagementFactory.getOperatingSystemMXBean() as OperatingSystemMXBean
    os.totalMemorySize / (1024L * 1024L * 1024L)
}.getOrDefault(16L)
val testMaxParallelForks = minOf(
    maxOf(1, hostCores / 2),
    maxOf(1, ((hostMemoryGiB - hostReservedGiB) / (testForkHeapGiB + testForkOverheadGiB)).toInt()),
)

android {
    namespace = "ai.oriveo.community"
    compileSdk {
        version = release(37) {
            minorApiLevel = 1
        }
    }
    testBuildType = if (providers.gradleProperty("ORIVEO_ANDROID_INSTRUMENTED").orNull == "1") "benchmark" else "debug"

    defaultConfig {
        applicationId = "ai.oriveo.community"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "METADATA_BASE_URL", quoted(metadataBaseUrl))
    }

    bundle {
        language {
            // Ship every translation in one artifact. Split language assets are downloaded on
            // demand, so a user who switches the in-app language offline would otherwise fall
            // back to English mid-session.
            enableSplit = false
        }
    }

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
        }
        create("benchmark") {
            initWith(getByName("release"))
            signingConfig = getByName("debug").signingConfig
            matchingFallbacks += listOf("release")
            isDebuggable = false
        }
        release {
            signingConfig = if (releaseSigningReady) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "No release keystore configured, so the release build is signed with the debug key. " +
                        "See SIGNING.md before distributing it.",
                )
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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

    testOptions {
        unitTests {
            isReturnDefaultValues = true
        }
        unitTests.all {
            // A fresh JVM per test class. Several of these tests exercise process-wide state
            // (singletons, static caches, the Compose runtime), and reusing a fork lets one class
            // decide whether the next one passes.
            it.forkEvery = 1
            it.maxHeapSize = "${testForkHeapGiB}g"
            it.maxParallelForks = testMaxParallelForks
        }
    }
}

// Release artifacts must never be produced with the debug key by accident, so the check runs both
// at configuration time (fails before any work happens) and again just before the task executes
// (catches a task pulled in as a dependency of something else).
val releaseArtifactTasks = setOf("bundleRelease", "assembleRelease", "packageRelease", "signReleaseBundle")
val releaseSigningFailure =
    "Release signing is not configured. keystore=${releaseKeystorePath ?: "<unset>"} " +
        "(exists=${releaseKeystorePath?.let { file(it).exists() } ?: false}). " +
        "Set the four ORIVEO_RELEASE_* Gradle properties; see SIGNING.md."
val requireReleaseSigning: () -> Unit = {
    if (!releaseSigningReady) throw GradleException(releaseSigningFailure)
}

if (gradle.startParameter.taskNames.any { it.substringAfterLast(':') in releaseArtifactTasks }) {
    requireReleaseSigning()
}
tasks.matching { it.name in releaseArtifactTasks }.configureEach {
    doFirst { requireReleaseSigning() }
}

// Compose compiler reports say which composables are skippable and which parameters are unstable.
// The stability file tells the compiler to treat a few external types as stable, which it cannot
// infer on its own.
composeCompiler {
    val reportsDir = layout.buildDirectory.dir("compose-reports")
    reportsDestination.set(reportsDir)
    metricsDestination.set(reportsDir)

    val stabilityFile = layout.projectDirectory.file("compose-stability.txt")
    stabilityConfigurationFiles.add(stabilityFile)
}

ksp {
    arg("room.schemaLocation", "$projectDir/schemas")
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    // AndroidX
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.security.crypto)
    implementation(libs.androidx.browser)

    // Compose
    val composeBom = platform(libs.compose.bom)
    implementation(composeBom)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material.icons.extended)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.haze.core)
    implementation(libs.haze.materials)

    // Room
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)

    // Ktor
    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.okhttp)
    implementation(libs.ktor.client.content.negotiation)
    implementation(libs.ktor.serialization.kotlinx.json)
    implementation(libs.ktor.client.logging)

    // Koin
    implementation(libs.koin.android)
    implementation(libs.koin.androidx.compose)

    // Serialization
    implementation(libs.kotlinx.serialization.json)

    implementation(libs.material)

    // Document text extraction
    implementation(libs.pdfbox.android)
    implementation(libs.jsoup)

    // LaTeX rendering in Markdown
    implementation(libs.jlatexmath.android)
    implementation(libs.jlatexmath.android.font.cyrillic)
    implementation(libs.jlatexmath.android.font.greek)

    implementation(libs.androidx.metrics.performance)
    implementation(libs.androidx.profileinstaller)

    // Testing
    testImplementation(libs.junit)
    testImplementation(libs.mockk)
    testImplementation(libs.turbine)
    testImplementation(libs.ktor.client.mock)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}
