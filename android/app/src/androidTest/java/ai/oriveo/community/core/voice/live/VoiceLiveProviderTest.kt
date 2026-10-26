package ai.oriveo.community.core.voice.live

import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.CloudSTTEngine
import ai.oriveo.community.core.voice.DefaultReadAloudEngineFactory
import ai.oriveo.community.core.voice.STTResult
import ai.oriveo.community.core.voice.SpeechAudioCache
import ai.oriveo.community.core.voice.SpeechEngine
import ai.oriveo.community.core.voice.SpeechError
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceSttEntry
import ai.oriveo.community.core.voice.VoiceTtsEntry
import io.ktor.client.HttpClient
import java.io.File
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.koin.mp.KoinPlatform

/**
 * Voice live, group `provider`: production CloudSTTEngine on clip-en / clip-zh per STT provider and production
 * CloudSpeechEngine (DefaultReadAloudEngineFactory wiring) for one sentence per TTS provider, against real keys.
 * Each item passes with one ok sample; spend is capped at [LIMIT_USD] for the whole class.
 */
@RunWith(AndroidJUnit4::class)
class VoiceLiveProviderTest {
    private val httpClient: HttpClient get() = KoinPlatform.getKoin().get()
    private val context get() = VoiceLive.context

    @Test
    fun sttOpenAI() = stt(ProviderKind.OpenAI, "openAI", OPENAI_BASE) { catalog ->
        catalog.entry(ProviderKind.OpenAI, VoiceDirection.Stt, "gpt-transcribe") as? VoiceSttEntry
    }

    @Test
    fun sttGrok() = stt(ProviderKind.Grok, "grok", GROK_BASE) { catalog ->
        catalog.provider(ProviderKind.Grok).stt.firstOrNull { it.isDefault }
    }

    @Test
    fun sttSiliconFlow() = stt(ProviderKind.SiliconFlow, "siliconFlow", SILICONFLOW_BASE) { catalog ->
        catalog.entry(ProviderKind.SiliconFlow, VoiceDirection.Stt, "FunAudioLLM/SenseVoiceSmall") as? VoiceSttEntry
    }

    @Test
    fun ttsOpenAI() = tts(ProviderKind.OpenAI, "openAI", OPENAI_BASE, "OpenAI") { catalog ->
        catalog.provider(ProviderKind.OpenAI).tts.firstOrNull { it.isDefault }
    }

    @Test
    fun ttsGrok() = tts(ProviderKind.Grok, "grok", GROK_BASE, "xAI") { catalog ->
        catalog.entry(ProviderKind.Grok, VoiceDirection.Tts, "xai-tts") as? VoiceTtsEntry
    }

    private fun stt(
        kind: ProviderKind,
        keyName: String,
        baseUrl: String,
        pick: (ai.oriveo.community.core.voice.VoiceCatalog) -> VoiceSttEntry?,
    ) {
        if (!VoiceLive.enabled(GROUP)) return
        val entry = pick(VoiceLive.catalog())
        assertNotNull("catalog has no stt entry for ${kind.rawValue}", entry)
        val apiKey = VoiceLive.key(keyName) ?: return fail("missing key $keyName in voice-live/keys.json")
        val engine = CloudSTTEngine(httpClient, entry!!, baseUrl, apiKey, File(context.cacheDir, "voice-live-stt"))
        var okCount = 0
        for (clip in VoiceLive.clips()) {
            val item = "stt"
            val est = VoiceLive.sttUsd(entry.model, clip.durationSec)
            if (!budget.reserve(est)) {
                VoiceLive.evidence(item, kind.rawValue, entry.model, false, null, "budget exceeded ${clip.file}", est)
                fail("estimated spend would exceed $LIMIT_USD USD")
            }
            val segment = VoiceLive.recordSegment(File(VoiceLive.audioDir, clip.file), File(context.cacheDir, "voice-live-slot"))
            val start = SystemClock.elapsedRealtime()
            val result = runBlocking { engine.transcribe(segment, clip.lang) }
            val ms = SystemClock.elapsedRealtime() - start
            segment.aac.delete()
            val (ok, detail) = when (result) {
                is STTResult.Success -> {
                    val hit = keyword(clip.lang).let { result.text.contains(it, ignoreCase = true) }
                    hit to "${clip.file} text=${result.text}"
                }
                is STTResult.Failed -> false to "${clip.file} failed=${result.failure}"
            }
            if (ok) okCount++
            VoiceLive.evidence(item, kind.rawValue, entry.model, ok, ms, detail, est)
        }
        assertTrue("stt ${kind.rawValue} ${entry.model}: no ok sample", okCount > 0)
    }

