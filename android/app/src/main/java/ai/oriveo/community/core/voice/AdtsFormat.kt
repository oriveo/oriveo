package ai.oriveo.community.core.voice

/** One frame in ADTS: [offset] is the position of the frame header in the file and [payload] is the AU with the header (including CRC) removed. */
class AdtsFrame(
    val offset: Int,
    val headerLength: Int,
    val frameLength: Int,
    /** ADTS profile field (object type - 1, LC = 1). */
    val profile: Int,
    val sampleRateIndex: Int,
    val channelConfig: Int,
    val payload: ByteArray,
) {
    val sampleRate: Int? get() = AdtsFormat.SAMPLE_RATES.getOrNull(sampleRateIndex)
}

/** Parse result: contains complete frames only; sample rate and channels come from the first frame and are null for an empty stream. */
class AdtsStream(val frames: List<AdtsFrame>) {
    val sampleRate: Int? get() = frames.firstOrNull()?.sampleRate
    val channelCount: Int? get() = frames.firstOrNull()?.channelConfig

    /** Duration (seconds) = frame count x 1024 / sample rate; null when the sample rate is unknown. */
    val durationSeconds: Double?
        get() = sampleRate?.let { frames.size * SAMPLES_PER_FRAME.toDouble() / it }

    companion object {
        const val SAMPLES_PER_FRAME = 1024
    }
}

/**
 * Pure functions for the ADTS frame format: writing frame headers (as AOSP AACWriter does), parsing ADTS files, and reconstructing the AudioSpecificConfig from a frame header
 * (as AOSP MakeAACCodecSpecificData does).
 */
object AdtsFormat {
    const val HEADER_LENGTH = 7
    private const val HEADER_LENGTH_WITH_CRC = 9
    private const val PROFILE_LC = 1
    private const val SAMPLE_RATE_INDEX_16K = 8
    private const val CHANNEL_MONO = 1
    private const val BUFFER_FULLNESS_VBR = 0x7FF
    private const val MAX_FRAME_LENGTH = 0x1FFF

    val SAMPLE_RATES = listOf(
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
    )

    /**
     * 7-byte ADTS header: syncword 0xFFF, ID=0 (MPEG-4), layer 0, protection_absent=1, LC, 16 kHz, mono,
     * frame_length = 7 + AU, buffer_fullness 0x7FF, and the raw-data-block-count field 0.
     */
    fun header(auLength: Int): ByteArray {
        val frameLength = HEADER_LENGTH + auLength
        require(auLength >= 0 && frameLength <= MAX_FRAME_LENGTH) { "AU length out of range: $auLength" }
        val profile = PROFILE_LC
        val sf = SAMPLE_RATE_INDEX_16K
        val ch = CHANNEL_MONO
        return byteArrayOf(
            0xFF.toByte(),
            0xF1.toByte(),
            ((profile shl 6) or (sf shl 2) or (ch shr 2)).toByte(),
            (((ch and 0x3) shl 6) or (frameLength shr 11)).toByte(),
            ((frameLength shr 3) and 0xFF).toByte(),
            (((frameLength and 0x7) shl 5) or (BUFFER_FULLNESS_VBR shr 6)).toByte(),
            (((BUFFER_FULLNESS_VBR and 0x3F) shl 2) or 0).toByte(),
        )
    }

    /** Parses sequentially from the start, supporting ID 0/1 and 9-byte headers with CRC; stops at an incomplete frame or loss of sync without throwing. */
    fun parse(bytes: ByteArray): AdtsStream {
        val frames = mutableListOf<AdtsFrame>()
        var offset = 0
        while (offset + HEADER_LENGTH <= bytes.size) {
            val b0 = bytes[offset].u()
            val b1 = bytes[offset + 1].u()
            if (b0 != 0xFF || (b1 and 0xF0) != 0xF0) break
            val protectionAbsent = b1 and 0x1
            val headerLength = if (protectionAbsent == 1) HEADER_LENGTH else HEADER_LENGTH_WITH_CRC
            val b2 = bytes[offset + 2].u()
            val b3 = bytes[offset + 3].u()
            val b4 = bytes[offset + 4].u()
            val b5 = bytes[offset + 5].u()
            val frameLength = ((b3 and 0x3) shl 11) or (b4 shl 3) or (b5 shr 5)
            if (frameLength < headerLength || offset + frameLength > bytes.size) break
            frames += AdtsFrame(
                offset = offset,
                headerLength = headerLength,
                frameLength = frameLength,
                profile = b2 shr 6,
                sampleRateIndex = (b2 shr 2) and 0xF,
                channelConfig = ((b2 and 0x1) shl 2) or (b3 shr 6),
                payload = bytes.copyOfRange(offset + headerLength, offset + frameLength),
            )
            offset += frameLength
        }
        return AdtsStream(frames)
    }

    /** 2-byte AudioSpecificConfig: `((profile+1)<<3)|(sf>>1)`, `((sf<<7)&0x80)|(ch<<3)`. */
    fun audioSpecificConfig(frame: AdtsFrame): ByteArray {
        val sf = frame.sampleRateIndex
        return byteArrayOf(
            (((frame.profile + 1) shl 3) or (sf shr 1)).toByte(),
            (((sf shl 7) and 0x80) or (frame.channelConfig shl 3)).toByte(),
        )
    }

    private fun Byte.u(): Int = toInt() and 0xFF
}
