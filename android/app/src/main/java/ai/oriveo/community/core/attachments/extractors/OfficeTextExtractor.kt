package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import ai.oriveo.community.core.util.InputSizeLimitExceededException
import ai.oriveo.community.core.util.readBytesLimited
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import java.io.StringReader
import java.util.zip.ZipInputStream
import javax.xml.parsers.SAXParserFactory


object OfficeTextExtractor {

    val supportedExtensions: Set<String> = setOf("docx", "xlsx", "pptx")

    fun isOfficeFile(extension: String): Boolean =
        supportedExtensions.contains(extension.lowercase())

    
    fun extractText(data: ByteArray, fileExtension: String): String? {
        return when (fileExtension.lowercase()) {
            "docx" -> extractDocxText(data)
            "xlsx" -> extractXlsxText(data)
            "pptx" -> extractPptxText(data)
            else -> null
        }
    }

    // region DOCX

    private fun extractDocxText(data: ByteArray): String {
        val xml = readZipEntry(data, "word/document.xml") ?: return ""
        val withBreaks = xml.replace("</w:p>", "\n</w:p>")
        return parseXmlText(withBreaks).collapseNewlines()
    }

    // endregion

    // region PPTX

    private fun extractPptxText(data: ByteArray): String {
        val entries = readZipEntries(data) { it.startsWith("ppt/slides/slide") && it.endsWith(".xml") }
        return entries.keys.sorted().mapNotNull { path ->
            val xml = entries[path] ?: return@mapNotNull null
            val withBreaks = xml.replace("</a:p>", "\n</a:p>")
            parseXmlText(withBreaks).trim().ifEmpty { null }
        }.joinToString("\n\n")
    }

    // endregion

    // region XLSX

    private fun extractXlsxText(data: ByteArray): String {
        
        val entries = readZipEntries(data) { name ->
            name == "xl/sharedStrings.xml" ||
                (name.startsWith("xl/worksheets/sheet") && name.endsWith(".xml"))
        }

        
        val sharedStrings = entries["xl/sharedStrings.xml"]
            ?.let { parseSharedStrings(it) }
            ?: emptyList()

        
        return entries.keys
            .filter { it.startsWith("xl/worksheets/sheet") }
            .sorted()
            .mapNotNull { path ->
                val xml = entries[path] ?: return@mapNotNull null
                parseSheetXml(xml, sharedStrings).ifEmpty { null }
            }
            .joinToString("\n\n")
    }

    private fun parseSharedStrings(xml: String): List<String> {
        val strings = mutableListOf<String>()
        val handler = object : DefaultHandler() {
            private val text = StringBuilder()
            private var inSI = false
            override fun startElement(uri: String?, ln: String?, qName: String?, attrs: Attributes?) {
                if (qName == "si") { inSI = true; text.clear() }
            }
            override fun characters(ch: CharArray, start: Int, length: Int) {
                if (inSI) text.append(ch, start, length)
            }
            override fun endElement(uri: String?, ln: String?, qName: String?) {
                if (qName == "si") { strings.add(text.toString()); inSI = false }
            }
        }
        saxParse(xml, handler)
        return strings
    }

    private fun parseSheetXml(xml: String, sharedStrings: List<String>): String {
        val rows = mutableListOf<List<String>>()
        val handler = object : DefaultHandler() {
            private var currentRow = mutableListOf<String>()
            private var cellValue = StringBuilder()
            private var cellType = ""
            private var inValue = false

            override fun startElement(uri: String?, ln: String?, qName: String?, attrs: Attributes?) {
                when (qName) {
                    "row" -> currentRow = mutableListOf()
                    "c" -> { cellType = attrs?.getValue("t") ?: ""; cellValue.clear() }
                    "v" -> { inValue = true; cellValue.clear() }
                }
            }
            override fun characters(ch: CharArray, start: Int, length: Int) {
                if (inValue) cellValue.append(ch, start, length)
            }
            override fun endElement(uri: String?, ln: String?, qName: String?) {
                when (qName) {
                    "v" -> inValue = false
                    "c" -> {
                        val value = cellValue.toString()
                        if (cellType == "s") {
                            val idx = value.toIntOrNull() ?: -1
                            currentRow.add(if (idx in sharedStrings.indices) sharedStrings[idx] else value)
                        } else {
                            currentRow.add(value)
                        }
                    }
                    "row" -> rows.add(currentRow.toList())
                }
            }
        }
        saxParse(xml, handler)
        return rows.joinToString("\n") { it.joinToString("\t") }
    }

    // endregion

    

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

    private fun readZipEntries(data: ByteArray, filter: (String) -> Boolean): Map<String, String> {
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
                    if (filter(entry.name)) {
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
        ExtractionException(ExtractionErrorCode.FileTooLarge, "Expanded Office archive exceeds safety limits")

    // endregion

    

    private fun parseXmlText(xml: String): String {
        val text = StringBuilder()
        val handler = object : DefaultHandler() {
            override fun characters(ch: CharArray, start: Int, length: Int) {
                text.append(ch, start, length)
            }
        }
        saxParse(xml, handler)
        return text.toString()
    }

    private fun saxParse(xml: String, handler: DefaultHandler) {
        val factory = SAXParserFactory.newInstance()
        
        factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false)
        factory.setFeature("http://xml.org/sax/features/external-general-entities", false)
        factory.newSAXParser().parse(InputSource(StringReader(xml)), handler)
    }

    private fun String.collapseNewlines(): String =
        replace(Regex("\\n{3,}"), "\n\n").trim()

    // endregion
}
