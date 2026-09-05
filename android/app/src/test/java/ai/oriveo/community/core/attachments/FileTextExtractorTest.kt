package ai.oriveo.community.core.attachments

import org.junit.Assert.*
import org.junit.Test

class FileTextExtractorTest {

    @Test
    fun noTruncation() {
        val raw = (1..100).joinToString("\n") { "line $it" }
        val r = FileTextExtractor.truncate(raw, raw.toByteArray().size)
        assertFalse(r.truncated)
        assertEquals(100, r.totalLines)
        assertEquals(raw, r.content)
    }

    @Test
    fun truncateByLines() {
        val raw = (1..700).joinToString("\n") { "L$it" }
        val r = FileTextExtractor.truncate(raw, raw.toByteArray().size)
        assertTrue(r.truncated)
        assertEquals(ExtractedText.TruncationReason.Lines, r.truncationReason)
        assertEquals(700, r.totalLines)
        assertEquals(500, r.content.split("\n").size)
    }

    @Test
    fun truncateByBytes() {
        val big = "a".repeat(5000)
        val raw = (1..50).joinToString("\n") { big }
        val r = FileTextExtractor.truncate(raw, raw.toByteArray().size)
        assertTrue(r.truncated)
        assertTrue(r.content.toByteArray(Charsets.UTF_8).size <= FileExtractionLimits.MAX_BYTES)
    }

    @Test
    fun resolveDefaultWhenNoModel() {
        val limits = FileExtractionLimits.resolve(null)
        assertEquals(500, limits.maxLines)
        assertEquals(204_800, limits.maxBytes)
        assertEquals(3, limits.maxFiles)
    }

    @Test
    fun unsupportedMimeThrows() {
        var caught: ExtractionException? = null
        try {
            FileTextExtractor.extract(
                "hello".toByteArray(),
                "file.xyz",
                "application/x-unknown-format",
            )
        } catch (e: ExtractionException) {
            caught = e
        }
        assertNotNull(caught)
        assertEquals(ExtractionErrorCode.UnsupportedFormat, caught!!.code)
    }

    @Test
    fun fileTooLargeThrows() {
        val limits = FileExtractionLimits.DEFAULT.copy(maxInputFileBytes = 10L)
        var caught: ExtractionException? = null
        try {
            FileTextExtractor.extract(
                "a".repeat(20).toByteArray(),
                "test.txt",
                "text/plain",
                limits,
            )
        } catch (e: ExtractionException) {
            caught = e
        }
        assertNotNull(caught)
        assertEquals(ExtractionErrorCode.FileTooLarge, caught!!.code)
    }
}
