package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import org.xml.sax.Attributes
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import javax.xml.parsers.SAXParserFactory

/**
 * Lightweight XML node: [name] is "canonical prefix:local name" (the prefix is normalized by namespace URI, see [XmlParts.prefixFor]),
 * [children] are [XNode] or [String] (character data).
 */
internal class XNode(val name: String, val attrs: Map<String, String>) {
    val children = ArrayList<Any>(2)

    val local: String get() = name.substringAfter(':')

    fun attr(key: String): String? = attrs[key]

    fun elements(): List<XNode> = children.filterIsInstance<XNode>()

    fun child(name: String): XNode? = children.firstOrNull { it is XNode && it.name == name } as XNode?

    fun children(name: String): List<XNode> = children.filter { it is XNode && it.name == name }.map { it as XNode }

    /** All descendants named [name] (document order, including every level below itself). */
    fun elements(name: String): List<XNode> {
        val out = ArrayList<XNode>()
        fun visit(node: XNode) {
            for (child in node.children) {
                if (child !is XNode) continue
                if (child.name == name) out += child
                visit(child)
            }
        }
        if (this.name == name) out += this
        visit(this)
        return out
    }

    /** All character data concatenated in order. */
    fun text(): String = buildString {
        fun visit(node: XNode) {
            for (child in node.children) if (child is XNode) visit(child) else append(child as String)
        }
        visit(this@XNode)
    }
}

/**
 * XML part parsing for OOXML / ODF (attachment extraction spec section 15):
 * before parsing, look at the first 1024 bytes after removing the BOM; if they contain `<!DOCTYPE` -> `corrupted_file`; SAX has external entities turned off.
 */
internal object XmlParts {
    private val knownNamespaces = mapOf(
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main" to "w",
        "http://purl.oclc.org/ooxml/wordprocessingml/main" to "w",
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main" to "x",
        "http://purl.oclc.org/ooxml/spreadsheetml/main" to "x",
        "http://schemas.openxmlformats.org/presentationml/2006/main" to "p",
        "http://purl.oclc.org/ooxml/presentationml/main" to "p",
        "http://schemas.openxmlformats.org/drawingml/2006/main" to "a",
        "http://purl.oclc.org/ooxml/drawingml/main" to "a",
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships" to "r",
        "http://purl.oclc.org/ooxml/officeDocument/relationships" to "r",
        "http://schemas.openxmlformats.org/markup-compatibility/2006" to "mc",
        "http://schemas.openxmlformats.org/package/2006/relationships" to "",
        "urn:oasis:names:tc:opendocument:xmlns:office:1.0" to "office",
        "urn:oasis:names:tc:opendocument:xmlns:text:1.0" to "text",
        "urn:oasis:names:tc:opendocument:xmlns:table:1.0" to "table",
        "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" to "draw",
        "urn:oasis:names:tc:opendocument:xmlns:presentation:1.0" to "presentation",
        "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" to "svg",
    )

    private const val DOCTYPE_WINDOW = 1024

    /** Known namespaces are normalized to fixed prefixes; no namespace gives an empty string; other URIs are kept as-is in braces so they never collide with known prefixes. */
    fun prefixFor(uri: String?): String =
        if (uri.isNullOrEmpty()) "" else knownNamespaces[uri] ?: "{$uri}"

    private fun qualified(uri: String?, localName: String?, qName: String?): String {
        val local = localName?.takeIf { it.isNotEmpty() } ?: qName.orEmpty().substringAfter(':')
        val prefix = prefixFor(uri)
        return if (prefix.isEmpty()) local else "$prefix:$local"
    }

