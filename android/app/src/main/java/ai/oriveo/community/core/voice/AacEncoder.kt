package ai.oriveo.community.core.voice

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import java.nio.ByteOrder

/** A unit produced by the encoder: a raw AU; when [isCodecConfig] is true it is the AudioSpecificConfig and is not written to disk. */
class AacEncodedUnit(val data: ByteArray, val isCodecConfig: Boolean)

/** 16 kHz mono 16-bit PCM -> AAC-LC raw AUs. */
interface AacEncoder {
    /** Feeds [count] samples and returns the units produced so far (possibly empty). */
    fun encode(samples: ShortArray, count: Int): List<AacEncodedUnit>

    /** Sends EOS, drains the encoder and returns the remaining units. */
    fun finish(): List<AacEncodedUnit>

    /** The delay (in samples) the encoder reports in its outputFormat; null if it does not report one. */
    val encoderDelay: Int?

    fun release()
}

/** MediaCodec implementation; delay is read from KEY_ENCODER_DELAY in the outputFormat (API 30+). */
class MediaCodecAacEncoder(
    sampleRate: Int = SAMPLE_RATE,
    channelCount: Int = CHANNEL_COUNT,
    bitRate: Int = BIT_RATE,
) : AacEncoder {
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private val info = MediaCodec.BufferInfo()
    private var queuedSamples = 0L
    private val sampleRateHz = sampleRate

    override var encoderDelay: Int? = null
        private set

    init {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channelCount).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
        }
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
        } catch (error: Exception) {
            codec.release()
            throw error
        }
    }

    override fun encode(samples: ShortArray, count: Int): List<AacEncodedUnit> {
        val out = mutableListOf<AacEncodedUnit>()
        var offset = 0
        while (offset < count) {
            val index = codec.dequeueInputBuffer(TIMEOUT_US)
            if (index < 0) {
                drain(out, untilEndOfStream = false)
                continue
            }
            val buffer = codec.getInputBuffer(index) ?: continue
            buffer.clear()
            buffer.order(ByteOrder.nativeOrder())
            val n = minOf(count - offset, buffer.remaining() / BYTES_PER_SAMPLE)
            buffer.asShortBuffer().put(samples, offset, n)
            codec.queueInputBuffer(index, 0, n * BYTES_PER_SAMPLE, presentationTimeUs(), 0)
            queuedSamples += n
            offset += n
            drain(out, untilEndOfStream = false)
        }
        return out
    }

    override fun finish(): List<AacEncodedUnit> {
        val out = mutableListOf<AacEncodedUnit>()
        var index = codec.dequeueInputBuffer(TIMEOUT_US)
        while (index < 0) {
            drain(out, untilEndOfStream = false)
            index = codec.dequeueInputBuffer(TIMEOUT_US)
        }
        codec.queueInputBuffer(index, 0, 0, presentationTimeUs(), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drain(out, untilEndOfStream = true)
        return out
    }

    override fun release() {
        runCatching { codec.stop() }
        codec.release()
    }

    private fun presentationTimeUs(): Long = queuedSamples * 1_000_000L / sampleRateHz

    private fun drain(out: MutableList<AacEncodedUnit>, untilEndOfStream: Boolean) {
        var idleTries = 0
        while (true) {
            val index = codec.dequeueOutputBuffer(info, if (untilEndOfStream) TIMEOUT_US else 0)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!untilEndOfStream || ++idleTries >= MAX_IDLE_TRIES) return
                }
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> readEncoderDelay(codec.outputFormat)
                index >= 0 -> {
                    idleTries = 0
                    val buffer = codec.getOutputBuffer(index)
                    if (buffer != null && info.size > 0) {
                        val bytes = ByteArray(info.size)
                        buffer.position(info.offset)
                        buffer.get(bytes)
                        val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        out += AacEncodedUnit(bytes, config)
                    }
                    val endOfStream = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    codec.releaseOutputBuffer(index, false)
                    if (endOfStream) return
                }
            }
        }
    }

    private fun readEncoderDelay(format: MediaFormat) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && format.containsKey(MediaFormat.KEY_ENCODER_DELAY)) {
            encoderDelay = format.getInteger(MediaFormat.KEY_ENCODER_DELAY)
        }
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        const val CHANNEL_COUNT = 1
        const val BIT_RATE = 32_000
        private const val BYTES_PER_SAMPLE = 2
        private const val TIMEOUT_US = 10_000L
        private const val MAX_IDLE_TRIES = 100
    }
}
