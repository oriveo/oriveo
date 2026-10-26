package ai.oriveo.community.core.voice.live

import android.content.Context
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.voice.MediaCodecAacEncoder
import ai.oriveo.community.core.voice.RecordingWriter
import ai.oriveo.community.core.voice.STTSegment
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogDecoder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Shared plumbing for the voice live (real key) instrumentation suites.
 * Gate: instrumentation arg `voiceLive` = comma separated groups. Keys come from filesDir/voice-live/keys.json and are
 * never printed, put into assertion messages or written anywhere; audio from filesDir/voice-live/audio/.
 */
object VoiceLive {
    const val TAG = "VoiceLive"
    const val END = "android"
    private const val GROUP_ARG = "voiceLive"
    private const val CATALOG_ASSET = "voice_catalog_contract.v2.json"
    private const val SAMPLE_RATE = 16_000
    private const val PCM_CHUNK = 1_024

    // Price table (contract item 6).
    private const val GPT_TRANSCRIBE_USD_PER_MIN = 0.0045
    private const val XAI_STT_USD_PER_HOUR = 0.10
    private const val TTS_USD_PER_CHAR = 15.0 / 1_000_000

    val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    /** Plain return in callers instead of Assume: the connected-test XML reports assumption failures as failures. */
    fun enabled(group: String): Boolean =
        InstrumentationRegistry.getArguments().getString(GROUP_ARG)
            ?.split(',')
            ?.map { it.trim() }
            ?.contains(group) == true

    private val root: File get() = File(context.filesDir, "voice-live")

    /** Key by name (openAI / grok / siliconFlow / gemini); null when missing or blank. */
    fun key(name: String): String? {
        val file = File(root, "keys.json")
        if (!file.isFile) return null
        val obj = Json.parseToJsonElement(file.readText()) as? JsonObject ?: return null
        return runCatching { obj[name]?.jsonPrimitive?.content }.getOrNull()?.trim()?.takeIf { it.isNotEmpty() }
    }

    val audioDir: File get() = File(root, "audio")

    data class Clip(val file: String, val lang: String, val text: String, val durationSec: Double)

    fun clips(): List<Clip> {
        val manifest = Json.parseToJsonElement(File(audioDir, "manifest.json").readText()).jsonObject
        return manifest.getValue("clips").jsonObject.map { (name, value) ->
            val obj = value.jsonObject
            Clip(
                file = name,
                lang = obj.getValue("lang").jsonPrimitive.content,
                text = obj.getValue("text").jsonPrimitive.content,
                durationSec = obj.getValue("durationSec").jsonPrimitive.doubleOrNull ?: 0.0,
            )
        }
    }

    /** Catalog decoded by the production decoder from the debug assets copy of the shared contract. */
    fun catalog(): VoiceCatalog {
        val text = context.assets.open(CATALOG_ASSET).use { it.readBytes().decodeToString() }
        return VoiceCatalogDecoder.decode(Json.parseToJsonElement(text).jsonObject["data"])
    }

    /** 16 kHz mono 16-bit WAV → samples (walks RIFF chunks). */
    fun readWav(file: File): ShortArray {
        val wav = file.readBytes()
        val bytes = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
        require(String(wav, 0, 4, Charsets.US_ASCII) == "RIFF" && String(wav, 8, 4, Charsets.US_ASCII) == "WAVE") {
            "not a WAVE file: ${file.name}"
        }
        var at = 12
        while (at + 8 <= wav.size) {
            val id = String(wav, at, 4, Charsets.US_ASCII)
            val length = bytes.getInt(at + 4)
            val body = at + 8
            if (id == "fmt ") {
                val channels = bytes.getShort(body + 2).toInt()
                val rate = bytes.getInt(body + 4)
                val bits = bytes.getShort(body + 14).toInt()
                require(channels == 1 && rate == SAMPLE_RATE && bits == 16) {
                    "expected 16 kHz mono 16-bit, got $channels/$rate/$bits"
                }
            } else if (id == "data") {
                val count = minOf(length, wav.size - body) / 2
                return ShortArray(count) { bytes.getShort(body + it * 2) }
            }
            at = body + length + (length and 1)
        }
        error("no data chunk in ${file.name}")
    }

    /** Encodes a WAV through the production recording path (MediaCodec AAC → ADTS slot file + envelope). */
    fun recordSegment(wav: File, slotDir: File): STTSegment {
        val samples = readWav(wav)
        slotDir.mkdirs()
        val aac = File(slotDir, wav.nameWithoutExtension + ".aac").apply { delete() }
        val writer = RecordingWriter(aac, MediaCodecAacEncoder())
        try {
            var offset = 0
            while (offset < samples.size) {
                val count = minOf(PCM_CHUNK, samples.size - offset)
                writer.write(samples.copyOfRange(offset, offset + count), count)
                offset += count
            }
        } finally {
            writer.close()
        }
        return STTSegment(aac = aac, primingFrames = writer.primingFrames, envelope = writer.envelope)
    }

    fun sttUsd(model: String, seconds: Double): Double = when {
        model == "gpt-transcribe" -> seconds / 60 * GPT_TRANSCRIBE_USD_PER_MIN
        model.startsWith("grok") -> seconds / 3600 * XAI_STT_USD_PER_HOUR
        model.contains("SenseVoice") -> 0.0
        else -> error("no price for stt model $model")
    }

    fun ttsUsd(text: String): Double = text.length * TTS_USD_PER_CHAR

    /** Per-process spend guard: a sample that would exceed [limitUsd] is not sent. */
    class Budget(private val limitUsd: Double) {
        var spentUsd: Double = 0.0
            private set

        @Synchronized
        fun reserve(estUsd: Double): Boolean {
            if (spentUsd + estUsd > limitUsd) return false
            spentUsd += estUsd
            return true
        }
    }

    /** One evidence line per sample (contract item 5). [detail] must never contain a key. */
    fun evidence(item: String, provider: String, model: String, ok: Boolean, ms: Long?, detail: String, estUsd: Double) {
        val json = buildJsonObject {
            put("end", END)
            put("item", item)
            put("provider", provider)
            put("model", model)
            put("ok", ok)
            put("ms", ms)
            put("detail", detail)
            put("estUsd", estUsd)
        }
        Log.i(TAG, "VOICE-LIVE $json")
    }
}
