package ai.oriveo.community.core.voice

import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A fake engine + fake platform environment drive the production [ReadAloudController]: start/stop, switching messages, finishing, failure, and the stop paths of observeChat. */
@OptIn(ExperimentalCoroutinesApi::class)
class ReadAloudControllerTest {

    private class FakeEngine : SpeechEngine {
        override val engineName = "system"
        val spoken = mutableListOf<List<String>>()
        val locales = mutableListOf<Locale>()
        var listener: SpeechEngine.Listener? = null
        var stops = 0

        override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) {
            spoken += utterances
            locales += locale
            this.listener = listener
        }

        val segmentLocales = mutableListOf<List<Locale>>()

        override fun speak(
            utterances: List<String>,
            locale: Locale,
            segmentLocales: List<Locale>,
            listener: SpeechEngine.Listener,
        ) {
            this.segmentLocales += segmentLocales
            speak(utterances, locale, listener)
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
    private val toasts = mutableListOf<GlobalSnackbarMessage>()

    /** The detector treats env.detected as the only full-score hypothesis. */
    private val envDetector = ReadingLanguageDetector { _ ->
        listOfNotNull(env.detected?.let { LanguageHypothesis(it.toLanguageTag(), 1.0) })
    }
    private val controller = ReadAloudController(
        engine = engine,
        environment = env,
        scope = CoroutineScope(UnconfinedTestDispatcher()),
        languageDetector = envDetector,
        showToast = toasts::add,
    )

    private fun controllerWith(
        source: ReadAloudEngineSource = ReadAloudEngineSource.fixed(engine),
        detector: ReadingLanguageDetector = envDetector,
    ) = ReadAloudController(
        engineSource = source,
        environment = env,
        scope = CoroutineScope(UnconfinedTestDispatcher()),
        languageDetector = detector,
        showToast = toasts::add,
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
    }

    @Test
    fun `toggle another message stops the current one first`() {
        controller.toggle("m1", threeSentences)
        val first = engine.listener!!
        controller.toggle("m2", "Other reply.")

        assertEquals(ReadAloudState.Speaking("m2", 0, 1), controller.state.value)
        assertEquals(1, engine.stops)
        // A late callback from the old session does not affect the new one
        first.onDoneAll()
        assertEquals(ReadAloudState.Speaking("m2", 0, 1), controller.state.value)
    }

    @Test
    fun `finishing all segments returns to idle`() {
        controller.toggle("m1", threeSentences)
        engine.listener!!.onStart(0)
        engine.listener!!.onStart(2)
        engine.listener!!.onDoneAll()

        assertEquals(ReadAloudState.Idle, controller.state.value)
        assertFalse(env.active)
    }

    @Test
    fun `engine error fails the message and shows a toast`() {
        controller.toggle("m1", threeSentences)
        engine.listener!!.onError(SpeechError.FAILED)

        assertEquals(ReadAloudState.Failed("m1"), controller.state.value)
        assertEquals(listOf(R.string.voice_read_aloud_failed), env.messages)

        controller.toggle("m2", "Retry works.")
        engine.listener!!.onError(SpeechError.UNAVAILABLE)
        assertEquals(R.string.voice_tts_unavailable, env.messages.last())
    }

    @Test
    fun `empty speakable text does nothing`() {
        controller.toggle("m1", "---\n🎉 ✨")
        assertEquals(ReadAloudState.Idle, controller.state.value)
        assertTrue(engine.spoken.isEmpty())
    }

    @Test
    fun `placeholder language falls back to ui locale when reading language unsupported`() {
        env.detected = Locale.forLanguageTag("sw")
        controller.toggle("m1", "Habari.\n| a | b |")
        assertEquals(listOf("zh-Hans"), env.placeholderLocales)
    }

    @Test
    fun `placeholder segment uses placeholder locale`() {
        // Old behavior: the whole read carried a single reading-language locale, so a placeholder written in the UI language was also read as Swahili
        env.detected = Locale.forLanguageTag("sw")
        controller.toggle("m1", "Habari.\n| a | b |")
        assertEquals(listOf(Locale.forLanguageTag("sw")), engine.locales)
        assertEquals(listOf(listOf(Locale.forLanguageTag("sw"), env.ui)), engine.segmentLocales)
    }

    @Test
    fun `observeChat stops on conversation change`() {
        controller.observeChat("c1", null)
        controller.toggle("m1", threeSentences)
        controller.observeChat("c1", null)
        assertTrue(controller.state.value is ReadAloudState.Speaking)
        controller.observeChat("c2", null)

        assertEquals(ReadAloudState.Idle, controller.state.value)
    }

    @Test
    fun `stopIfSpeaking only stops the spoken message`() {
        controller.toggle("m1", threeSentences)
        controller.stopIfSpeaking("m2")
        assertTrue(controller.state.value is ReadAloudState.Speaking)
        controller.stopIfSpeaking("m1")

        assertEquals(ReadAloudState.Idle, controller.state.value)
    }

    @Test
    fun `observeChat stops when a new generation starts streaming`() {
        controller.observeChat("c1", null)
        controller.toggle("m1", threeSentences)
        controller.observeChat("c1", "m2")

        assertEquals(ReadAloudState.Idle, controller.state.value)
    }

    @Test
    fun `denied audio focus fails`() {
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

        controller.toggle("m1", threeSentences)
        env.listener!!.onBackgrounded()
        assertEquals(ReadAloudState.Idle, controller.state.value)
    }

    @Test
    fun `cloud fallback toasts provider name once per read`() {
        val cloud = object : SpeechEngine {
            override val engineName = CloudSpeechEngine.ENGINE_NAME
            var listener: SpeechEngine.Listener? = null
            override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) {
                this.listener = listener
            }
            override fun stop() = Unit
        }
        val cloudController = controllerWith(source = { ReadAloudEngineChoice(cloud, "openai") })
        val expected = GlobalSnackbarMessage(
            UiText.Resource(R.string.voice_read_aloud_cloud_fallback, listOf("OpenAI")),
            style = GlobalToastStyle.Warning,
        )

        cloudController.toggle("m1", threeSentences)
        assertTrue(toasts.isEmpty())
        cloud.listener!!.onFallback("OpenAI")
        cloud.listener!!.onFallback("OpenAI")
        assertEquals(listOf(expected), toasts)

        // Counted afresh on the next read-aloud
        cloudController.stop()
        cloudController.toggle("m1", threeSentences)
        cloud.listener!!.onFallback("OpenAI")
        assertEquals(listOf(expected, expected), toasts)
        assertTrue(env.messages.isEmpty())
    }

