package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionDeadline
import ai.oriveo.community.core.attachments.ExtractionException
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/**
 * RTF extraction, attachment extraction spec section 11: the same hand-written tokenizer on all three platforms (modeled on python striprtf),
 * deadline checked once per 64 KB of input (section 14), finally section 3.1 normalization.
 */
object RtfTextExtractor {
    @Throws(ExtractionException::class)
    fun extract(data: ByteArray, deadline: ExtractionDeadline = ExtractionDeadline()): String =
        StructuredText.normalize(RtfParser(data, deadline).run())
}

private class RtfParser(private val data: ByteArray, private val deadline: ExtractionDeadline) {

    /** Group state: copied from the outer group on entry, restored on exit. */
    private data class Group(
        var ucSkip: Int = 1,
        var ignore: Boolean = false,
        var font: Int? = null,
        var hidden: Boolean = false,
        var fontTable: Boolean = false,
        var upr: Boolean = false,
    )

    private class FontDef(var charset: Int? = null, var cpg: Int? = null)

    private val stack = ArrayList<Group>()
    private val fonts = HashMap<Int, FontDef>()
    private var fontDef: Int? = null
    private var defaultFont: Int? = null
    private var ansiCpg = 1252

    private var groupStart = false
    private var skip = 0

    private val out = StringBuilder()
    private val bytes = ByteArrayOutputStream()
    private var bytesCodepage = 1252

    private var pos = 0

    fun run(): String {
        var nextCheck = 0
        while (pos < data.size) {
            if (pos >= nextCheck) {
                deadline.check()
                nextCheck = pos + CHECK_INTERVAL_BYTES
            }
            val byte = data[pos].toInt() and 0xFF
            if (stack.isEmpty() && byte != '{'.code) {
                // Content before the outermost group does not count as body.
                pos++
                continue
            }
            when (byte) {
                '{'.code -> {
                    pos++
                    openGroup()
                }
                '}'.code -> {
                    pos++
                    if (closeGroup()) break
                }
                '\\'.code -> controlToken()
                CR, LF -> pos++
                else -> {
                    pos++
                    plainByte(byte)
                }
            }
        }
        flushBytes()
        return replaceLoneSurrogates(out)
    }

    private val group: Group get() = stack.last()

    private fun openGroup() {
        skip = 0
        flushBytes()
        stack += stack.lastOrNull()?.copy() ?: Group()
        groupStart = true
    }

    /** @return the outermost group has ended (content after it is ignored). */
    private fun closeGroup(): Boolean {
        skip = 0
        flushBytes()
        stack.removeAt(stack.lastIndex)
        groupStart = false
        return stack.isEmpty()
    }

