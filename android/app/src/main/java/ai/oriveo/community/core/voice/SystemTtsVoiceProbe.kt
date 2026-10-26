package ai.oriveo.community.core.voice

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Same as TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED: voice data not downloaded. */
const val TTS_FEATURE_NOT_INSTALLED = "notInstalled"

/** Voice quality threshold, same as Voice.QUALITY_HIGH. */
private const val TTS_QUALITY_HIGH = 300

/** Voice description independent of the platform Voice, to make pure-function tests easy. */
data class TtsVoiceInfo(
    val locale: Locale,
    val quality: Int,
    val networkRequired: Boolean,
    val features: Set<String>,
)

/**
 * Whether system read-aloud should show the "download more natural voices" hint:
 * filter by UI language (same language counts) and exclude uninstalled voices; none left -> no hint;
 * none that is both high quality and usable offline -> show the hint.
 */
fun ttsHintNeeded(voices: List<TtsVoiceInfo>, locale: Locale): Boolean {
    val candidates = voices.filter {
        it.locale.language == locale.language && TTS_FEATURE_NOT_INSTALLED !in it.features
    }
    if (candidates.isEmpty()) return false
    return candidates.none { it.quality >= TTS_QUALITY_HIGH && !it.networkRequired }
}

interface SystemTtsVoiceProbe {
    suspend fun hintNeeded(locale: Locale): Boolean
}

/** Platform implementation: temporarily creates a TextToSpeech to read voices, then shuts it down; exceptions / init failure / timeout mean no hint. */
class AndroidSystemTtsVoiceProbe(
    context: Context,
    private val timeoutMillis: Long = 5_000,
) : SystemTtsVoiceProbe {
    private val appContext = context.applicationContext

    override suspend fun hintNeeded(locale: Locale): Boolean {
        val voices = withTimeoutOrNull(timeoutMillis) { loadVoices() } ?: return false
        return ttsHintNeeded(voices, locale)
    }

    private suspend fun loadVoices(): List<TtsVoiceInfo>? = withContext(Dispatchers.Main) {
        suspendCancellableCoroutine { cont ->
            val lock = Any()
            var engine: TextToSpeech? = null
            var initStatus: Int? = null
            fun finish(tts: TextToSpeech, status: Int) {
                val result = if (status == TextToSpeech.SUCCESS) {
                    runCatching { tts.voices.orEmpty().map(Voice::toInfo) }.getOrNull()
                } else {
                    null
                }
                runCatching { tts.shutdown() }
                if (cont.isActive) cont.resume(result)
            }
            val created = runCatching {
                TextToSpeech(appContext) { status ->
                    // The callback may fire before the constructor returns
                    val tts = synchronized(lock) {
                        initStatus = status
                        engine
                    }
                    if (tts != null) finish(tts, status)
                }
            }.getOrNull()
            if (created == null) {
                cont.resume(null)
                return@suspendCancellableCoroutine
            }
            val early = synchronized(lock) {
                engine = created
                initStatus
            }
            if (early != null) finish(created, early)
            cont.invokeOnCancellation { runCatching { created.shutdown() } }
        }
    }
}

private fun Voice.toInfo() = TtsVoiceInfo(
    locale = locale,
    quality = quality,
    networkRequired = isNetworkConnectionRequired,
    features = features.orEmpty(),
)
