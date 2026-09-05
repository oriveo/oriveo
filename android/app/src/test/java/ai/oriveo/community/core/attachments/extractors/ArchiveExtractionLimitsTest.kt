package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
import org.junit.Test

class ArchiveExtractionLimitsTest {

    @Test
    fun `archive budgets scale with heap and remain bounded`() {
        assertEquals(8L * 1024L * 1024L, archiveTotalBudgetBytes(32L * 1024L * 1024L))
        assertEquals(16L * 1024L * 1024L, archiveEntryBudgetBytes(2L * 1024L * 1024L * 1024L))
    }

    @Test
    fun `office extractor rejects highly expanded zip entry`() {
        val archive = zipOf(
            "word/document.xml" to ByteArray((archiveEntryBudgetBytes() + 1).toInt()) { 'a'.code.toByte() },
        )

        val error = runCatching {
            OfficeTextExtractor.extractText(archive, "docx")
        }.exceptionOrNull()

        assertEquals(ExtractionErrorCode.FileTooLarge, (error as ExtractionException).code)
    }

    @Test
    fun `office extractor still reads a normal document`() {
        val archive = zipOf(
            "word/document.xml" to "<w:document><w:p>Hello</w:p></w:document>".toByteArray(),
        )

        assertEquals("Hello", OfficeTextExtractor.extractText(archive, "docx"))
    }

    @Test
    fun `epub extractor reads spine in order`() {
        val archive = zipOf(
            "META-INF/container.xml" to
                "<container><rootfiles><rootfile full-path=\"OEBPS/content.opf\"/></rootfiles></container>".toByteArray(),
            "OEBPS/content.opf" to
                ("<package><manifest>" +
                    "<item id=\"one\" href=\"one.xhtml\"/><item id=\"two\" href=\"two.xhtml\"/>" +
                    "</manifest><spine><itemref idref=\"one\"/><itemref idref=\"two\"/></spine></package>").toByteArray(),
            "OEBPS/one.xhtml" to "<html><body>First chapter</body></html>".toByteArray(),
            "OEBPS/two.xhtml" to "<html><body>Second chapter</body></html>".toByteArray(),
        )

        assertEquals("First chapter\n\nSecond chapter", EpubTextExtractor.extract(archive))
    }

    private fun zipOf(vararg entries: Pair<String, ByteArray>): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            for ((name, bytes) in entries) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(bytes)
                zip.closeEntry()
            }
        }
        return output.toByteArray()
    }
}
