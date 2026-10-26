package ai.oriveo.community.core.voice

import java.io.File
import java.util.Locale
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Drives the production [SystemSTTRouter] with a fake recognizer backend and an injected sdkInt. */
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
    fun `sdk 33 only on-device downloadable triggers one download and self records`() = runTest {
        val backend = FakeBackend()
        backend.supports[SystemSTTRecognizer.ON_DEVICE] = SystemSTTSupport(downloadableOnDevice = listOf("ko-KR"))
        backend.supports[SystemSTTRecognizer.DEFAULT] = SystemSTTSupport(online = listOf("en-US"))

        val route = SystemSTTRouter(backend, sdkInt = 33).route("ko-KR")

        assertEquals(SystemSTTRoute.SelfRecord(SystemSTTRecognizer.DEFAULT, "ko-KR"), route)
        assertEquals(listOf(SystemSTTRecognizer.ON_DEVICE to "ko-KR"), backend.downloads)
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
    fun `manifest declares record audio and recognition service queries`() {
        val manifest = File("src/main/AndroidManifest.xml").readText()

        assertTrue(manifest.contains("""<uses-permission android:name="android.permission.RECORD_AUDIO" />"""))
        assertTrue(
            Regex("""<queries>[\s\S]*<action android:name="android\.speech\.RecognitionService" />[\s\S]*</queries>""")
                .containsMatchIn(manifest),
        )
    }
}