    @Test
    fun `use site fallback toasts engine unavailable`() {
        val fallbackController = controllerWith(
            source = { ReadAloudEngineChoice(engine, "system", VoiceFallbackReason.KeyMissing) },
        )

        fallbackController.toggle("m1", threeSentences)

        assertEquals(
            listOf(
                GlobalSnackbarMessage(
                    UiText.Resource(R.string.voice_read_aloud_engine_fallback),
                    style = GlobalToastStyle.Warning,
                ),
            ),
            toasts,
        )
        assertEquals(1, engine.spoken.size)

        // No fallback reason, no toast
        controller.toggle("m2", threeSentences)
        assertEquals(1, toasts.size)
    }

    @Test
    fun `detected language drives locale`() {
        val detecting = controllerWith(
            detector = {
                listOf(
                    LanguageHypothesis("en", 0.3),
                    LanguageHypothesis("ja", 0.9),
                    LanguageHypothesis("fr", 0.9),
                )
            },
        )

        detecting.toggle("m1", "Bonjour.\n| a | b |")

        // On a tie the lexicographically smaller one wins
        assertEquals(listOf(Locale.forLanguageTag("fr")), engine.locales)
        assertEquals(listOf("fr"), env.placeholderLocales)
    }

    @Test
    fun `language detection reads speakable sentences not raw markdown`() {
        val inputs = mutableListOf<String>()
        val detecting = controllerWith(detector = { text -> inputs += text; listOf(LanguageHypothesis("fr", 0.9)) })

        // Old behavior: the detector got the raw markdown (heading hashes, code block text), so code-heavy replies were judged as English
        detecting.toggle("m1", "# Title\n\n```kotlin\nval x = 1\n```\nDone.")
        assertEquals(listOf("Title Done."), inputs)
        assertEquals(listOf(Locale.forLanguageTag("fr")), engine.locales)

        // No speakable sentences (placeholders only): no detection, use the UI locale
        detecting.toggle("m2", "```kotlin\nval x = 1\n```")
        assertEquals(1, inputs.size)
        assertEquals(env.ui, engine.locales.last())

        // First 2000 code points, without splitting a surrogate pair
        val long = languageDetectionInput(listOf(SpeakableSegment.Sentence("\uD83D\uDE00".repeat(1999)), SpeakableSegment.Sentence("ab")))
        assertEquals(2000, long.codePointCount(0, long.length))
        assertEquals("\uD83D\uDE00".repeat(1999) + " ", long)
    }

    @Test
    fun `low confidence uses ui locale`() {
        controllerWith(detector = { listOf(LanguageHypothesis("ja", 0.49)) }).toggle("m1", threeSentences)
        controllerWith(detector = ReadingLanguageDetector.NONE).toggle("m2", threeSentences)

        assertEquals(listOf(env.ui, env.ui), engine.locales)
    }
}
