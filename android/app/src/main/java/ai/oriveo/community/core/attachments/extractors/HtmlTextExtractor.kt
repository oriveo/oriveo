package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionException
import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables.BIG5
import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables.EUC_KR
import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables.GB18030
import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables.SHIFT_JIS
import ai.oriveo.community.core.attachments.extractors.LegacyCharsetTables.WINDOWS_1252
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode
import org.jsoup.select.NodeFilter
import org.jsoup.select.NodeFilter.FilterResult
import org.jsoup.select.NodeTraversor

/**
 * HTML extraction, spec section 8: decode to a string ourselves and hand it to jsoup (HTML5 tree building),
 * walk the DOM from body using simplified innerText rules to produce Markdown-structured text, then apply section 3.1 normalization.
 */
object HtmlTextExtractor {
    private const val META_SNIFF_BYTES = 1024

    private val metaCharset = Regex("""<meta\b[^>]*?charset\s*=\s*["']?\s*([A-Za-z0-9_.:\-]+)""", RegexOption.IGNORE_CASE)

    /** Charset label normalization from section 8; labels not in the table count as undeclared. */
    private val charsetLabels: Map<String, String> = mapOf(
        "gbk" to GB18030, "gb2312" to GB18030, "x-gbk" to GB18030,
        "shift_jis" to SHIFT_JIS, "sjis" to SHIFT_JIS, "ms932" to SHIFT_JIS,
        "big5" to BIG5,
        "euc-kr" to EUC_KR, "ks_c_5601-1987" to EUC_KR,
        "iso-8859-1" to WINDOWS_1252, "latin1" to WINDOWS_1252, "ascii" to WINDOWS_1252, "us-ascii" to WINDOWS_1252,
        "utf-8" to PlainTextExtractor.UTF_8_LABEL, "utf8" to PlainTextExtractor.UTF_8_LABEL,
    ) + LegacyCharsetTables.candidates.associateWith { it } // the target names of section 4 candidates are accepted as-is too

    @Throws(ExtractionException::class)
    fun extract(data: ByteArray, uiLanguage: String = "en"): String = render(decode(data, uiLanguage))

    /** Section 8 "decode": BOM -> first meta charset within the first 1024 bytes -> section 4. */
    @Throws(ExtractionException::class)
    internal fun decode(data: ByteArray, uiLanguage: String): String =
        PlainTextExtractor.decodeDeclared(data, declaredCharset(data), uiLanguage)

    internal fun declaredCharset(data: ByteArray): String? {
        val head = String(data, 0, minOf(data.size, META_SNIFF_BYTES), Charsets.ISO_8859_1)
        val label = metaCharset.find(head)?.groupValues?.get(1)?.lowercase() ?: return null
        return charsetLabels[label]
    }

    /** From section 8 "parse" up to section 3.1 normalization. */
    internal fun render(html: String): String {
        val document = Jsoup.parse(html)
        val root: Element = document.body()
        val out = HtmlOut()
        HtmlWalker(out, HtmlContext()).walkChildren(root)
        return StructuredText.normalize(out.text())
    }
}

/** State shared across subtrees while walking the DOM (list stack, nesting depth of li / pre / table cells). */
private class HtmlContext {
    class ListLevel(val ordered: Boolean, var next: Int)

    val lists = ArrayDeque<ListLevel>()
    var liDepth = 0
    var preDepth = 0
    var cellDepth = 0
}

/**
 * Output buffer: newline requests merge by taking the maximum and only land before the next text is written, so requests at the start and end of the whole text drop naturally;
 * a space produced by whitespace collapsing right next to a request is removed, and collapsed spaces adjacent across text nodes merge into one.
 */
private class HtmlOut {
    private val sb = StringBuilder()
    private var pending = 0
    private var trailingCollapsed = false

    /** List marker not yet written: lands at the first text of the item; an item with no text emits no line at all. */
    private var pendingMarker: String? = null

    fun request(newlines: Int) {
        if (trailingCollapsed) {
            sb.setLength(sb.length - 1)
            trailingCollapsed = false
        }
        if (newlines > pending) pending = newlines
    }

