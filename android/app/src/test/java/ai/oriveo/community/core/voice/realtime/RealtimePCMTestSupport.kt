package ai.oriveo.community.core.voice.realtime

// PCM helpers used only by tests: the production path only uses the three-argument resample16kTo24k and toLittleEndian.

/** 16 kHz → 24 kHz linear interpolation, output length = n * 3 / 2 (wraps the production three-argument version). */
internal fun RealtimePCM.resample16kTo24k(input: ShortArray): ShortArray {
    val out = ShortArray(input.size * OUTPUT_RATE / INPUT_RATE)
    resample16kTo24k(input, input.size, out)
    return out
}

/** Little-endian PCM16 bytes to samples; a trailing lone byte is dropped. */
internal fun RealtimePCM.fromLittleEndian(bytes: ByteArray): ShortArray = ShortArray(bytes.size / 2) { i ->
    ((bytes[i * 2].toInt() and 0xFF) or (bytes[i * 2 + 1].toInt() shl 8)).toShort()
}
