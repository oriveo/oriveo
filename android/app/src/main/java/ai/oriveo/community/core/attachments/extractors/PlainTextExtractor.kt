package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables.BIG5
import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables.EUC_KR
import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables.GB18030
import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables.SHIFT_JIS
import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables.WINDOWS_1251
import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables.WINDOWS_1252
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/**
 * Plain-text decoding, spec section 4 (the same deterministic algorithm on all three platforms, no third-party detection library):
 * BOM -> NUL bytes decide UTF-16 / binary -> strict UTF-8 -> score six candidates -> strictly decode the whole file in rank order.
 * Output only does the plain-text part of section 3.1: drop the BOM, `\r\n` / `\r` -> `\n`; no trim, no blank-line squeezing.
 */
object PlainTextExtractor {
    private const val NUL_PROBE_BYTES = 4096
    private const val SAMPLE_BYTES = 65536

    /**
     * @param uiLanguage a value from spec section 1 (zh-Hans / zh-Hant / ja / ko / ru / others as en), only used for tie-breaking.
     * @throws ExtractionException decoding fails after the BOM -> corrupted_file; binary -> unsupported_format.
     */
    @Throws(ExtractionException::class)
    fun extract(data: ByteArray, uiLanguage: String = "en"): String =
        decode(data, uiLanguage).replace("\r\n", "\n").replace('\r', '\n')

    /**
     * Spec section 8 "decode": BOM first; otherwise strictly decode with the declared encoding (one of [LegacyCharsetTables.candidates] or `utf-8`);
     * no declaration or strict decoding fails -> the algorithm of section 4. Line breaks as in [extract].
     */
    @Throws(ExtractionException::class)
    internal fun decodeDeclared(data: ByteArray, declared: String?, uiLanguage: String): String {
        if (declared != null && bom(data) == null) {
            val text = if (declared == UTF_8_LABEL) strictDecode(Charsets.UTF_8, data) else decodeWhole(declared, data)
            if (text != null) return text.replace("\r\n", "\n").replace('\r', '\n')
        }
        return extract(data, uiLanguage)
    }

    /** Decoders for multibyte candidates on this platform (Android column of the spec section 4 decoder table); single-byte candidates use the tables in [LegacyCharsetTables]. */
    internal fun legacyCharset(candidate: String): Charset? = multiByteCharset(candidate)

    const val UTF_8_LABEL = "utf-8"

    private fun decode(data: ByteArray, uiLanguage: String): String {
        if (data.isEmpty()) return ""

        // 1. BOM: after removing it, strictly decode the whole file with that encoding.
        bom(data)?.let { (charset, bomLength) ->
            return strictDecode(charset, data, bomLength, data.size - bomLength)
                ?: throw ExtractionException(ExtractionErrorCode.CorruptedFile, "invalid_${charset.name()}")
        }

        // 2. NUL bytes: look only at the first 4096 bytes, judge UTF-16LE / BE by position parity; if both appear, it is binary.
        var nulAtOdd = false
        var nulAtEven = false
        for (index in 0 until minOf(data.size, NUL_PROBE_BYTES)) {
            if (data[index].toInt() == 0) {
                if (index % 2 == 1) nulAtOdd = true else nulAtEven = true
            }
        }
        if (nulAtOdd || nulAtEven) {
            if (nulAtOdd && nulAtEven) throw ExtractionException(ExtractionErrorCode.UnsupportedFormat, "binary")
            val charset = if (nulAtOdd) Charsets.UTF_16LE else Charsets.UTF_16BE
            return strictDecode(charset, data)
                ?: throw ExtractionException(ExtractionErrorCode.UnsupportedFormat, "binary")
        }

        // 3. Strict UTF-8 (pure ASCII also succeeds here).
        strictDecode(Charsets.UTF_8, data)?.let { return it }

        // 4. Score candidates; 5. strictly decode the whole file in rank order, the first success is the result.
        for (candidate in rankCandidates(data, uiLanguage)) {
            decodeWhole(candidate, data)?.let { return it }
        }
        // The two single-byte candidates always decode, so this is unreachable.
        return decodeSingleByte(data, LegacyCharsetTables.windows1252High)
    }