    /** Inline text that has already been collapsed. */
    fun collapsed(text: String) {
        var value = text
        if (value.startsWith(' ') && (sb.isEmpty() || pending > 0 || pendingMarker != null || trailingCollapsed)) {
            value = value.substring(1)
        }
        if (value.isEmpty()) return
        flush()
        sb.append(value)
        trailingCollapsed = value.endsWith(' ')
    }

    /** Verbatim text (pre, line breaks, tables). */
    fun raw(text: String) {
        if (text.isEmpty()) return
        flush()
        sb.append(text)
        trailingCollapsed = false
    }

    /** A new list item starts; the marker of an outer item that has no text yet is voided. */
    fun marker(text: String) {
        pendingMarker = text
    }

    /** List item ends: a marker that never landed means the item had no text, so the line is not emitted. */
    fun endItem() {
        pendingMarker = null
    }

    fun text(): String = sb.toString()

    private fun flush() {
        if (pending > 0 && sb.isNotEmpty()) repeat(pending) { sb.append('\n') }
        pending = 0
        pendingMarker?.let {
            sb.append(it)
            pendingMarker = null
        }
    }
}

private class HtmlWalker(private val out: HtmlOut, private val ctx: HtmlContext) : NodeFilter {

    fun walkChildren(element: Element) {
        for (child in element.childNodes()) NodeTraversor.filter(this, child)
    }

    override fun head(node: Node, depth: Int): FilterResult {
        if (node is TextNode) {
            val text = node.wholeText
            if (ctx.preDepth > 0) out.raw(text) else out.collapsed(WHITESPACE.replace(text, " "))
            return FilterResult.CONTINUE
        }
        if (node !is Element) return FilterResult.CONTINUE
        if (isDropped(node)) return FilterResult.SKIP_ENTIRELY

        when (val tag = node.normalName()) {
            "br" -> if (ctx.liDepth > 0 && ctx.cellDepth == 0) out.collapsed(" ") else out.raw("\n")
            "hr" -> {
                out.request(2)
                out.raw("---")
            }
            "table" -> {
                renderTable(node)
                return FilterResult.SKIP_ENTIRELY
            }
            "ul", "ol" -> {
                out.request(listBreak())
                val start = if (tag == "ol") node.attr("start").trim().toIntOrNull() ?: 1 else 0
                ctx.lists.addLast(HtmlContext.ListLevel(tag == "ol", start))
            }
            "li" -> {
                out.request(1)
                val list = ctx.lists.lastOrNull()
                val marker = if (list != null && list.ordered) "${list.next++}. " else "- "
                out.marker("  ".repeat(ctx.liDepth) + marker)
                ctx.liDepth++
            }
            "pre" -> {
                out.request(2)
                ctx.preDepth++
            }
            else -> {
                val level = headingLevel(tag)
                if (level != null && ctx.cellDepth == 0) {
                    renderHeading(node, level)
                    return FilterResult.SKIP_ENTIRELY
                }
                blockBreak(tag)?.let(out::request)
            }
        }
        return FilterResult.CONTINUE
    }

    override fun tail(node: Node, depth: Int): FilterResult {
        if (node !is Element) return FilterResult.CONTINUE
        when (val tag = node.normalName()) {
            "br" -> Unit
            "ul", "ol" -> {
                ctx.lists.removeLastOrNull()
                out.request(listBreak())
            }
            "li" -> {
                ctx.liDepth--
                out.endItem()
                out.request(1)
            }
            "pre" -> {
                ctx.preDepth--
                out.request(2)
            }
            else -> blockBreak(tag)?.let(out::request)
        }
        return FilterResult.CONTINUE
    }

    private fun listBreak(): Int = if (ctx.liDepth > 0) 1 else 2

    private fun renderHeading(element: Element, level: Int) {
        val text = subRender(element).replace('\n', ' ').replace('\t', ' ').trim()
        if (text.isEmpty()) return
        out.request(2)
        out.raw("#".repeat(minOf(level, 6)) + " " + text)
        out.request(2)
    }

