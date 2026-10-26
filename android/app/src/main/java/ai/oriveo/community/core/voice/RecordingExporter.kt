package ai.oriveo.community.core.voice

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.muxer.BufferInfo
import androidx.media3.muxer.Mp4Muxer
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import kotlin.math.roundToLong

/** Export failure: the range is out of bounds or empty, or the source file has no complete ADTS frame. */
class RecordingExportException(val reason: Reason, message: String) : IllegalArgumentException(message) {
    enum class Reason { OUT_OF_BOUNDS, EMPTY_RANGE, NO_FRAMES }
}

/**
 * Remuxes a slot's ADTS (.aac) into .m4a without re-encoding: parses the ADTS itself and feeds each frame, header stripped, to Mp4Muxer as one sync sample,
 * with pts = frame index x 1024 / sample rate. A recording-time range can be exported: recording time is first converted to file time by adding primingFrames / sample rate,
 * then all frames covering that range are taken.
 */
object RecordingExporter {

    /**
     * [range] is recording time (seconds, 0 = first valid sample); null exports the whole recording;
     * an out-of-bounds or empty range throws [RecordingExportException], in which case [out] is not created.
     */
    @OptIn(UnstableApi::class)
    fun toM4a(
        aac: File,
        out: File,
        range: ClosedFloatingPointRange<Double>? = null,
        primingFrames: Int = RecordingWriter.DEFAULT_PRIMING_FRAMES,
    ) {
        val frames = AdtsFormat.parse(aac.readBytes()).frames
        if (frames.isEmpty()) {
            throw RecordingExportException(RecordingExportException.Reason.NO_FRAMES, "no complete ADTS frame in $aac")
        }
        val first = frames.first()
        val sampleRate = first.sampleRate
            ?: throw RecordingExportException(
                RecordingExportException.Reason.NO_FRAMES,
                "unsupported sample rate index ${first.sampleRateIndex}",
            )
        val selected = if (range == null) frames.indices else frameIndices(range, frames.size, sampleRate, primingFrames)

        val format = Format.Builder()
            .setSampleMimeType(MimeTypes.AUDIO_AAC)
            .setSampleRate(sampleRate)
            .setChannelCount(first.channelConfig)
            .setInitializationData(listOf(AdtsFormat.audioSpecificConfig(first)))
            .build()

        FileOutputStream(out).use { stream ->
            // Disable the streamable reservation: otherwise about 400 KB of padding is placed before moov, so even a few seconds of recording exports at 400 KB.
            val muxer = Mp4Muxer.Builder(stream).setAttemptStreamableOutputEnabled(false).build()
            try {
                val track = muxer.addTrack(format)
                for ((sampleIndex, frameIndex) in selected.withIndex()) {
                    val payload = frames[frameIndex].payload
                    val ptsUs = sampleIndex.toLong() * AdtsStream.SAMPLES_PER_FRAME * C.MICROS_PER_SECOND / sampleRate
                    muxer.writeSampleData(
                        track,
                        ByteBuffer.wrap(payload),
                        BufferInfo(ptsUs, payload.size, C.BUFFER_FLAG_KEY_FRAME),
                    )
                }
            } finally {
                muxer.close()
            }
        }
    }

    /** Converts recording time to sample positions (adding priming) and snaps to frame boundaries: the start rounds down and the end rounds up. */
    private fun frameIndices(
        range: ClosedFloatingPointRange<Double>,
        frameCount: Int,
        sampleRate: Int,
        primingFrames: Int,
    ): IntRange {
        val start = range.start
        val end = range.endInclusive
        if (!(end > start)) {
            throw RecordingExportException(RecordingExportException.Reason.EMPTY_RANGE, "empty range $range")
        }
        val startSample = (start * sampleRate).roundToLong() + primingFrames
        val endSample = (end * sampleRate).roundToLong() + primingFrames
        val totalSamples = frameCount.toLong() * AdtsStream.SAMPLES_PER_FRAME
        if (start < 0 || endSample > totalSamples) {
            throw RecordingExportException(RecordingExportException.Reason.OUT_OF_BOUNDS, "range $range out of recording")
        }
        val firstFrame = (startSample / AdtsStream.SAMPLES_PER_FRAME).toInt()
        val endFrame = ((endSample + AdtsStream.SAMPLES_PER_FRAME - 1) / AdtsStream.SAMPLES_PER_FRAME).toInt()
        if (endFrame <= firstFrame) {
            throw RecordingExportException(RecordingExportException.Reason.EMPTY_RANGE, "range $range covers no frame")
        }
        return firstFrame until endFrame
    }
}
