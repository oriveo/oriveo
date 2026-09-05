package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import java.nio.charset.Charset

/**
 * Tries decoding in priority order: UTF-8 BOM -> UTF-16 BOM -> UTF-8 -> GBK/GB18030 -> Shift-JIS -> lossy ISO-8859-1
 */
object PlainTextExtractor {
    fun extract(data: ByteArray): String {
        if (data.isEmpty()) return ""
        // UTF-8 BOM
        if (data.size >= 3 && data[0] == 0xEF.toByte() && data[1] == 0xBB.toByte() && data[2] == 0xBF.toByte()) {
            return String(data, 3, data.size - 3, Charsets.UTF_8)
        }
        // UTF-16 LE BOM
        if (data.size >= 2 && data[0] == 0xFF.toByte() && data[1] == 0xFE.toByte()) {
            return String(data, Charset.forName("UTF-16LE"))
        }
        // UTF-16 BE BOM
        if (data.size >= 2 && data[0] == 0xFE.toByte() && data[1] == 0xFF.toByte()) {
            return String(data, Charset.forName("UTF-16BE"))
        }

        // Try UTF-8 (strict decoder checks validity)
        runCatching {
            val decoder = Charsets.UTF_8.newDecoder()
            return decoder.decode(java.nio.ByteBuffer.wrap(data)).toString()
        }
        // Try GBK / GB18030
        runCatching {
            return String(data, Charset.forName("GB18030"))
        }
        // Shift-JIS
        runCatching {
            return String(data, Charset.forName("Shift_JIS"))
        }
        // Lossy fallback
        return String(data, Charsets.ISO_8859_1) +
            "\n[encoding detection failed, content may be garbled]"
    }
}
