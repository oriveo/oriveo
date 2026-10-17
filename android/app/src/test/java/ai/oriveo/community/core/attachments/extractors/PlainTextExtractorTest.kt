package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
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
        val gbk = "\u4F60\u597D\u4E16\u754C".toByteArray(Charset.forName("GB18030"))
        assertEquals("\u4F60\u597D\u4E16\u754C", PlainTextExtractor.extract(gbk))
    }

    @Test
    fun emptyData() {
        assertEquals("", PlainTextExtractor.extract(byteArrayOf()))
    }

    // -- Attachment extraction spec section 4 --

    @Test
    fun newlinesAreNormalizedButWhitespaceIsKept() {
        assertEquals("a\n\n\n  b  \nc\n", PlainTextExtractor.extract("a\r\n\r\n\r\n  b  \rc\n".toByteArray()))
    }

    @Test
    fun utf16WithBomAndALoneSurrogateIsCorrupted() {
        val data = byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x41, 0x00, 0x00, 0xD8.toByte(), 0x42, 0x00)
        val error = runCatching { PlainTextExtractor.extract(data) }.exceptionOrNull()
        assertEquals(ExtractionErrorCode.CorruptedFile, (error as? ExtractionException)?.code)
    }

    @Test
    fun nulBytesAtOddPositionsMeanUtf16LeWithoutBom() {
        assertEquals("Hi", PlainTextExtractor.extract("Hi".toByteArray(Charsets.UTF_16LE)))
        assertEquals("Hi", PlainTextExtractor.extract("Hi".toByteArray(Charsets.UTF_16BE)))
    }

    @Test
    fun nulBytesAtBothParitiesAreBinary() {
        val data = byteArrayOf(0x89.toByte(), 0x50, 0x00, 0x00, 0x0D, 0x0A)
        val error = runCatching { PlainTextExtractor.extract(data) }.exceptionOrNull()
        assertEquals(ExtractionErrorCode.UnsupportedFormat, (error as? ExtractionException)?.code)
    }

    @Test
    fun uiLanguageOnlyBreaksTies() {
        // C5 A2 scores a +1 range score under GB18030, Big5 and EUC-KR and is not in the common-character table: all three tie, the UI language decides the rank, with no bonus.
        val bytes = byteArrayOf(0xC5.toByte(), 0xA2.toByte())
        val scores = listOf("gb18030", "big5", "euc-kr").map { PlainTextExtractor.score(it, bytes) }
        assertEquals(listOf(1.0, 1.0, 1.0), scores)
        assertEquals("gb18030", PlainTextExtractor.rankCandidates(bytes, "en").first())
        assertEquals("big5", PlainTextExtractor.rankCandidates(bytes, "zh-Hant").first())
        assertEquals("euc-kr", PlainTextExtractor.rankCandidates(bytes, "ko").first())
    }

    @Test
    fun windows1252AndWindows1251AlwaysSurviveAndMultiByteFailuresAreDropped() {
        // A lone E9 at the end: strict decoding of the sample fails for multibyte candidates (the sample is the whole file, no retry).
        val ranked = PlainTextExtractor.rankCandidates("caf".toByteArray() + byteArrayOf(0xE9.toByte()), "en")
        assertEquals(listOf("windows-1252", "windows-1251"), ranked.filter { it.startsWith("windows-") })
        assertEquals("windows-1252", ranked.first())
        assertEquals("café", PlainTextExtractor.extract("caf".toByteArray() + byteArrayOf(0xE9.toByte())))
    }

    @Test
    fun cyrillicInWindows1251() {
        val text = "Привет, мир! Это проверка."
        assertEquals(text, PlainTextExtractor.extract(text.toByteArray(Charset.forName("windows-1251"))))
    }
}
