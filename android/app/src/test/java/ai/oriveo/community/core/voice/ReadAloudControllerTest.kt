package ai.oriveo.community.core.voice

import ai.oriveo.community.R
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Drives the production [ReadAloudController] with a fake engine and platform: start/stop, switching, finishing, failures and the automatic stops. */
@OptIn(ExperimentalCoroutinesApi::class)
class ReadAloudControllerTest {

    private class FakeEngine : SpeechEngine {
        val spoken = mutableListOf<List<String>>()
        val locales = mutableListOf<Locale>()
        var listener: SpeechEngine.Listener? = null
        var stops = 0

        override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) {
            spoken += utterances
            locales += locale
            this.listener = listener
        }

        override fun stop() {
            stops++
        }
    }

    private class FakeEnvironment : ReadAloudEnvironment {
        var detected: Locale? = Locale.ENGLISH
        var ui: Locale = Locale.forLanguageTag("zh-CN")
        var listener: ReadAloudEnvironment.SessionListener? = null
        var active = false
        var focusGranted = true
        val messages = mutableListOf<Int>()
        val placeholderLocales = mutableListOf<String>()

        override fun uiLocale(): Locale = ui
        override suspend fun detectLanguage(text: String): Locale? = detected
        override fun placeholderText(kind: SpeakablePlaceholder, appLocale: String): String {
            placeholderLocales += appLocale
            return "[${kind.rawValue}@$appLocale]"
        }

        override fun beginSession(listener: ReadAloudEnvironment.SessionListener): Boolean {
            this.listener = listener
            active = true
            return focusGranted
        }

        override fun endSession() {
            active = false
        }

        override fun showMessage(resId: Int) {
            messages += resId
        }
    }

    private val engine = FakeEngine()
    private val env = FakeEnvironment()
    private val controller = ReadAloudController(
        engine = engine,
        environment = env,
        scope = CoroutineScope(UnconfinedTestDispatcher()),
    )

    private val threeSentences = "First sentence. Second sentence. Third sentence."

    @Test
    fun `toggle starts speaking with segments`() {
        controller.toggle("m1", "# Title\n\n```kotlin\nval x = 1\n```\nDone.")

        assertEquals(ReadAloudState.Speaking("m1", 0, 3), controller.state.value)
        assertEquals(listOf(listOf("Title", "[code@en]", "Done.")), engine.spoken)
        assertEquals(listOf(Locale.ENGLISH), engine.locales)
        assertTrue(env.active)
        engine.listener!!.onStart(1)
        assertEquals(ReadAloudState.Speaking("m1", 1, 3), controller.state.value)
    }

    @Test
    fun `toggle same message stops`() {
        controller.toggle("m1", threeSentences)
        engine.listener!!.onStart(0)
        controller.toggle("m1", threeSentences)

        assertEquals(ReadAloudState.Idle, controller.state.value)
        assertFalse(env.active)
        assertEquals(1, engine.stops)
        assertEquals(1, engine.spoken.size)
    }

    @Test
    fun `toggle another message stops the current one first`() {
        controller.toggle("m1", threeSentences)
        val first = engine.listener!!
        controller.toggle("m2", "Other reply.")

        assertEquals(ReadAloudState.Speaking("m2", 0, 1), controller.state.value)
        assertEquals(1, engine.stops)
        assertEquals(2, engine.spoken.size)
        // A late callback from the old session does not affect the new one
        first.onDoneAll()
        assertEquals(ReadAloudState.Speaking("m2", 0, 1), controller.state.value)
        assertTrue(env.active)
    }

    @Test
    fun `finishing all segments returns to idle`() {
        controller.toggle("m1", threeSentences)
        engine.listener!!.onStart(0)
        engine.listener!!.onStart(2)
        engine.listener!!.onDoneAll()

        assertEquals(ReadAloudState.Idle, controller.state.value)
        assertFalse(env.active)
        assertTrue(env.messages.isEmpty())
    }

    @Test
    fun `engine error fails the message and shows a toast`() {
        controller.toggle("m1", threeSentences)
        engine.listener!!.onError(SpeechError.FAILED)

        assertEquals(ReadAloudState.Failed("m1"), controller.state.value)
        assertEquals(listOf(R.string.voice_read_aloud_failed), env.messages)
        assertFalse(env.active)

        controller.toggle("m2", "Retry works.")
        engine.listener!!.onError(SpeechError.UNAVAILABLE)
        assertEquals(R.string.voice_tts_unavailable, env.messages.last())
    }

    @Test
    fun `empty speakable text does nothing`() {
        controller.toggle("m1", "---\n🎉 ✨")
        assertEquals(ReadAloudState.Idle, controller.state.value)
        assertTrue(engine.spoken.isEmpty())
        assertFalse(env.active)
    }

    @Test
    fun `placeholder language falls back to ui locale when reading language unsupported`() {
        env.detected = Locale.forLanguageTag("sw")
        controller.toggle("m1", "Habari.\n| a | b |")
        assertEquals(listOf("zh-Hans"), env.placeholderLocales)
    }

    @Test
    fun `observeChat stops on conversation change`() {
        controller.observeChat("c1", null)
        controller.toggle("m1", threeSentences)
        controller.observeChat("c1", null)
        assertTrue(controller.state.value is ReadAloudState.Speaking)
        controller.observeChat("c2", null)

        assertEquals(ReadAloudState.Idle, controller.state.value)
        assertEquals(1, engine.stops)
        assertFalse(env.active)
    }

    @Test
    fun `stopIfSpeaking only stops the spoken message`() {
        controller.toggle("m1", threeSentences)
        controller.stopIfSpeaking("m2")
        assertTrue(controller.state.value is ReadAloudState.Speaking)
        controller.stopIfSpeaking("m1")

        assertEquals(ReadAloudState.Idle, controller.state.value)
        assertEquals(1, engine.stops)
    }

    @Test
    fun `observeChat stops when a new generation starts streaming`() {
        controller.observeChat("c1", null)
        controller.toggle("m1", threeSentences)
        controller.observeChat("c1", "m2")

        assertEquals(ReadAloudState.Idle, controller.state.value)
        assertFalse(env.active)
    }

    @Test
    fun `denied audio focus fails without speaking`() {
        env.focusGranted = false
        controller.toggle("m1", threeSentences)

        assertEquals(ReadAloudState.Failed("m1"), controller.state.value)
        assertEquals(listOf(R.string.voice_read_aloud_failed), env.messages)
        assertTrue(engine.spoken.isEmpty())
        assertFalse(env.active)
    }

    @Test
    fun `platform interruption and backgrounding end the session`() {
        controller.toggle("m1", threeSentences)
        env.listener!!.onInterrupted()
        assertEquals(ReadAloudState.Idle, controller.state.value)
        assertFalse(env.active)

        controller.toggle("m1", threeSentences)
        env.listener!!.onBackgrounded()
        assertEquals(ReadAloudState.Idle, controller.state.value)
        assertFalse(env.active)
        assertEquals(2, engine.stops)
    }
}
