package ai.oriveo.community.core.voice

import android.content.Context
import android.os.Looper
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.util.Locale
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Drives the production [SystemSTTRouter] with a fake recognizer backend and an injected sdkInt. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SystemSTTRouteTest {

    private class FakeBackend : SystemSTTBackend {
        var available = true
        var onDeviceAvailable = true
        var enabledService = true
        var ui: Locale = Locale.forLanguageTag("fr-FR")
        val supports = mutableMapOf<SystemSTTRecognizer, SystemSTTSupport?>()
        val checks = mutableListOf<Pair<SystemSTTRecognizer, String>>()
        val downloads = mutableListOf<Pair<SystemSTTRecognizer, String>>()

/** When set, suspends on it (simulating a recognition service that never calls back) and returns only once it completes. */
        val pending = mutableMapOf<SystemSTTRecognizer, CompletableDeferred<SystemSTTSupport?>>()

        override fun isRecognitionAvailable(): Boolean = available
        override fun isOnDeviceRecognitionAvailable(): Boolean = onDeviceAvailable
        override fun hasEnabledRecognitionService(): Boolean = enabledService
        override suspend fun checkSupport(recognizer: SystemSTTRecognizer, languageTag: String): SystemSTTSupport? {
            checks += recognizer to languageTag
            pending[recognizer]?.let { return it.await() }
            return supports[recognizer]
        }

        override fun triggerModelDownload(recognizer: SystemSTTRecognizer, languageTag: String) {
            downloads += recognizer to languageTag
        }

        override fun uiLocale(): Locale = ui
    }

    @Test
    fun `sdk 33 on-device installed language routes pipe through on-device`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(installedOnDevice = listOf("EN-us"))
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("en-US"))

        val route = SystemSTTRouter(backend, sdkInt = 33).route("en-US")

        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.ON_DEVICE, "EN-us"), route)
        assertEquals(emptyList<Pair<SystemSTTRecognizer, String>>(), backend.downloads)
    }

    @Test
    fun `sdk 33 only default online support routes pipe through default`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(installedOnDevice = listOf("ja-JP"))
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("de-AT", "de-DE"))

        val route = SystemSTTRouter(backend, sdkInt = 33).route("de-DE")

        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "de-DE"), route)
        assertEquals(
            listOf(SystemSTTRecognizer.ON_DEVICE to "de-DE", SystemSTTRecognizer.DEFAULT to "de-DE"),
            backend.checks,
        )
    }

    @Test
    fun `primary subtag match is used when no exact tag`() = runTest {
        val backend = FakeBackend()
        backend.onDeviceAvailable = false
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("es-MX"))

        val route = SystemSTTRouter(backend, sdkInt = 34).route("es-ES")

        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "es-MX"), route)
    }

    @Test
    fun `sdk 33 only on-device downloadable self records with a language pack offer and no download`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(downloadableOnDevice = listOf("ko-KR"))
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("en-US"))
        val router = SystemSTTRouter(backend, sdkInt = 33)

        val route = router.route("ko-KR")

        val expected = SystemSTTRoute.SelfRecord(SystemSTTRecognizer.DEFAULT, "ko-KR", languagePackOffer = true)
        assertEquals(expected, route)
        // Download is triggered only after the user consents.
        assertEquals(emptyList<Pair<SystemSTTRecognizer, String>>(), backend.downloads)
        // Route selection that does not suspend on a cache hit gives the same result.
        assertEquals(expected, router.cachedRoute("ko-KR"))
    }

    @Test
    fun `cannot check support counts as supported routes pipe with the requested tag and is cached`() = runTest {
        val backend = FakeBackend()
        backend.onDeviceAvailable = false
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(cannotCheck = true)
        val router = SystemSTTRouter(backend, sdkInt = 34, nowMs = { 0L })

        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "ko-KR"), router.route("ko-KR"))
        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "ko-KR"), router.cachedRoute("ko-KR"))
        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "ko-KR"), router.route("ko-KR"))
        assertEquals(listOf(SystemSTTRecognizer.DEFAULT to "ko-KR"), backend.checks)
        assertEquals(emptyList<Pair<SystemSTTRecognizer, String>>(), backend.downloads)
    }

    @Test
    fun `sdk 33 nothing supports language self records without download`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(installedOnDevice = listOf("en-US"))
        backend.supports[SystemSTTRecognizer.DEFAULT] = null

        val route = SystemSTTRouter(backend, sdkInt = 33).route("th-TH")

        assertEquals(SystemSTTRoute.SelfRecord(SystemSTTRecognizer.DEFAULT, "th-TH"), route)
        assertEquals(emptyList<Pair<SystemSTTRecognizer, String>>(), backend.downloads)
    }

    @Test
    fun `sdk 32 self records without checking support`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(installedOnDevice = listOf("en-US"))

        val route = SystemSTTRouter(backend, sdkInt = 32).route("en-US")

        assertEquals(SystemSTTRoute.SelfRecord(SystemSTTRecognizer.DEFAULT, "en-US"), route)
        assertEquals(emptyList<Pair<SystemSTTRecognizer, String>>(), backend.checks)
    }

    @Test
    fun `no enabled recognition service is unavailable even if on-device reports available`() = runTest {
        val backend = FakeBackend()
        backend.available = false
        backend.onDeviceAvailable = true
        backend.enabledService = false

        assertEquals(SystemSTTRoute.Unavailable, SystemSTTRouter(backend, sdkInt = 33).route("en-US"))
        assertEquals(SystemSTTRoute.Unavailable, SystemSTTRouter(backend, sdkInt = 28).route("en-US"))
        assertEquals(emptyList<Pair<SystemSTTRecognizer, String>>(), backend.checks)
    }

    @Test
    fun `no recognition service is unavailable`() = runTest {
        val backend = FakeBackend()
        backend.available = false
        backend.onDeviceAvailable = false

        assertEquals(SystemSTTRoute.Unavailable, SystemSTTRouter(backend, sdkInt = 33).route("en-US"))
        assertEquals(SystemSTTRoute.Unavailable, SystemSTTRouter(backend, sdkInt = 28).route("en-US"))
        assertEquals(emptyList<Pair<SystemSTTRecognizer, String>>(), backend.checks)
    }

    @Test
    fun `null language falls back to app ui language`() = runTest {
        val backend = FakeBackend()
        backend.ui = Locale.forLanguageTag("fr-FR")
        backend.onDeviceAvailable = false
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("fr-FR"))

        val route = SystemSTTRouter(backend, sdkInt = 33).route(null)

        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "fr-FR"), route)
        assertEquals(listOf(SystemSTTRecognizer.DEFAULT to "fr-FR"), backend.checks)

        backend.ui = Locale.forLanguageTag("sw-KE")
        assertEquals(
            SystemSTTRoute.SelfRecord(SystemSTTRecognizer.DEFAULT, "en"),
            SystemSTTRouter(backend, sdkInt = 32).route(null),
        )
    }

    @Test
    fun `check support without a callback for two seconds counts as unsupported and routing continues`() = runTest {
        val backend = FakeBackend()
        val silent = CompletableDeferred<SystemSTTSupport?>()
        backend.pending[SystemSTTRecognizer.ON_DEVICE] = silent
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("en-US"))

        val route = SystemSTTRouter(backend, sdkInt = 33).route("en-US")

        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "en-US"), route)
        assertEquals(2_000L, currentTime)
        assertEquals(
            listOf(SystemSTTRecognizer.ON_DEVICE to "en-US", SystemSTTRecognizer.DEFAULT to "en-US"),
            backend.checks,
        )
        // A callback arriving after the timeout does not affect the route already chosen.
        silent.complete(SystemSTTSupport(installedOnDevice = listOf("en-US")))
        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "en-US"), route)
        assertEquals(emptyList<Pair<SystemSTTRecognizer, String>>(), backend.downloads)
    }

    @Test
    fun `all check support timeouts self record`() = runTest {
        val backend = FakeBackend()
        backend.pending[SystemSTTRecognizer.ON_DEVICE] = CompletableDeferred()
        backend.pending[SystemSTTRecognizer.DEFAULT] = CompletableDeferred()

        val route = SystemSTTRouter(backend, sdkInt = 33).route("en-US")

        assertEquals(SystemSTTRoute.SelfRecord(SystemSTTRecognizer.DEFAULT, "en-US"), route)
        assertEquals(4_000L, currentTime)
    }

    @Test
    fun `zh-Hans matches simplified tags written as cmn or by region but not traditional ones`() {
        assertEquals("cmn-Hans-CN", SystemSTTRouter.matchLanguage("zh-Hans", listOf("cmn-Hans-CN")))
        assertEquals("zh-CN", SystemSTTRouter.matchLanguage("zh-Hans", listOf("zh-CN")))
        assertEquals("zh-CN", SystemSTTRouter.matchLanguage("zh-Hans", listOf("cmn-Hant-TW", "zh-TW", "zh-CN")))
        assertEquals("zh_SG", SystemSTTRouter.matchLanguage("zh-Hans", listOf("zh-HK", "zh_SG")))
        assertNull(SystemSTTRouter.matchLanguage("zh-Hans", listOf("cmn-Hant-TW")))
        assertNull(SystemSTTRouter.matchLanguage("zh-Hans", listOf("zh-TW", "zh-HK", "zh-MO")))
        assertEquals("cmn-Hant-TW", SystemSTTRouter.matchLanguage("zh-Hant", listOf("zh-CN", "cmn-Hant-TW")))
        assertEquals("cmn-Hans-CN", SystemSTTRouter.matchLanguage("zh-CN", listOf("cmn-Hant-TW", "cmn-Hans-CN")))
    }

    @Test
    fun `zh-Hans routes through the recognizer listing cmn-Hans-CN`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(installedOnDevice = listOf("cmn-Hant-TW"))
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("zh-TW", "cmn-Hans-CN"))

        val route = SystemSTTRouter(backend, sdkInt = 33).route("zh-Hans")

        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "cmn-Hans-CN"), route)
        assertEquals(emptyList<Pair<SystemSTTRecognizer, String>>(), backend.downloads)
    }

    @Test
    fun `successful support results are cached per language and recognizer for 600 s in the router instance`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(installedOnDevice = listOf("ja-JP"))
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("de-DE", "ja-JP"))
        var now = 0L
        val router = SystemSTTRouter(backend, sdkInt = 34, nowMs = { now })
        val bothForDe = listOf(SystemSTTRecognizer.ON_DEVICE to "de-DE", SystemSTTRecognizer.DEFAULT to "de-DE")

        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "de-DE"), router.route("de-DE"))
        now = 599_999L
        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "de-DE"), router.route("de-DE"))
        assertEquals(bothForDe, backend.checks)

        // Another language is a separate key.
        router.route("ja-JP")
        assertEquals(bothForDe + (SystemSTTRecognizer.ON_DEVICE to "ja-JP"), backend.checks)

        now = 600_000L
        router.route("de-DE")
        assertEquals(bothForDe + (SystemSTTRecognizer.ON_DEVICE to "ja-JP") + bothForDe, backend.checks)

        // The cache follows the router instance.
        SystemSTTRouter(backend, sdkInt = 34, nowMs = { now }).route("ja-JP")
        assertEquals(SystemSTTRecognizer.ON_DEVICE to "ja-JP", backend.checks.last())
        assertEquals(6, backend.checks.size)
    }

    @Test
    fun `failed and timed out support queries are not cached`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = null
        backend.pending[SystemSTTRecognizer.DEFAULT] = CompletableDeferred()
        val router = SystemSTTRouter(backend, sdkInt = 34, nowMs = { 0L })

        router.route("en-US")
        router.route("en-US")

        assertEquals(4, backend.checks.size)
    }

    @Test
    fun `default route offers the language pack when on-device can download but has not installed it`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(downloadableOnDevice = listOf("de-DE"))
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("de-DE"))

        val route = SystemSTTRouter(backend, sdkInt = 34).route("de-DE")

        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "de-DE", languagePackOffer = true), route)
        // Only a hint, no automatic download.
        assertEquals(emptyList<Pair<SystemSTTRecognizer, String>>(), backend.downloads)
    }

    @Test
    fun `no language pack offer when on-device cannot download it or is the chosen route`() = runTest {
        val notDownloadable = FakeBackend()
        notDownloadable.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(downloadableOnDevice = listOf("ja-JP"))
        notDownloadable.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("de-DE"))
        val installed = FakeBackend()
        installed.supports[SystemSTTRecognizer.ON_DEVICE] =
            SystemSTTSupport(installedOnDevice = listOf("de-DE"), downloadableOnDevice = listOf("de-DE"))

        assertEquals(
            SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "de-DE", languagePackOffer = false),
            SystemSTTRouter(notDownloadable, sdkInt = 34).route("de-DE"),
        )
        assertEquals(
            SystemSTTRoute.Pipe(SystemSTTRecognizer.ON_DEVICE, "de-DE", languagePackOffer = false),
            SystemSTTRouter(installed, sdkInt = 34).route("de-DE"),
        )
    }

    @Test
    fun `download language pack triggers the on-device download and drops the cached support`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(downloadableOnDevice = listOf("de-DE"))
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("de-DE"))
        val router = SystemSTTRouter(backend, sdkInt = 34, nowMs = { 0L })
        router.route("de-de")

        assertTrue(router.downloadLanguagePack("de-de"))

        assertEquals(listOf(SystemSTTRecognizer.ON_DEVICE to "de-DE"), backend.downloads)
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(installedOnDevice = listOf("de-DE"))
        assertEquals(SystemSTTRoute.Pipe(SystemSTTRecognizer.ON_DEVICE, "de-DE"), router.route("de-de"))
    }

    @Test
    fun `download language pack is refused when not downloadable on-device unavailable or below sdk 33`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(downloadableOnDevice = listOf("ja-JP"))

        assertEquals(false, SystemSTTRouter(backend, sdkInt = 34).downloadLanguagePack("de-DE"))
        assertEquals(false, SystemSTTRouter(backend, sdkInt = 32).downloadLanguagePack("ja-JP"))
        backend.onDeviceAvailable = false
        assertEquals(false, SystemSTTRouter(backend, sdkInt = 34).downloadLanguagePack("ja-JP"))
        assertEquals(emptyList<Pair<SystemSTTRecognizer, String>>(), backend.downloads)
    }

    @Test
    fun `manifest declares record audio and recognition service queries`() {
        val manifest = File("src/main/AndroidManifest.xml").readText()

        assertTrue(manifest.contains("""<uses-permission android:name="android.permission.RECORD_AUDIO" />"""))
        assertTrue(
            Regex("""<queries>[\s\S]*<action android:name="android\.speech\.RecognitionService" />[\s\S]*</queries>""")
                .containsMatchIn(manifest),
        )
    }

    @Test
    fun `production backend reports error cannot check support as unknown support`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val context = ApplicationProvider.getApplicationContext<Context>()
            val created = mutableListOf<SpeechRecognizer>()
            val backend = AndroidSystemSTTBackend(context, SystemSTTRecognizerGate()) {
                SpeechRecognizer.createSpeechRecognizer(context).also { created += it }
            }

            val support = async { backend.checkSupport(SystemSTTRecognizer.DEFAULT, "ko-KR") }
            runCurrent()
            shadowOf(created.single()).triggerSupportError(SpeechRecognizer.ERROR_CANNOT_CHECK_SUPPORT)
            shadowOf(Looper.getMainLooper()).idle()
            runCurrent()

            assertEquals(SystemSTTSupport(cannotCheck = true), support.await())
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `production backend support check and download go through the recognizer gate one at a time`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val context = ApplicationProvider.getApplicationContext<Context>()
            val gate = SystemSTTRecognizerGate()
            val created = mutableListOf<SpeechRecognizer>()
            val backend = AndroidSystemSTTBackend(context, gate) {
                // The first one must already be destroyed before creating the second.
                assertTrue(created.all { shadowOf(it).isDestroyed })
                SpeechRecognizer.createSpeechRecognizer(context).also { created += it }
            }
            val held = gate.enqueue()

            val support = async { backend.checkSupport(SystemSTTRecognizer.DEFAULT, "fr-FR") }
            advanceTimeBy(10 * 60_000L)
            runCurrent()
            assertEquals(0, created.size)

            held.release()
            runCurrent()
            assertEquals(1, created.size)
            backend.triggerModelDownload(SystemSTTRecognizer.DEFAULT, "fr-FR")
            runCurrent()
            assertEquals(1, created.size)

            shadowOf(created[0]).triggerSupportError(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)
            shadowOf(Looper.getMainLooper()).idle()
            runCurrent()

            assertNull(support.await())
            assertTrue(shadowOf(created[0]).isDestroyed)
            assertEquals(2, created.size)
            val download = shadowOf(created[1])
            assertEquals("fr-FR", download.latestModelDownloadIntent?.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
            assertTrue(download.isDestroyed)
        } finally {
            Dispatchers.resetMain()
        }
    }
}