    /** Spec section 4 step 4: surviving candidates by score descending; on equal scores the UI-language candidate first, then candidate order. */
    internal fun rankCandidates(data: ByteArray, uiLanguage: String): List<String> {
        val sample = if (data.size > SAMPLE_BYTES) data.copyOf(SAMPLE_BYTES) else data
        val sampleIsPartial = sample.size < data.size
        val preferred = LegacyCharsetTables.localeTieBreak[uiLanguage]
        return LegacyCharsetTables.candidates
            .mapIndexedNotNull { order, name ->
                val charset = multiByteCharset(name)
                if (name in MULTI_BYTE && (charset == null || !sampleDecodes(charset, sample, sampleIsPartial))) {
                    null
                } else {
                    Triple(name, order, score(name, sample))
                }
            }
            .sortedWith(
                compareByDescending<Triple<String, Int, Double>> { it.third }
                    .thenBy { if (it.first == preferred) 0 else 1 }
                    .thenBy { it.second },
            )
            .map { it.first }
    }

    internal fun score(candidate: String, sample: ByteArray): Double = when (candidate) {
        GB18030 -> scoreGb18030(sample)
        BIG5 -> scoreDoubleByte(sample, LegacyCharsetTables.commonChars.getValue(BIG5)) { lead, _ ->
            when (lead) {
                in 0xA4..0xC6 -> 1
                in 0xA1..0xA3, in 0xC9..0xF9 -> 0
                in 0xC7..0xC8 -> -1
                else -> -2
            }
        }
        EUC_KR -> scoreDoubleByte(sample, LegacyCharsetTables.commonChars.getValue(EUC_KR)) { lead, trail ->
            when {
                lead in 0xB0..0xC8 && trail in 0xA1..0xFE -> 1
                (lead in 0xA1..0xAC || lead in 0xCA..0xFD) && trail in 0xA1..0xFE -> 0
                else -> -1
            }
        }
        SHIFT_JIS -> scoreShiftJis(sample)
        WINDOWS_1252 -> score1252(sample)
        WINDOWS_1251 -> score1251(sample)
        else -> 0.0
    }

    private fun scoreGb18030(sample: ByteArray): Double {
        val common = LegacyCharsetTables.commonChars.getValue(GB18030)
        var score = 0.0
        var index = 0
        while (index < sample.size) {
            val lead = sample.u(index)
            if (lead < 0x80) {
                index++
                continue
            }
            if (index + 1 >= sample.size) break
            val trail = sample.u(index + 1)
            if (trail in 0x30..0x39) {
                // Skip the whole four-byte sequence; an incomplete one at the end of the sample is not counted.
                if (index + 3 >= sample.size) break
                score -= 2
                index += 4
                continue
            }
            score += when {
                lead in 0xB0..0xD7 && trail in 0xA1..0xFE -> 1
                (lead in 0xA1..0xA9 || lead in 0xD8..0xF7) && trail in 0xA1..0xFE -> 0
                else -> -1
            }
            if ((lead shl 8 or trail) in common) score += 3
            index += 2
        }
        return score
    }

    private fun scoreShiftJis(sample: ByteArray): Double {
        val common = LegacyCharsetTables.commonChars.getValue(SHIFT_JIS)
        var score = 0.0
        var index = 0
        while (index < sample.size) {
            val lead = sample.u(index)
            if (lead < 0x80) {
                index++
                continue
            }
            if (lead in 0xA1..0xDF) {
                // Single-byte half-width katakana.
                score -= 1
                index++
                continue
            }
            if (index + 1 >= sample.size) break
            val code = lead shl 8 or sample.u(index + 1)
            score += when {
                code in 0x829F..0x82F1 || code in 0x8340..0x8396 || code in 0x889F..0x9872 -> 1
                code in 0x989F..0xEAA4 || lead in 0x81..0x84 -> 0
                lead in 0xF0..0xF9 -> -2
                else -> -1
            }
            if (code in common) score += 3
            index += 2
        }
        return score
    }

    private inline fun scoreDoubleByte(sample: ByteArray, common: Set<Int>, range: (Int, Int) -> Int): Double {
        var score = 0.0
        var index = 0
        while (index < sample.size) {
            val lead = sample.u(index)
            if (lead < 0x80) {
                index++
                continue
            }
            if (index + 1 >= sample.size) break
            val trail = sample.u(index + 1)
            score += range(lead, trail)
            if ((lead shl 8 or trail) in common) score += 3
            index += 2
        }
        return score
    }

    private fun score1252(sample: ByteArray): Double {
        var score = 0.0
        for (index in sample.indices) {
            val byte = sample.u(index)
            if (byte < 0x80) continue
            val prev = if (index > 0) sample.u(index - 1) else ABSENT
            val next = if (index + 1 < sample.size) sample.u(index + 1) else ABSENT
            val prevHigh = prev >= 0x80
            val nextHigh = next >= 0x80
            when {
                is1252Letter(byte) -> score += when {
                    prevHigh && nextHigh -> -1
                    isAsciiLetter(prev) || isAsciiLetter(next) || (!prevHigh && !nextHigh) -> 1
                    else -> 0
                }
                byte == 0xBF || byte == 0xA1 ->
                    if (next != ABSENT && next < 0x80 && prev < 0x80) score += 2
                byte in LegacyCharsetTables.punct1252 ->
                    if (!prevHigh && !nextHigh) score += 1
            }
        }
        return score
    }

