package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionDeadline
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import org.xml.sax.Attributes
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import javax.xml.parsers.SAXParserFactory

/**
 * EPUB extraction, spec section 10: DRM check -> container.xml -> OPF -> walk chapters in spine order via section 8.
 * The zip goes through the shared [ZipPackage] (budgets reuse [archiveTotalBudgetBytes] / [archiveEntryBudgetBytes], deadline checked per zip entry),
 * the deadline is checked at the start of each chapter (section 14); container.xml and the OPF go through the section 15 DOCTYPE check before parsing.
 */
object EpubTextExtractor {
    private const val CONTAINER = "META-INF/container.xml"
    private const val ENCRYPTION = "META-INF/encryption.xml"

    private val drmMarkers = setOf("META-INF/rights.xml", "META-INF/license.lcpl", "META-INF/sinf.xml")
    private val fontObfuscation = setOf("http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC")
    private val chapterMediaTypes = setOf("application/xhtml+xml", "text/html")
    private val voidElements = setOf(
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    )
    private val selfClosing = Regex("""<([A-Za-z][A-Za-z0-9:_.\-]*)(\s[^<>]*?)?/>""")

    @Throws(ExtractionException::class)
    fun extract(
        data: ByteArray,
        uiLanguage: String = "en",
        deadline: ExtractionDeadline = ExtractionDeadline(),
    ): String {
        val zip = ZipPackage.open(data, deadline, "EPUB")
        val meta = zip.readAll(listOf(CONTAINER, ENCRYPTION))
        if (zip.names.any { it in drmMarkers } || meta[ENCRYPTION]?.let(::hasDrmEncryption) == true) {
            throw ExtractionException(ExtractionErrorCode.UnsupportedFormat, "epub_drm")
        }

        val container = meta[CONTAINER]?.also(XmlParts::checkDoctype) ?: throw corrupted()
        val opfPath = rootfilePath(container) ?: throw corrupted()
        val opf = zip.read(opfPath)?.also(XmlParts::checkDoctype) ?: throw corrupted()
        val pkg = parseOpf(opf)

        val chapters = pkg.spine.mapNotNull { idref ->
            val item = pkg.manifest[idref] ?: return@mapNotNull null
            if (item.mediaType.substringBefore(';').trim().lowercase() !in chapterMediaTypes) return@mapNotNull null
            resolveHref(opfPath, item.href)?.let { zip.find(it) }
        }
        val files = if (chapters.isEmpty()) emptyMap() else zip.readAll(chapters.toSet())

        val parts = mutableListOf<String>()
        for (entry in chapters) {
            deadline.check()
            val bytes = files[entry] ?: continue
            val html = rewriteSelfClosing(HtmlTextExtractor.decode(bytes, uiLanguage))
            val text = HtmlTextExtractor.render(html)
            if (text.isNotEmpty()) parts += text
        }
        return StructuredText.normalize(parts.joinToString("\n\n"))
    }

    /** Section 10 step 5: rewrite `<tag .../>` of non-void elements into `<tag ...></tag>`. */
    internal fun rewriteSelfClosing(html: String): String =
        selfClosing.replace(html) { match ->
            val tag = match.groupValues[1]
            if (tag.lowercase() in voidElements) match.value else "<$tag${match.groupValues[2]}></$tag>"
        }

    /**
     * Section 10 step 3: resolve relative to the OPF's own path by URL rules. Drop everything after `#`, percent-decode, handle `.` and `..`;
     * return null if it escapes the package root or starts with `/`.
     */
    internal fun resolveHref(opfPath: String, href: String): String? {
        val withoutFragment = href.substringBefore('#')
        if (withoutFragment.startsWith("/")) return null
        val decoded = percentDecode(withoutFragment)
        val segments = opfPath.split('/').dropLast(1).filter { it.isNotEmpty() }.toMutableList()
        for (segment in decoded.split('/')) {
            when (segment) {
                "", "." -> Unit
                ".." -> if (segments.isEmpty()) return null else segments.removeAt(segments.lastIndex)
                else -> segments += segment
            }
        }
        return segments.takeIf { it.isNotEmpty() }?.joinToString("/")
    }

    private fun percentDecode(value: String): String {
        if ('%' !in value) return value
        val bytes = ByteArrayOutputStream()
        var index = 0
        while (index < value.length) {
            val c = value[index]
            val hex = if (c == '%' && index + 2 < value.length) {
                value.substring(index + 1, index + 3).toIntOrNull(16)
            } else {
                null
            }
            if (hex != null) {
                bytes.write(hex)
                index += 3
            } else {
                val end = if (Character.isHighSurrogate(c) && index + 1 < value.length) index + 2 else index + 1
                bytes.write(value.substring(index, end).toByteArray(Charsets.UTF_8))
                index = end
            }
        }
        return bytes.toByteArray().toString(Charsets.UTF_8)
    }

    private fun hasDrmEncryption(xml: ByteArray): Boolean {
        var drm = false
        parseXml(xml, object : DefaultHandler() {
            override fun startElement(uri: String?, localName: String?, qName: String?, attrs: Attributes?) {
                if (localName(localName, qName) != "EncryptionMethod") return
                if (attrs?.getValue("Algorithm")?.trim() !in fontObfuscation) drm = true
            }
        })
        return drm
    }

    private fun rootfilePath(xml: ByteArray): String? {
        var path: String? = null
        parseXml(xml, object : DefaultHandler() {
            override fun startElement(uri: String?, localName: String?, qName: String?, attrs: Attributes?) {
                if (path == null && localName(localName, qName) == "rootfile") {
                    path = attrs?.getValue("full-path")?.takeIf { it.isNotBlank() }
                }
            }
        })
        return path
    }

    private class ManifestItem(val href: String, val mediaType: String)

    private class Package(val manifest: Map<String, ManifestItem>, val spine: List<String>)

    private fun parseOpf(xml: ByteArray): Package {
        val manifest = mutableMapOf<String, ManifestItem>()
        val spine = mutableListOf<String>()
        parseXml(xml, object : DefaultHandler() {
            override fun startElement(uri: String?, localName: String?, qName: String?, attrs: Attributes?) {
                when (localName(localName, qName)) {
                    "item" -> {
                        val id = attrs?.getValue("id") ?: return
                        val href = attrs.getValue("href") ?: return
                        manifest.putIfAbsent(id, ManifestItem(href, attrs.getValue("media-type").orEmpty()))
                    }
                    "itemref" -> attrs?.getValue("idref")?.let { spine += it }
                }
            }
        })
        return Package(manifest, spine)
    }

    private fun parseXml(xml: ByteArray, handler: DefaultHandler) {
        SAXParserFactory.newInstance().also { factory ->
            factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false)
            factory.setFeature("http://xml.org/sax/features/external-general-entities", false)
            factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false)
        }.newSAXParser().parse(ByteArrayInputStream(xml), handler)
    }

    private fun localName(localName: String?, qName: String?): String =
        (localName?.takeIf { it.isNotEmpty() } ?: qName.orEmpty()).substringAfterLast(':')

    private fun corrupted(): ExtractionException = ExtractionException(ExtractionErrorCode.CorruptedFile)
}
