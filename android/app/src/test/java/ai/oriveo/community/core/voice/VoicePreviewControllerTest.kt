package ai.oriveo.community.core.voice

import ai.oriveo.community.R
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A fake engine + fake platform environment drive the production [VoicePreviewController]: preview, stop on the same voice, switching voices, interruption, no fallback on failure, mutual exclusion with read-aloud. */
@OptIn(ExperimentalCoroutinesApi::class)
class VoicePreviewControllerTest {

    private class FakeEngine(override val engineName: String = "cloud") : SpeechEngine {
        val spoken = mutableListOf<Pair<List<String>, Locale>>()
        var listener: SpeechEngine.Listener? = null
        var stops = 0

        override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) {
            spoken += utterances to locale
            this.listener = listener
        }

        override fun stop() {
            stops++
        }
    }

    private class FakeEnvironment : ReadAloudEnvironment {
        var ui: Locale = Locale.forLanguageTag("zh-CN")
        var listener: ReadAloudEnvironment.SessionListener? = null
        var active = false
        val messages = mutableListOf<Int>()

        override fun uiLocale(): Locale = ui
        override fun placeholderText(kind: SpeakablePlaceholder, appLocale: String): String = kind.rawValue
        override fun beginSession(listener: ReadAloudEnvironment.SessionListener): Boolean {
            this.listener = listener
            active = true
            return true
        }

        override fun endSession() {
            active = false
        }

        override fun showMessage(resId: Int) {
            messages += resId
        }
    }

    private val env = FakeEnvironment()
    private val engines = mutableMapOf<String, FakeEngine>()
    private val requested = mutableListOf<String>()
    private var unavailable = false
    private var readAloudStops = 0

    private val source = VoicePreviewEngineSource { voiceId ->
        requested += voiceId
        if (unavailable) null else FakeEngine().also { engines[voiceId] = it }
    }

    private val preview = VoicePreviewController(
        engineSource = source,
        environment = env,
        sampleText = { "Sample" },
        stopReadAloud = { readAloudStops++ },
        scope = CoroutineScope(UnconfinedTestDispatcher()),
    )

    @Test
    fun `tap plays sample with voice`() {
        preview.toggle("alloy")

        assertEquals(listOf("alloy"), requested)
        assertEquals(listOf(listOf("Sample") to Locale.forLanguageTag("zh-CN")), engines.getValue("alloy").spoken)
        assertEquals("alloy", preview.previewing.value)
        assertTrue(env.active)
        assertEquals(1, readAloudStops)

        engines.getValue("alloy").listener!!.onDoneAll()
        assertNull(preview.previewing.value)
        assertFalse(env.active)
    }

    @Test
    fun `tap same voice stops`() {
        preview.toggle("alloy")
        preview.toggle("alloy")

        assertNull(preview.previewing.value)
        assertEquals(1, engines.getValue("alloy").stops)
        assertEquals(listOf("alloy"), requested)
        assertFalse(env.active)
    }

    @Test
    fun `tap other voice switches`() {
        preview.toggle("alloy")
        preview.toggle("echo")

        assertEquals(1, engines.getValue("alloy").stops)
        assertEquals(listOf(listOf("Sample") to Locale.forLanguageTag("zh-CN")), engines.getValue("echo").spoken)
        assertEquals("echo", preview.previewing.value)
        assertTrue(env.active)

        // A late callback from a stopped old voice does not affect the new preview.
        engines.getValue("alloy").listener!!.onDoneAll()
        assertEquals("echo", preview.previewing.value)
    }

    @Test
    fun `interruption stops`() {
        preview.toggle("alloy")
        env.listener!!.onInterrupted()
        assertNull(preview.previewing.value)
        assertEquals(1, engines.getValue("alloy").stops)
        assertFalse(env.active)

        preview.toggle("echo")
        env.listener!!.onBackgrounded()
        assertNull(preview.previewing.value)
        assertEquals(1, engines.getValue("echo").stops)

        preview.toggle("fable")
        preview.stop()
        assertNull(preview.previewing.value)
        assertEquals(1, engines.getValue("fable").stops)
        assertTrue(env.messages.isEmpty())
    }

    @Test
    fun `failure toasts and does not fall back`() {
        preview.toggle("alloy")
        engines.getValue("alloy").listener!!.onError(SpeechError.FAILED)

        assertNull(preview.previewing.value)
        assertEquals(listOf(R.string.voice_preview_failed), env.messages)
        assertEquals(1, engines.size)
        assertEquals(1, engines.getValue("alloy").spoken.size)

        unavailable = true
        preview.toggle("echo")
        assertNull(preview.previewing.value)
        assertEquals(listOf(R.string.voice_preview_failed, R.string.voice_preview_failed), env.messages)
        assertFalse(env.active)
    }

    @Test
    fun `preview stops read aloud and read aloud stops preview`() {
        val readEngine = FakeEngine("system")
        val readEnv = FakeEnvironment()
        lateinit var linkedPreview: VoicePreviewController
        val readAloud = ReadAloudController(
            engine = readEngine,
            environment = readEnv,
            scope = CoroutineScope(UnconfinedTestDispatcher()),
            beforeStart = { linkedPreview.stop() },
        )
        linkedPreview = VoicePreviewController(
            engineSource = source,
            environment = env,
            sampleText = { "Sample" },
            stopReadAloud = { readAloud.stop(ReadAloudEndReason.USER_STOPPED) },
            scope = CoroutineScope(UnconfinedTestDispatcher()),
        )

        readAloud.toggle("m1", "Hello there.")
        assertTrue(readAloud.state.value is ReadAloudState.Speaking)

        linkedPreview.toggle("alloy")
        assertEquals(ReadAloudState.Idle, readAloud.state.value)
        assertEquals(1, readEngine.stops)
        assertEquals("alloy", linkedPreview.previewing.value)

        readAloud.toggle("m1", "Hello there.")
        assertNull(linkedPreview.previewing.value)
        assertEquals(1, engines.getValue("alloy").stops)
        assertTrue(readAloud.state.value is ReadAloudState.Speaking)
    }
}