    private fun renderTable(table: Element) {
        table.children().filter { it.normalName() == "caption" && !isDropped(it) }
            .forEach { NodeTraversor.filter(this, it) }

        val rows = table.select("tr")
            .filter { row -> owningTable(row) === table && !droppedBetween(row, table) }
            .map { row -> row.children().filter { (it.normalName() == "td" || it.normalName() == "th") && !isDropped(it) } }
            .filter { it.isNotEmpty() }
        if (rows.isEmpty()) return

        val cellLines = rows.map { row -> row.map(::cellLines) }
        if (ctx.cellDepth > 0) {
            // A table nested in a cell is flattened into one paragraph: ` / ` between rows, `; ` between cells.
            val flat = cellLines.joinToString(" / ") { row -> row.joinToString("; ") { it.joinToString(" ") } }.trim()
            if (flat.isEmpty()) return
            out.request(2)
            out.raw(flat)
            out.request(2)
            return
        }

        val spanned = rows.any { row -> row.any { span(it, "colspan") > 1 || span(it, "rowspan") > 1 } }
        if (spanned) {
            // Rows that are entirely empty are dropped.
            val text = cellLines.filter { row -> row.any { it.isNotEmpty() } }.joinToString("\n") { row ->
                row.joinToString("\t") { it.joinToString(" ").replace('\t', ' ') }
            }
            if (text.isBlank()) return
            out.request(2)
            out.raw(text)
            out.request(2)
            return
        }

        when (val table3 = StructuredText.table(cellLines.map { row -> row.map(StructuredText::cellText) })) {
            null -> return
            is StructuredText.TableOutput.Paragraph -> {
                out.request(2)
                out.raw(table3.text)
                out.request(2)
            }
            is StructuredText.TableOutput.Table -> {
                out.request(2)
                out.raw(table3.markdown)
                out.request(2)
                table3.moreColumnsNote?.let {
                    out.raw(it)
                    out.request(2)
                }
            }
        }
    }

    /** Inline text in a cell: block line breaks become paragraph boundaries inside the cell; each paragraph is trimmed and empty ones are dropped. */
    private fun cellLines(cell: Element): List<String> {
        val savedLi = ctx.liDepth
        ctx.liDepth = 0
        ctx.cellDepth++
        try {
            return subRender(cell).split('\n').map { it.trim(' ', '\t') }.filter { it.isNotEmpty() }
        } finally {
            ctx.cellDepth--
            ctx.liDepth = savedLi
        }
    }

    private fun subRender(element: Element): String {
        val sub = HtmlOut()
        HtmlWalker(sub, ctx).walkChildren(element)
        return sub.text()
    }

    private fun owningTable(row: Element): Element? = row.parents().firstOrNull { it.normalName() == "table" }

    private fun droppedBetween(row: Element, table: Element): Boolean {
        var current: Element? = row
        while (current != null && current !== table) {
            if (isDropped(current)) return true
            current = current.parent()
        }
        return false
    }

    private fun span(cell: Element, name: String): Int = cell.attr(name).trim().toIntOrNull() ?: 1

    private fun isDropped(element: Element): Boolean =
        element.normalName() in DROPPED ||
            element.hasAttr("hidden") ||
            element.attr("epub:type").contains("pagebreak")

    private fun headingLevel(tag: String): Int? =
        if (tag.length == 2 && tag[0] == 'h' && tag[1] in '1'..'6') tag[1] - '0' else null

    private fun blockBreak(tag: String): Int? = when (tag) {
        in BREAK_TWO -> 2
        in BREAK_ONE -> 1
        else -> null
    }

    companion object {
        private val WHITESPACE = Regex("[ \\t\\n\\r\\u000C]+")

        private val DROPPED = setOf(
            "script", "style", "noscript", "template", "head", "title", "svg", "math", "iframe", "object",
            "embed", "canvas", "audio", "video", "select", "rp",
        )

        // A heading inside a cell degrades to an ordinary block and issues two newline requests.
        private val BREAK_TWO = setOf(
            "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table", "hr", "dl", "figure", "address",
        )

        private val BREAK_ONE = setOf(
            "div", "li", "dt", "dd", "section", "article", "header", "footer", "nav", "aside", "main", "figcaption",
            "caption", "tr", "form", "fieldset", "legend", "details", "summary", "center",
        )
    }
}
