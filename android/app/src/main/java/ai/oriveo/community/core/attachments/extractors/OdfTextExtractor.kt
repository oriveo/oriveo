package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import ai.oriveo.community.core.util.InputSizeLimitExceededException
import ai.oriveo.community.core.util.readBytesLimited
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import java.io.StringReader
import java.util.zip.ZipInputStream
import javax.xml.parsers.SAXParserFactory

object OdfTextExtractor {

    /**
     * Extracts the text of an OpenDocument file.
     *
     * `.odt`, `.ods` and `.odp` all store their text in `content.xml` inside the same zip container,
     * so the extension does not change how it is read.
     */
    fun extract(data: ByteArray): String {
        val contentXml = readZipEntry(data, "content.xml")
            ?: throw ExtractionException(ExtractionErrorCode.CorruptedFile)

        val withBreaks = contentXml.replace("</text:p>", "\n</text:p>")
        val handler = TextHandler()
        val parser = SAXParserFactory.newInstance().also { factory ->
            factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false)
            factory.setFeature("http://xml.org/sax/features/external-general-entities", false)
        }.newSAXParser()
        parser.parse(InputSource(StringReader(withBreaks)), handler)
        return handler.sb.toString().replace(Regex("\\n{3,}"), "\n\n").trim()
    }

    private fun readZipEntry(data: ByteArray, path: String): String? {
        val entryBudget = archiveEntryBudgetBytes()
        try {
            ZipInputStream(ByteArrayInputStream(data)).use { zis ->
                var entryCount = 0
                var entry = zis.nextEntry
                while (entry != null) {
                    if (++entryCount > MAX_ARCHIVE_ENTRY_COUNT) throw archiveTooLarge()
                    if (entry.name == path) {
                        return zis.readBytesLimited(entryBudget).toString(Charsets.UTF_8)
                    }
                    zis.closeEntry()
                    entry = zis.nextEntry
                }
            }
        } catch (_: InputSizeLimitExceededException) {
            throw archiveTooLarge()
        }
        return null
    }

    private fun archiveTooLarge(): ExtractionException =
        ExtractionException(ExtractionErrorCode.FileTooLarge, "Expanded ODF archive exceeds safety limits")

    private class TextHandler : DefaultHandler() {
        val sb = StringBuilder()
        override fun characters(ch: CharArray, start: Int, length: Int) {
            sb.append(ch, start, length)
        }
    }
}
