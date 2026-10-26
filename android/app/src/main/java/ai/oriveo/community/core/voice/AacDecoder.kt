package ai.oriveo.community.core.voice

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Decodes a slot's .aac into 16 kHz mono PCM_16BIT (little-endian bytes) so the system recognizer can re-recognize from the file. */
interface AacDecoder {
    /**
     * Hands PCM bytes to [sink] chunk by chunk, stopping early when [sink] returns false. [range] is the time range to decode (seconds, null = everything),
     * taken in file time without skipping the leading priming frames (the recognizer does not mind the roughly 0.1 s of leading silence). Throws IOException if the file cannot be read or decoding fails.
     */
    @Throws(IOException::class)
    fun decode(file: File, range: ClosedFloatingPointRange<Double>?, sink: (ByteArray) -> Boolean)
}

/** Production [AacDecoder]: MediaExtractor reads the ADTS frames and MediaCodec decodes them; multi-channel audio is averaged per frame into mono. */
class MediaCodecAacDecoder : AacDecoder {
    override fun decode(file: File, range: ClosedFloatingPointRange<Double>?, sink: (ByteArray) -> Boolean) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(file.path)
            val track = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith(AUDIO_MIME_PREFIX) == true
            } ?: throw IOException("no audio track in ${file.name}")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: throw IOException("audio track without mime")
            val startUs = range?.start?.let { (it * MICROS_PER_SECOND).toLong() } ?: 0L
            val endUs = range?.endInclusive?.let { (it * MICROS_PER_SECOND).toLong() } ?: Long.MAX_VALUE
            if (startUs > 0) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()
            drain(extractor, decoder, format, endUs, sink)
        } catch (error: IOException) {
            throw error
        } catch (error: RuntimeException) {
            // Platform exceptions such as MediaCodec.CodecException are all treated as decode failures.
            throw IOException("aac decode failed: ${error.message}", error)
        } finally {
            codec?.let { runCatching { it.stop() }; runCatching { it.release() } }
            extractor.release()
        }
    }

    private fun drain(
        extractor: MediaExtractor,
        codec: MediaCodec,
        inputFormat: MediaFormat,
        endUs: Long,
        sink: (ByteArray) -> Boolean,
    ) {
        val info = MediaCodec.BufferInfo()
        var output = PcmShape.of(inputFormat)
        var inputDone = false
        while (true) {
            if (!inputDone) {
                val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                if (inIndex >= 0) {
                    val buffer = codec.getInputBuffer(inIndex) ?: throw IOException("no input buffer")
                    val size = extractor.readSampleData(buffer, 0)
                    val timeUs = extractor.sampleTime
                    if (size < 0 || timeUs > endUs) {
                        codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inIndex, 0, size, timeUs, 0)
                        extractor.advance()
                    }
                }
            }
            val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                output = PcmShape.of(codec.outputFormat)
                continue
            }
            if (outIndex < 0) continue
            val endOfStream = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            val bytes = if (info.size > 0) {
                output.check()
                val buffer = codec.getOutputBuffer(outIndex) ?: throw IOException("no output buffer")
                buffer.position(info.offset)
                buffer.limit(info.offset + info.size)
                toMonoLittleEndian(buffer, output.channels)
            } else {
                null
            }
            codec.releaseOutputBuffer(outIndex, false)
            if (bytes != null && !sink(bytes)) return
            if (endOfStream) return
        }
    }

    /** Channel count, sample rate and encoding of the decoder output; only 16 kHz, 16-bit integer PCM is accepted. */
    private data class PcmShape(val channels: Int, val sampleRate: Int, val encoding: Int) {
        fun check() {
            if (sampleRate != AudioRecordCapture.SAMPLE_RATE) throw IOException("unexpected sample rate $sampleRate")
            if (encoding != AudioFormat.ENCODING_PCM_16BIT) throw IOException("unexpected pcm encoding $encoding")
            if (channels < 1) throw IOException("unexpected channel count $channels")
        }

        companion object {
            fun of(format: MediaFormat) = PcmShape(
                channels = format.intOr(MediaFormat.KEY_CHANNEL_COUNT, 1),
                sampleRate = format.intOr(MediaFormat.KEY_SAMPLE_RATE, AudioRecordCapture.SAMPLE_RATE),
                encoding = format.intOr(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT),
            )

            private fun MediaFormat.intOr(key: String, fallback: Int): Int =
                if (containsKey(key)) getInteger(key) else fallback
        }
    }

    private companion object {
        const val AUDIO_MIME_PREFIX = "audio/"
        const val MICROS_PER_SECOND = 1_000_000.0
        const val TIMEOUT_US = 10_000L

        /** Decoder output is interleaved 16-bit samples in native byte order; multi-channel audio is averaged and emitted uniformly as little-endian mono. */
        fun toMonoLittleEndian(buffer: ByteBuffer, channels: Int): ByteArray {
            val samples = buffer.order(ByteOrder.nativeOrder()).asShortBuffer()
            val frames = samples.remaining() / channels
            val out = ByteArray(frames * 2)
            for (frame in 0 until frames) {
                var sum = 0
                for (channel in 0 until channels) sum += samples.get(frame * channels + channel)
                val sample = sum / channels
                out[frame * 2] = sample.toByte()
                out[frame * 2 + 1] = (sample shr 8).toByte()
            }
            return out
        }
    }
}