    private fun score1251(sample: ByteArray): Double {
        var score = 0.0
        for (index in sample.indices) {
            val byte = sample.u(index)
            if (byte < 0x80) continue
            val prev = if (index > 0) sample.u(index - 1) else ABSENT
            val next = if (index + 1 < sample.size) sample.u(index + 1) else ABSENT
            if (isAsciiLetter(prev) || isAsciiLetter(next)) {
                score -= 1
                continue
            }
            when {
                byte >= 0xE0 -> score += 1
                byte >= 0xC0 -> score += when {
                    prev in 0xE0..0xFF -> -1.0
                    prev in 0xC0..0xDF && next in 0xE0..0xFF -> -1.0
                    else -> 0.5
                }
                byte !in LegacyCharsetTables.ok1251 -> score -= 2
            }
        }
        return score
    }

    private fun is1252Letter(byte: Int): Boolean =
        (byte in 0xC0..0xFF && byte != 0xD7 && byte != 0xF7) || byte in LETTERS_1252_80_9F

    private fun isAsciiLetter(byte: Int): Boolean = byte in 0x41..0x5A || byte in 0x61..0x7A

    /** Strictly decode the sample; when the sample is shorter than the whole file, allow a multibyte character truncated at the end, retrying after dropping 1, 2, 3 bytes in turn. */
    private fun sampleDecodes(charset: Charset, sample: ByteArray, sampleIsPartial: Boolean): Boolean {
        if (strictDecode(charset, sample) != null) return true
        if (!sampleIsPartial) return false
        return (1..3).any { drop -> sample.size > drop && strictDecode(charset, sample, 0, sample.size - drop) != null }
    }

    private fun decodeWhole(candidate: String, data: ByteArray): String? = when (candidate) {
        WINDOWS_1252 -> decodeSingleByte(data, LegacyCharsetTables.windows1252High)
        WINDOWS_1251 -> decodeSingleByte(data, LegacyCharsetTables.windows1251High)
        else -> multiByteCharset(candidate)?.let { strictDecode(it, data) }
    }

    private fun decodeSingleByte(data: ByteArray, high: CharArray): String =
        String(CharArray(data.size) { index -> data.u(index).let { if (it < 0x80) it.toChar() else high[it - 0x80] } })

    /** Android column of the spec section 4 decoder table; candidates the platform lacks count as eliminated. */
    private fun multiByteCharset(candidate: String): Charset? = when (candidate) {
        GB18030 -> charsetOrNull("GB18030")
        SHIFT_JIS -> charsetOrNull("windows-31j")
        BIG5 -> charsetOrNull("Big5-HKSCS")
        EUC_KR -> charsetOrNull("x-windows-949") ?: charsetOrNull("EUC-KR")
        else -> null
    }

    private fun charsetOrNull(name: String): Charset? =
        runCatching { if (Charset.isSupported(name)) Charset.forName(name) else null }.getOrNull()

    /** Strict = illegal sequences throw, not replaced by U+FFFD. */
    internal fun strictDecode(charset: Charset, data: ByteArray, offset: Int = 0, length: Int = data.size): String? =
        try {
            charset.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(data, offset, length))
                .toString()
        } catch (_: CharacterCodingException) {
            null
        }

    private fun bom(data: ByteArray): Pair<Charset, Int>? = when {
        data.size >= 3 && data.u(0) == 0xEF && data.u(1) == 0xBB && data.u(2) == 0xBF -> Charsets.UTF_8 to 3
        data.size >= 2 && data.u(0) == 0xFF && data.u(1) == 0xFE -> Charsets.UTF_16LE to 2
        data.size >= 2 && data.u(0) == 0xFE && data.u(1) == 0xFF -> Charsets.UTF_16BE to 2
        else -> null
    }

    private fun ByteArray.u(index: Int): Int = this[index].toInt() and 0xFF

    private const val ABSENT = -1
    private val MULTI_BYTE = setOf(GB18030, SHIFT_JIS, BIG5, EUC_KR)
    private val LETTERS_1252_80_9F = setOf(0x8A, 0x8C, 0x8E, 0x9A, 0x9C, 0x9E, 0x9F)
}
