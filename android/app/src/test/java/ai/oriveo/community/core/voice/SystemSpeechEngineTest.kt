package ai.oriveo.community.core.voice

import android.content.Context
import android.speech.tts.TextToSpeech
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

/** The production [SystemSpeechEngine] with a fake TextToSpeech factory: rebuilding after an initialization failure. */
class SystemSpeechEngineTest {

    private class RecordingListener : SpeechEngine.Listener {
        val errors = mutableListOf<SpeechError>()
        override fun onStart(index: Int) = Unit
        override fun onDoneAll() = Unit
        override fun onError(error: SpeechError) {
            errors += error
        }
    }

    @Test
    fun `init error during construction then next speak reports unavailable`() {
        val context = mockk<Context>(relaxed = true)
        every { context.applicationContext } returns context
        val created = mutableListOf<TextToSpeech>()
        // With no system TTS engine, the TextToSpeech constructor synchronously calls onInit(ERROR)
        val engine = SystemSpeechEngine(context, ttsFactory = { _, listener ->
            listener.onInit(TextToSpeech.ERROR)
            mockk<TextToSpeech>(relaxed = true).also { created += it }
        })

        val first = RecordingListener()
        engine.speak(listOf("Hello."), Locale.ENGLISH, first)
        val second = RecordingListener()
        engine.speak(listOf("Hello again."), Locale.ENGLISH, second)

        assertEquals(listOf(SpeechError.UNAVAILABLE), first.errors)
        // Old behavior: the failed instance stayed in tts, the second speak neither rebuilt nor called back, and read-aloud got stuck in Speaking
        assertEquals(listOf(SpeechError.UNAVAILABLE), second.errors)
        assertEquals(2, created.size)
        created.forEach { verify { it.shutdown() } }
    }
}