    /** Section 15: the first 1024 bytes after removing the BOM contain `<!DOCTYPE` (case-insensitive) -> `corrupted_file`. */
    fun checkDoctype(bytes: ByteArray) {
        val utf8Bom = bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()
        val utf16Bom = bytes.size >= 2 &&
            ((bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte()) || (bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte()))
        val head = when {
            utf8Bom -> String(bytes, 3, minOf(DOCTYPE_WINDOW, bytes.size - 3), Charsets.ISO_8859_1)
            utf16Bom -> String(
                bytes, 2, minOf(DOCTYPE_WINDOW, bytes.size - 2),
                if (bytes[0] == 0xFF.toByte()) Charsets.UTF_16LE else Charsets.UTF_16BE,
            )
            else -> String(bytes, 0, minOf(DOCTYPE_WINDOW, bytes.size), Charsets.ISO_8859_1)
        }
        if (head.contains("<!DOCTYPE", ignoreCase = true)) throw ExtractionException(ExtractionErrorCode.CorruptedFile, "doctype")
    }

    /** Build the whole part into one tree and return the root element. */
    fun tree(bytes: ByteArray): XNode {
        var root: XNode? = null
        stream(bytes, capture = { _, ancestors -> ancestors.isEmpty() }, onCaptured = { node, _ -> root = node })
        return root ?: throw ExtractionException(ExtractionErrorCode.CorruptedFile)
    }

    /**
     * Streaming parse: when [capture] returns true for an element (not already inside a captured subtree), build its whole subtree into an [XNode] and hand it to [onCaptured];
     * other elements only call back [onStart] / [onEnd]. `ancestors` is the list of canonical names from the root to the parent element.
     */
    fun stream(
        bytes: ByteArray,
        capture: (name: String, ancestors: List<String>) -> Boolean,
        onCaptured: (node: XNode, ancestors: List<String>) -> Unit,
        onStart: (name: String, attrs: Map<String, String>, ancestors: List<String>) -> Unit = { _, _, _ -> },
        onEnd: (name: String, ancestors: List<String>) -> Unit = { _, _ -> },
    ) {
        checkDoctype(bytes)
        val handler = object : DefaultHandler() {
            private val path = ArrayList<String>()
            private val building = ArrayList<XNode>()

            override fun startElement(uri: String?, localName: String?, qName: String?, attributes: Attributes?) {
                val name = qualified(uri, localName, qName)
                if (building.isNotEmpty()) {
                    val node = XNode(name, attrsOf(attributes))
                    building.last().children += node
                    building += node
                    path += name
                    return
                }
                if (capture(name, path)) {
                    building += XNode(name, attrsOf(attributes))
                } else {
                    onStart(name, attrsOf(attributes), path)
                }
                path += name
            }

            override fun endElement(uri: String?, localName: String?, qName: String?) {
                val name = path.removeAt(path.lastIndex)
                if (building.isNotEmpty()) {
                    val node = building.removeAt(building.lastIndex)
                    if (building.isEmpty()) onCaptured(node, path)
                    return
                }
                onEnd(name, path)
            }

            override fun characters(ch: CharArray, start: Int, length: Int) {
                val current = building.lastOrNull() ?: return
                val last = current.children.lastOrNull()
                if (last is String) {
                    current.children[current.children.lastIndex] = last + String(ch, start, length)
                } else {
                    current.children += String(ch, start, length)
                }
            }
        }
        newParserFactory().newSAXParser().parse(ByteArrayInputStream(bytes), handler)
    }

    private fun attrsOf(attributes: Attributes?): Map<String, String> {
        if (attributes == null || attributes.length == 0) return emptyMap()
        val map = HashMap<String, String>(attributes.length * 2)
        for (index in 0 until attributes.length) {
            val qName = attributes.getQName(index).orEmpty()
            if (qName == "xmlns" || qName.startsWith("xmlns:")) continue
            map[qualified(attributes.getURI(index), attributes.getLocalName(index), qName)] = attributes.getValue(index)
        }
        return map
    }

    private fun newParserFactory(): SAXParserFactory = SAXParserFactory.newInstance().also { factory ->
        factory.isNamespaceAware = true
        for (feature in listOf(
            "http://apache.org/xml/features/nonvalidating/load-external-dtd",
            "http://xml.org/sax/features/external-general-entities",
            "http://xml.org/sax/features/external-parameter-entities",
        )) {
            try {
                factory.setFeature(feature, false)
            } catch (_: Exception) {
                // Some platforms' parsers do not recognize this switch; external DTDs are already blocked earlier by the section 15 DOCTYPE check.
            }
        }
    }
}
