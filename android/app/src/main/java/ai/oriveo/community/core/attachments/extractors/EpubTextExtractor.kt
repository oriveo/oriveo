package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import ai.oriveo.community.core.util.InputSizeLimitExceededException
import ai.oriveo.community.core.util.readBytesLimited
import org.xml.sax.Attributes
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import java.util.zip.ZipInputStream
import javax.xml.parsers.SAXParserFactory


object EpubTextExtractor {

    fun extract(data: ByteArray): String {
        val container = readZipEntry(data, "META-INF/container.xml")
            ?: throw ExtractionException(ExtractionErrorCode.CorruptedFile)

        val opfPath = parseOpfPath(container)
            ?: throw ExtractionException(ExtractionErrorCode.CorruptedFile)

        val opf = readZipEntry(data, opfPath)
            ?: throw ExtractionException(ExtractionErrorCode.CorruptedFile)

        val opfDir = opfPath.substringBeforeLast('/', "")
        val handler = OpfHandler(opfDir)
        SAXParserFactory.newInstance().also { factory ->
            factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false)
            factory.setFeature("http://xml.org/sax/features/external-general-entities", false)
        }.newSAXParser().parse(opf.byteInputStream(), handler)

        val spineEntries = readZipEntries(data, handler.spineHrefs.toSet())
        val parts = mutableListOf<String>()
        for (href in handler.spineHrefs) {
            val xhtml = spineEntries[href] ?: continue
            val text = HtmlTextExtractor.extract(xhtml.toByteArray()).trim()
            if (text.isNotEmpty()) parts.add(text)
        }
        return parts.joinToString("\n\n")
    }

    private fun parseOpfPath(containerXml: String): String? {
        val r = Regex("""full-path="([^"]+)"""")
        return r.find(containerXml)?.groupValues?.get(1)
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

    private fun readZipEntries(data: ByteArray, paths: Set<String>): Map<String, String> {
        val result = mutableMapOf<String, String>()
        var totalBytes = 0L
        val totalBudget = archiveTotalBudgetBytes()
        val entryBudget = archiveEntryBudgetBytes()
        try {
            ZipInputStream(ByteArrayInputStream(data)).use { zis ->
                var entryCount = 0
                var entry = zis.nextEntry
                while (entry != null) {
                    if (++entryCount > MAX_ARCHIVE_ENTRY_COUNT) throw archiveTooLarge()
                    if (entry.name in paths) {
                        val remaining = totalBudget - totalBytes
                        val bytes = zis.readBytesLimited(minOf(entryBudget, remaining))
                        totalBytes += bytes.size
                        result[entry.name] = bytes.toString(Charsets.UTF_8)
                    }
                    zis.closeEntry()
                    entry = zis.nextEntry
                }
            }
        } catch (_: InputSizeLimitExceededException) {
            throw archiveTooLarge()
        }
        return result
    }

    private fun archiveTooLarge(): ExtractionException =
        ExtractionException(ExtractionErrorCode.FileTooLarge, "Expanded EPUB archive exceeds safety limits")

    private class OpfHandler(private val opfDir: String) : DefaultHandler() {
        val manifest = mutableMapOf<String, String>()   // id -> href
        val spineRefs = mutableListOf<String>()

        val spineHrefs: List<String>
            get() = spineRefs.mapNotNull { manifest[it] }
                .map { if (opfDir.isEmpty()) it else "$opfDir/$it" }

        override fun startElement(uri: String?, localName: String?, qName: String?, attrs: Attributes?) {
            val name = (localName?.takeIf { it.isNotEmpty() } ?: qName) ?: return
            when (name) {
                "item" -> {
                    val id = attrs?.getValue("id") ?: return
                    val href = attrs.getValue("href") ?: return
                    manifest[id] = href
                }
                "itemref" -> attrs?.getValue("idref")?.let { spineRefs.add(it) }
            }
        }
    }
}
