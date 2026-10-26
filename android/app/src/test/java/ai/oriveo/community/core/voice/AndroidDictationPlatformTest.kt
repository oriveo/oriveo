package ai.oriveo.community.core.voice

import android.Manifest
import android.app.Application
import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.testing.TestSharedPreferences
import java.io.File
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The production [AndroidMicrophonePermission] requester bridge and [AndroidDictationEnvironment] (with a real [ReadAloudController]). */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidDictationPlatformTest {

    private val app = ApplicationProvider.getApplicationContext<Application>()

    private class FakeEngine : SpeechEngine {
        override val engineName = "system"
        var listener: SpeechEngine.Listener? = null

        override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) {
            this.listener = listener
        }

        override fun stop() = Unit
    }

    private class FakeReadAloudEnvironment : ReadAloudEnvironment {
        override fun uiLocale(): Locale = Locale.ENGLISH
        override fun placeholderText(kind: SpeakablePlaceholder, appLocale: String): String = ""
        override fun beginSession(listener: ReadAloudEnvironment.SessionListener): Boolean = true
        override fun endSession() = Unit
        override fun showMessage(resId: Int) = Unit
    }

    @Test
    fun `granted permission skips requester`() = runTest {
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO)
        val permission = AndroidMicrophonePermission(app)
        var launches = 0
        permission.attach { launches++ }

        assertTrue(permission.request())
        assertEquals(0, launches)
    }

    @Test
    fun `no requester counts as denied`() = runTest {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        val permission = AndroidMicrophonePermission(app)

        assertFalse(permission.request())

        // Attached then closed: also counts as denied.
        permission.attach { error("closed requester must not launch") }.close()
        assertFalse(permission.request())
    }

    @Test
    fun `requester result is returned`() = runTest(UnconfinedTestDispatcher()) {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        val permission = AndroidMicrophonePermission(app)
        val firstLaunches = mutableListOf<(Boolean) -> Unit>()
        val secondLaunches = mutableListOf<(Boolean) -> Unit>()
        permission.attach { firstLaunches += it }
        permission.attach { secondLaunches += it }

        val granted = async { permission.request() }
        assertEquals(0, firstLaunches.size)
        assertEquals(1, secondLaunches.size)
        secondLaunches.single()(true)
        assertTrue(granted.await())

        val denied = async { permission.request() }
        secondLaunches.last()(false)
        assertFalse(denied.await())
    }

    @Test
    fun `closing requester while pending resolves denied`() = runTest(UnconfinedTestDispatcher()) {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        val permission = AndroidMicrophonePermission(app)
        val launches = mutableListOf<(Boolean) -> Unit>()
        val handle = permission.attach { launches += it }

        val result = async { permission.request() }
        assertEquals(1, launches.size)
        assertFalse(result.isCompleted)
        handle.close()

        assertFalse(result.await())
        // A callback arriving after close neither changes the result nor throws.
        launches.single()(true)
        assertFalse(permission.request())
    }

    @Test
    fun `pending request survives requester release for config change`() = runTest(UnconfinedTestDispatcher()) {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        val permission = AndroidMicrophonePermission(app)
        val launches = mutableListOf<(Boolean) -> Unit>()
        val handle = permission.attach { launches += it }

        val result = async { permission.request() }
        handle.releaseForConfigChange()
        assertFalse(result.isCompleted)

        // A requester attached after recreation does not re-show the system permission dialog.
        val nextLaunches = mutableListOf<(Boolean) -> Unit>()
        val next = permission.attach { nextLaunches += it }
        assertFalse(result.isCompleted)
        assertEquals(1, launches.size)
        assertTrue(nextLaunches.isEmpty())
        next.close()
        assertFalse(result.await())
    }

    @Test
    fun `result from next requester completes pending request`() = runTest(UnconfinedTestDispatcher()) {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        val permission = AndroidMicrophonePermission(app)
        val handle = permission.attach { }

        val result = async { permission.request() }
        handle.releaseForConfigChange()
        val next = permission.attach { }
        next.onResult(true)

        assertTrue(result.await())
        // The pending request has ended: a late result does not change it.
        next.onResult(false)
        assertTrue(result.await())
    }

    @Test
    fun `close still resolves pending as denied`() = runTest(UnconfinedTestDispatcher()) {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        val permission = AndroidMicrophonePermission(app)
        val handle = permission.attach { }

        val carried = async { permission.request() }
        handle.releaseForConfigChange()
        val next = permission.attach { }
        next.close()
        assertFalse(carried.await())

        // Without an adopting requester, close also ends the pending request as denied.
        val last = permission.attach { }
        val orphan = async { permission.request() }
        last.releaseForConfigChange()
        assertFalse(orphan.isCompleted)
        permission.attach { }.close()
        assertFalse(orphan.await())
    }

    @Test
    fun `launch failure counts as denied`() = runTest(UnconfinedTestDispatcher()) {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        val permission = AndroidMicrophonePermission(app)
        permission.attach { throw IllegalStateException("launcher not registered") }

        assertFalse(permission.request())

        // A failed request leaves nothing behind: after switching to a working requester, results are reported as usual.
        val launches = mutableListOf<(Boolean) -> Unit>()
        permission.attach { launches += it }
        val granted = async { permission.request() }
        launches.single()(true)
        assertTrue(granted.await())
    }

    @Test
    fun `app module wires production dictation controller`() {
        val source = File("src/main/java/ai/oriveo/community/di/AppModule.kt").readText()

        listOf(
            "DictationController(",
            "routeFor = ",
            "asDictationCatalogSource()",
            "RecordingStore.production(",
            "AudioRecordCapture(",
            "AndroidMicrophonePermission(",
        ).forEach { assertTrue("AppModule.kt missing $it", source.contains(it)) }
    }

    @Test
    fun `stop read aloud uses user stopped reason`() {
        val engine = FakeEngine()
        val readAloud = ReadAloudController(
            engine = engine,
            environment = FakeReadAloudEnvironment(),
            scope = CoroutineScope(UnconfinedTestDispatcher()),
        )
        readAloud.toggle("m1", "First sentence. Second sentence.")
        engine.listener!!.onStart(0)
        val environment = AndroidDictationEnvironment(app, readAloud)

        environment.stopReadAloud()

        assertEquals(ReadAloudState.Idle, readAloud.state.value)
    }

    @Test
    @Config(qualifiers = "fr-rFR")
    fun `recognition language follows app locale`() {
        val readAloud = ReadAloudController(
            engine = FakeEngine(),
            environment = FakeReadAloudEnvironment(),
            scope = CoroutineScope(UnconfinedTestDispatcher()),
        )
        val environment = AndroidDictationEnvironment(app, readAloud)

        assertEquals("fr-FR", environment.recognitionLanguage())
    }

    @Test
    @Config(qualifiers = "fr-rFR")
    fun `recognition language prefers saved setting`() {
        val readAloud = ReadAloudController(
            engine = FakeEngine(),
            environment = FakeReadAloudEnvironment(),
            scope = CoroutineScope(UnconfinedTestDispatcher()),
        )
        val settings = VoiceEngineSettings(prefsProvider = { TestSharedPreferences() })
        val environment = AndroidDictationEnvironment(app, readAloud, settings)

        assertEquals("fr-FR", environment.recognitionLanguage())

        settings.setRecognitionLanguage("zh-Hans")
        assertEquals("zh-Hans", environment.recognitionLanguage())

        settings.setRecognitionLanguage(null)
        assertEquals("fr-FR", environment.recognitionLanguage())
    }
}