    private fun tts(
        kind: ProviderKind,
        keyName: String,
        baseUrl: String,
        displayName: String,
        pick: (ai.oriveo.community.core.voice.VoiceCatalog) -> VoiceTtsEntry?,
    ) {
        if (!VoiceLive.enabled(GROUP)) return
        val entry = pick(VoiceLive.catalog())
        assertNotNull("catalog has no tts entry for ${kind.rawValue}", entry)
        val apiKey = VoiceLive.key(keyName) ?: return fail("missing key $keyName in voice-live/keys.json")
        val est = VoiceLive.ttsUsd(SENTENCE)
        if (!budget.reserve(est)) {
            VoiceLive.evidence("tts", kind.rawValue, entry!!.model, false, null, "budget exceeded", est)
            fail("estimated spend would exceed $LIMIT_USD USD")
        }
        // Fresh cache dir so the sample is always a real request.
        val cacheDir = File(context.cacheDir, "voice-live-tts-${kind.rawValue}").apply { deleteRecursively() }
        val fallback = NoopSystemEngine()
        val factory = DefaultReadAloudEngineFactory(
            httpClient = httpClient,
            cache = SpeechAudioCache(cacheDir),
            systemEngine = fallback,
            speechRate = { 1.0 },
        )
        val engine = factory.cloud(entry!!, kind, baseUrl, apiKey, null, displayName)
        val firstAudioMs = AtomicLong(-1)
        val error = AtomicReference<String?>(null)
        val done = CountDownLatch(1)
        val start = SystemClock.elapsedRealtime()
        engine.speak(
            listOf(SENTENCE),
            Locale.US,
            object : SpeechEngine.Listener {
                override fun onStart(index: Int) {
                    firstAudioMs.compareAndSet(-1, SystemClock.elapsedRealtime() - start)
                }

                override fun onDoneAll() = done.countDown()

                override fun onError(error: SpeechError) {
                    errorOnce(error.name)
                    done.countDown()
                }

                override fun onFallback(providerDisplayName: String) {
                    errorOnce("fallback")
                }

                private fun errorOnce(reason: String) {
                    error.compareAndSet(null, reason)
                }
            },
        )
        val finished = done.await(TTS_TIMEOUT_SEC, TimeUnit.SECONDS)
        engine.stop()
        val bytes = cacheDir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
        val ms = firstAudioMs.get().takeIf { it >= 0 }
        val reason = error.get() ?: if (fallback.used) "fallback" else if (!finished) "timeout" else null
        val ok = reason == null && ms != null && bytes > 0
        val detail = "chars=${SENTENCE.length} bytes=$bytes format=${entry.outputFormat}" +
            (reason?.let { " error=$it" } ?: "")
        VoiceLive.evidence("tts", kind.rawValue, entry.model, ok, ms, detail, est)
        cacheDir.deleteRecursively()
        assertTrue("tts ${kind.rawValue} ${entry.model}: no ok sample ($detail)", ok)
    }

    /** Stands in for the system engine so a cloud failure shows up as a fallback instead of being masked. */
    private class NoopSystemEngine : SpeechEngine {
        @Volatile
        var used = false
            private set

        override val engineName: String = "system"

        override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) {
            used = true
            listener.onDoneAll()
        }

        override fun stop() = Unit
    }

    private fun keyword(lang: String): String = if (lang.startsWith("zh")) "\u62a5\u544a" else "bread"

    private companion object {
        const val GROUP = "provider"
        const val LIMIT_USD = 0.05
        const val TTS_TIMEOUT_SEC = 60L
        const val SENTENCE = "This is a short read aloud check from the Oriveo live test."
        const val OPENAI_BASE = "https://api.openai.com/v1"
        const val GROK_BASE = "https://api.x.ai/v1"
        const val SILICONFLOW_BASE = "https://api.siliconflow.cn"
        val budget = VoiceLive.Budget(LIMIT_USD)
    }
}
