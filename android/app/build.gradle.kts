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
 * or with an empty value to build an app that never contacts a catalog at all. Such a build falls
 * back to the catalog snapshot bundled in the APK (see syncMetadataContractAssets), which is never
 * refreshed; models can also come from a relay, a local engine, or manual entry.
 */
val metadataBaseUrl = providers.gradleProperty("ORIVEO_METADATA_BASE_URL").orNull
    ?: "https://api.oriveoai.com"

/**
 * URL of the OAuth client metadata document that identifies this build to the authorization servers
 * of remote MCP servers.
 *
 * Empty by default: an app you build yourself has no such document hosted anywhere, so it registers
 * with each authorization server dynamically instead. If you host one, pass
 * `-PORIVEO_MCP_CLIENT_METADATA_URL=https://your.host/oauth/mcp-client.json`; the document must list
 * `oriveo://mcp/oauth/callback` as a redirect URI.
 */
val mcpClientMetadataUrl = providers.gradleProperty("ORIVEO_MCP_CLIENT_METADATA_URL").orNull ?: ""

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
        versionCode = 2
        versionName = "1.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "METADATA_BASE_URL", quoted(metadataBaseUrl))
        buildConfigField("String", "MCP_CLIENT_METADATA_URL", quoted(mcpClientMetadataUrl))
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
            isShrinkResources = true
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
            // Robolectric rendering real Compose UI (stringResource, resource ids) needs the merged app
            // resources; without them it fails with Resources$NotFoundException.
            isIncludeAndroidResources = true
        }
        unitTests.all {
            // A fresh JVM per test class. Several of these tests exercise process-wide state
            // (singletons, static caches, the Compose runtime), and reusing a fork lets one class
            // decide whether the next one passes.
            it.forkEvery = 1
            it.maxHeapSize = "${testForkHeapGiB}g"
            it.maxParallelForks = testMaxParallelForks
            // The request-body export (NativeFileRequestExportTest) is switched on by this environment variable. Its
            // output directory is not a declared task output, so without forcing a rerun the task would be
            // UP-TO-DATE when the sources are unchanged and nothing would be written.
            if (!System.getenv("ORIVEO_REQUEST_EXPORT_DIR").isNullOrBlank()) {
                it.outputs.upToDateWhen { false }
            }
            // MockK gets its Instrumentation by having ByteBuddy spawn a java process that attaches back to
            // this JVM. With several forks starting at once that attach fails at random ("Could not
            // self-attach to current VM"), JvmMockKGateway fails to initialise, and every mockk call left in
            // that JVM throws NoClassDefFoundError. Loading the same jar with -javaagent at startup hands
            // ByteBuddyAgent a ready Instrumentation, so nothing attaches. The jar comes from this task's
            // classpath (same version MockK uses) and is looked up at execution time, because AGP replaces
            // the classpath after this block runs.
            it.jvmArgumentProviders.add(CommandLineArgumentProvider {
                listOf("-javaagent:${it.classpath.single { file -> file.name.startsWith("byte-buddy-agent-") }.absolutePath}")
            })
        }
    }

    sourceSets {
        // PdfOcrInstrumentedTest runs the shared scanned-PDF fixtures through the real ML Kit on an emulator.
        // The shared directory is mounted directly instead of copied so there is a single source of truth;
        // it only lands in the test APK (instrumentation.context.assets), never in the app package.
        getByName("androidTest").assets.directories.add(
            "$projectDir/../../shared/test-fixtures/attachments/extraction/files/pdf",
        )
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

// The shared schema and the bundled snapshot used by schema 2 validation are packaged into the APK assets (under model-contracts/).
// The shared/ directory is found by walking up from projectDir; a missing directory or file fails the build
// instead of silently producing a package without the schema.
// The narrow upstream-rejection signature table (contract model catalog and capability truth, section 6.1) is also a shared single source,
// flattened into model-contracts/ as well and read directly at runtime.
val metadataContractAssetFiles = listOf(
    "model-contracts/bundled-metadata.v2.json.gz",
    "model-contracts/metadata_payload.v2.schema.json",
    "test-fixtures/capability/rejection-signatures.v1.json",
    // Bundled external-search catalog snapshot (the ?view=search payload as-is): fallback when neither network nor cache is available
    "search-contracts/search_catalog_view.v1.json",
)
val metadataContractRoot: File? = generateSequence(projectDir) { it.parentFile }
    .map { it.resolve("shared") }
    .firstOrNull { it.resolve("model-contracts").isDirectory }

abstract class SyncMetadataContractAssets : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.NAME_ONLY)
    abstract val contractFiles: ConfigurableFileCollection

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun sync() {
        val missing = contractFiles.files.filterNot { it.isFile }
        if (contractFiles.isEmpty || missing.isNotEmpty()) {
            throw GradleException(
                "Metadata assets not found under shared/model-contracts: " +
                    missing.joinToString { it.path }.ifEmpty { "<no model-contracts directory found>" },
            )
        }
        val target = outputDir.get().asFile.resolve("model-contracts")
        outputDir.get().asFile.deleteRecursively()
        target.mkdirs()
        contractFiles.files.forEach { it.copyTo(target.resolve(it.name), overwrite = true) }
    }
}

val syncMetadataContractAssets = tasks.register<SyncMetadataContractAssets>("syncMetadataContractAssets") {
    metadataContractRoot?.let { root -> contractFiles.from(metadataContractAssetFiles.map { root.resolve(it) }) }
    outputDir.set(layout.buildDirectory.dir("generated/metadataContractAssets"))
}

androidComponents.onVariants { variant ->
    variant.sources.assets?.addGeneratedSourceDirectory(syncMetadataContractAssets, SyncMetadataContractAssets::outputDir)
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
    // The external-search catalog signature check uses Tink's Ed25519Verify (the JCA on minSdk 26 has no Ed25519).
    // tink-android is already a runtime transitive dependency of security-crypto but invisible at compile time, so it
    // is declared explicitly at the same version; the APK gains no extra artifact.
    implementation(libs.tink.android)
    implementation(libs.androidx.browser)
    implementation(libs.androidx.exifinterface)
    implementation(libs.androidx.media3.muxer)

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

    // OCR for scanned PDFs
    implementation(libs.mlkit.text.recognition.chinese)
    implementation(libs.mlkit.text.recognition.japanese)
    implementation(libs.mlkit.text.recognition.korean)
    implementation(libs.mlkit.text.recognition.devanagari)

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
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
    testImplementation(libs.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
}
