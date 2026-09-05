package ai.oriveo.community.core.attachments.extractors

import org.junit.Assert.*
import org.junit.Test
import java.nio.charset.Charset

class PlainTextExtractorTest {

    @Test
    fun utf8NoBom() {
        assertEquals("hello こんにちは", PlainTextExtractor.extract("hello こんにちは".toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun utf8WithBom() {
        val bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())
        val data = bom + "hello".toByteArray(Charsets.UTF_8)
        assertEquals("hello", PlainTextExtractor.extract(data))
    }

    @Test
    fun utf16Le() {
        // UTF-16LE with BOM: Charset.forName("UTF-16") includes BOM automatically
        val data = "hello".toByteArray(Charset.forName("UTF-16"))  // Java includes BOM
        val result = PlainTextExtractor.extract(data)
        assertTrue("UTF-16 with BOM should decode to 'hello'", result.contains("hello"))
    }

    @Test
    fun utf16Be() {
        // UTF-16BE BOM test: construct BOM + UTF-16BE bytes manually
        val bom = byteArrayOf(0xFE.toByte(), 0xFF.toByte())
        val data = bom + "hello".toByteArray(Charset.forName("UTF-16BE"))
        val result = PlainTextExtractor.extract(data)
        assertTrue("UTF-16BE with BOM should decode to 'hello'", result.contains("hello"))
    }

    @Test
    fun gbkChinese() {
        val gbk = "こんにちは".toByteArray(Charset.forName("GB18030"))
        assertEquals("こんにちは", PlainTextExtractor.extract(gbk))
    }

    @Test
    fun emptyData() {
        assertEquals("", PlainTextExtractor.extract(byteArrayOf()))
    }
}