    private fun controlToken() {
        if (pos + 1 >= data.size) {
            pos++
            return
        }
        val next = data[pos + 1].toInt() and 0xFF
        when {
            isLetter(next) -> {
                var end = pos + 1
                while (end < data.size && isLetter(data[end].toInt() and 0xFF)) end++
                val word = String(data, pos + 1, end - pos - 1, Charsets.ISO_8859_1)
                var param: Int? = null
                val digitsFrom = if (end < data.size && data[end] == '-'.code.toByte()) end + 1 else end
                var digitsEnd = digitsFrom
                while (digitsEnd < data.size && (data[digitsEnd].toInt() and 0xFF) in 0x30..0x39) digitsEnd++
                if (digitsEnd > digitsFrom) {
                    param = String(data, end, digitsEnd - end, Charsets.ISO_8859_1).toLongOrNull()
                        ?.coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong())?.toInt()
                    end = digitsEnd
                }
                if (end < data.size && data[end] == ' '.code.toByte()) end++
                pos = end
                word(word, param)
            }
            next == '\''.code -> {
                val value = if (pos + 3 < data.size) {
                    String(data, pos + 2, 2, Charsets.ISO_8859_1).toIntOrNull(16)
                } else {
                    null
                }
                pos += if (value != null) 4 else 2
                if (value != null) hexByte(value)
            }
            next == CR || next == LF -> {
                pos += 2
                word("par", null)
            }
            else -> {
                pos += 2
                symbol(next)
            }
        }
    }

    private fun word(word: String, param: Int?) {
        if (skip > 0) {
            skip--
            if (word == "bin") skipBinary(param)
            return
        }
        val g = group
        if (groupStart) {
            groupStart = false
            when {
                word == "ud" && g.ignore && parentIsUpr() -> {
                    g.ignore = false
                    g.upr = false
                    return
                }
                word == "upr" -> {
                    g.ignore = true
                    g.upr = true
                    return
                }
                word in IGNORED_DESTINATIONS -> {
                    g.ignore = true
                    if (word == "fonttbl") g.fontTable = true
                    return
                }
            }
        }
        if (g.fontTable) {
            when (word) {
                "f" -> fontDef = param
                "fcharset" -> fontDef?.let { fonts.getOrPut(it, ::FontDef).charset = param }
                "cpg" -> fontDef?.let { fonts.getOrPut(it, ::FontDef).cpg = param }
                "bin" -> skipBinary(param)
            }
            return
        }
        if (g.ignore) {
            if (word == "bin") skipBinary(param)
            return
        }
        when (word) {
            "bin" -> skipBinary(param)
            "ansicpg" -> param?.let { ansiCpg = it }
            "mac" -> ansiCpg = 10000
            "pc" -> ansiCpg = 437
            "pca" -> ansiCpg = 850
            "deff" -> defaultFont = param
            "f" -> {
                flushBytes()
                g.font = param
            }
            "uc" -> g.ucSkip = (param ?: 1).coerceAtLeast(0)
            "u" -> param?.let {
                emit((if (it < 0) it + 65536 else it).toChar().toString())
                skip = g.ucSkip
            }
            "v" -> g.hidden = (param ?: 1) != 0
            // `\plain` resets character formatting and also ends `\v` hidden.
            "plain" -> g.hidden = false
            else -> OUTPUT[word]?.let(::emit)
        }
    }

    private fun symbol(c: Int) {
        if (skip > 0) {
            skip--
            return
        }
        if (c == '*'.code) {
            // `\*` only matters at the start of a group: the whole group is ignored (the `\*\ud` inside `\upr` is let through by the next control word).
            if (groupStart) group.ignore = true
            return
        }
        groupStart = false
        when (c) {
            '\\'.code, '{'.code, '}'.code -> literal(c)
            '~'.code -> emit(" ")
            '_'.code -> emit("-")
            else -> Unit // `\-` and other control symbols produce no output
        }
    }

    private fun hexByte(value: Int) {
        if (skip > 0) {
            skip--
            return
        }
        groupStart = false
        if (group.ignore || group.hidden) return
        addByte(value)
    }

    private fun plainByte(byte: Int) {
        if (skip > 0) {
            skip--
            return
        }
        groupStart = false
        if (group.ignore || group.hidden) return
        if (byte >= 0x80) addByte(byte) else literal(byte)
    }

    /** A literal ASCII character; in a double-byte code page, 0x40-0x7E right after a lead byte counts as a trail byte. */
    private fun literal(c: Int) {
        if (group.ignore || group.hidden) return
        if (c in 0x40..0x7E && bytes.size() > 0 && isDoubleByte(bytesCodepage) && endsWithLeadByte()) {
            bytes.write(c)
            return
        }
        emit(c.toChar().toString())
    }

    private fun emit(text: String) {
        if (group.ignore || group.hidden) return
        flushBytes()
        out.append(text)
    }

    private fun addByte(value: Int) {
        val codepage = currentCodepage()
        if (bytes.size() > 0 && codepage != bytesCodepage) flushBytes()
        bytesCodepage = codepage
        bytes.write(value)
    }

    private fun flushBytes() {
        if (bytes.size() == 0) return
        out.append(decode(bytes.toByteArray(), bytesCodepage))
        bytes.reset()
    }

    private fun skipBinary(count: Int?) {
        pos = (pos + (count ?: 0).coerceAtLeast(0)).coerceAtMost(data.size)
    }

    private fun parentIsUpr(): Boolean = stack.size >= 2 && stack[stack.size - 2].upr

    /** Code page taken in order: the current font's `\cpg`, the code page for the current font's `\fcharset`, `\ansicpg`, finally 1252. */
    private fun currentCodepage(): Int {
        val def = (group.font ?: defaultFont)?.let(fonts::get)
        def?.cpg?.let { return it }
        def?.charset?.let { charset -> charsetCodepage(charset)?.let { return it } }
        return ansiCpg
    }

    /** `\fcharset` -> code page; 0 / 1 return null (take `\ansicpg`). */
    private fun charsetCodepage(charset: Int): Int? = when (charset) {
        0, 1 -> null
        77 -> 10000
        128 -> 932
        129 -> 949
        134 -> 936
        136 -> 950
        161 -> 1253
        162 -> 1254
        163 -> 1258
        177 -> 1255
        178 -> 1256
        186 -> 1257
        204 -> 1251
        222 -> 874
        238 -> 1250
        else -> 1252
    }

    private fun endsWithLeadByte(): Boolean {
        val buffered = bytes.toByteArray()
        var index = 0
        while (index < buffered.size) {
            if (isLeadByte(bytesCodepage, buffered[index].toInt() and 0xFF)) {
                if (index + 1 >= buffered.size) return true
                index += 2
            } else {
                index++
            }
        }
        return false
    }

    private fun decode(raw: ByteArray, codepage: Int): String {
        when (codepage) {
            1252, 10000, 437, 850 -> return singleByte(raw, LegacyCharsetTables.windows1252High)
            1251 -> return singleByte(raw, LegacyCharsetTables.windows1251High)
        }
        val charset = when (codepage) {
            932 -> PlainTextExtractor.legacyCharset(LegacyCharsetTables.SHIFT_JIS)
            936 -> PlainTextExtractor.legacyCharset(LegacyCharsetTables.GB18030)
            949 -> PlainTextExtractor.legacyCharset(LegacyCharsetTables.EUC_KR)
            950 -> PlainTextExtractor.legacyCharset(LegacyCharsetTables.BIG5)
            else -> listOf("windows-$codepage", "x-windows-$codepage", "cp$codepage").firstNotNullOfOrNull(::charsetOrNull)
        } ?: return singleByte(raw, LegacyCharsetTables.windows1252High)
        if (isDoubleByte(codepage)) return decodeDoubleByte(raw, codepage, charset)
        // Bytes that fail to decode output U+FFFD.
        return charset.newDecoder()
            .onMalformedInput(CodingErrorAction.REPLACE)
            .onUnmappableCharacter(CodingErrorAction.REPLACE)
            .replaceWith("�")
            .decode(ByteBuffer.wrap(raw))
            .toString()
    }

    /** Double-byte code page: strictly decode the whole run; on failure decode character unit by character unit, each failed unit yielding one U+FFFD. */
    private fun decodeDoubleByte(raw: ByteArray, codepage: Int, charset: Charset): String {
        strictDecode(charset, raw, 0, raw.size)?.let { return it }
        val result = StringBuilder()
        var index = 0
        while (index < raw.size) {
            val unit = unitLength(raw, index, codepage)
            result.append(strictDecode(charset, raw, index, unit) ?: "\uFFFD")
            index += unit
        }
        return result.toString()
    }

    /** Byte count of one character unit: a lead byte takes one trail byte (GB18030 four-byte sequences take three), others are single-byte; a truncation extends to the end of the run. */
    private fun unitLength(raw: ByteArray, index: Int, codepage: Int): Int {
        if (!isLeadByte(codepage, raw[index].toInt() and 0xFF)) return 1
        val second = raw.getOrNull(index + 1)?.toInt()?.and(0xFF) ?: return 1
        val length = if (codepage == 936 && second in 0x30..0x39) 4 else 2
        return minOf(length, raw.size - index)
    }

    private fun strictDecode(charset: Charset, raw: ByteArray, offset: Int, length: Int): String? =
        try {
            charset.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(raw, offset, length))
                .toString()
        } catch (_: CharacterCodingException) {
            null
        }

    private fun singleByte(raw: ByteArray, high: CharArray): String =
        String(CharArray(raw.size) { index -> (raw[index].toInt() and 0xFF).let { if (it < 0x80) it.toChar() else high[it - 0x80] } })

    private fun charsetOrNull(name: String): Charset? =
        runCatching { if (Charset.isSupported(name)) Charset.forName(name) else null }.getOrNull()

    private fun replaceLoneSurrogates(text: CharSequence): String {
        val result = StringBuilder(text.length)
        var index = 0
        while (index < text.length) {
            val c = text[index]
            when {
                Character.isHighSurrogate(c) && index + 1 < text.length && Character.isLowSurrogate(text[index + 1]) -> {
                    result.append(c).append(text[index + 1])
                    index += 2
                    continue
                }
                Character.isSurrogate(c) -> result.append('�')
                else -> result.append(c)
            }
            index++
        }
        return result.toString()
    }

    companion object {
        private const val CHECK_INTERVAL_BYTES = 64 * 1024
        private const val CR = 0x0D
        private const val LF = 0x0A

        private fun isLetter(byte: Int): Boolean = byte in 0x41..0x5A || byte in 0x61..0x7A

        private fun isDoubleByte(codepage: Int): Boolean = codepage == 932 || codepage == 936 || codepage == 949 || codepage == 950

        private fun isLeadByte(codepage: Int, byte: Int): Boolean = when (codepage) {
            932 -> byte in 0x81..0x9F || byte in 0xE0..0xFC
            936, 949, 950 -> byte in 0x81..0xFE
            else -> false
        }

        private val IGNORED_DESTINATIONS = setOf(
            "fonttbl", "colortbl", "stylesheet", "listtable", "listoverridetable", "revtbl", "rsidtbl", "info",
            "pict", "shppict", "nonshppict", "object", "themedata", "datastore", "latentstyles", "xmlnstbl",
            "generator", "fldinst", "header", "headerl", "headerr", "headerf", "footer", "footerl", "footerr",
            "footerf",
        )

        private val OUTPUT = mapOf(
            "par" to "\n", "line" to "\n",
            "sect" to "\n\n", "page" to "\n\n",
            "tab" to "\t", "cell" to "\t", "nestcell" to "\t",
            "row" to "\n", "nestrow" to "\n",
            "emdash" to "—", "endash" to "–", "bullet" to "•",
            "lquote" to "‘", "rquote" to "’", "ldblquote" to "“", "rdblquote" to "”",
        )
    }
}
