package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionDeadline
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import ai.oriveo.community.core.attachments.extractors.OoxmlRelationships.targetOf

/** DOCX extraction, attachment extraction spec section 5. */
internal object DocxTextExtractor {
    private val skipped = setOf(
        "w:del", "w:moveFrom", "mc:Fallback", "w:pPr", "w:rPr", "w:delText", "w:instrText", "w:fldData",
        "w:sdtPr", "w:sdtEndPr",
    )
    /** Output never taken while a field is in the "instruction" state (section 5). */
    private val fieldOutputs = setOf(
        "w:t", "w:tab", "w:br", "w:cr", "w:noBreakHyphen", "w:footnoteReference", "w:endnoteReference", "w:txbxContent",
    )
    private val headingName = Regex("""^heading ([1-9])$""")
    private const val MAX_BASED_ON = 10

    fun extract(zip: ZipPackage, deadline: ExtractionDeadline): String {
        val main = OoxmlRelationships.mainPart(zip, "word/document.xml")
        val document = zip.read(main) ?: throw ExtractionException(ExtractionErrorCode.CorruptedFile)
        val rels = OoxmlRelationships.read(zip, main)
        fun part(suffix: String, fallback: String): ByteArray? =
            rels.targetOf(suffix)?.let { zip.read(it) } ?: zip.read(fallback)

        val styles = part("/styles", "word/styles.xml")?.let { parseStyles(XmlParts.tree(it)) }.orEmpty()
        val numbering = part("/numbering", "word/numbering.xml")?.let { parseNumbering(XmlParts.tree(it)) }
        val converter = Converter(styles, numbering)

        val out = BlockText()
        XmlParts.stream(
            document,
            capture = { _, ancestors -> ancestors.size == 2 && ancestors[1] == "w:body" },
            onCaptured = { node, _ ->
                deadline.check()
                converter.block(node, out)
            },
        )

        if (converter.noteRefs.isNotEmpty()) {
            val footnotes = part("/footnotes", "word/footnotes.xml")?.let { parseNotes(XmlParts.tree(it), "w:footnote") }.orEmpty()
            val endnotes = part("/endnotes", "word/endnotes.xml")?.let { parseNotes(XmlParts.tree(it), "w:endnote") }.orEmpty()
            var first = true
            for (ref in converter.noteRefs) {
                val endnote = ref.startsWith("e")
                val note = (if (endnote) endnotes[ref.substring(1)] else footnotes[ref]) ?: continue
                val text = Converter(styles, numbering, notesMode = true).noteText(note)
                out.paragraph("[^$ref]: $text", blankBefore = first)
                first = false
            }
        }
        return out.render()
    }

    // region styles and numbering

    private class Style(val name: String?, val basedOn: String?, val outlineLevel: Int?)

    private fun parseStyles(root: XNode): Map<String, Style> =
        root.children("w:style").mapNotNull { style ->
            val id = style.attr("w:styleId") ?: return@mapNotNull null
            id to Style(
                name = style.child("w:name")?.attr("w:val"),
                basedOn = style.child("w:basedOn")?.attr("w:val"),
                outlineLevel = style.child("w:pPr")?.child("w:outlineLvl")?.attr("w:val")?.toIntOrNull(),
            )
        }.toMap()

    private class Level(val format: String?, val start: Int)

    private class Numbering(val nums: Map<String, String>, val abstracts: Map<String, Map<Int, Level>>)

    private fun parseNumbering(root: XNode): Numbering {
        val abstracts = root.children("w:abstractNum").mapNotNull { abstract ->
            val id = abstract.attr("w:abstractNumId") ?: return@mapNotNull null
            id to abstract.children("w:lvl").mapNotNull { lvl ->
                val ilvl = lvl.attr("w:ilvl")?.toIntOrNull() ?: return@mapNotNull null
                ilvl to Level(
                    format = lvl.child("w:numFmt")?.attr("w:val"),
                    start = lvl.child("w:start")?.attr("w:val")?.toIntOrNull() ?: 1,
                )
            }.toMap()
        }.toMap()
        val nums = root.children("w:num").mapNotNull { num ->
            val id = num.attr("w:numId") ?: return@mapNotNull null
            val abstractId = num.child("w:abstractNumId")?.attr("w:val") ?: return@mapNotNull null
            id to abstractId
        }.toMap()
        return Numbering(nums, abstracts)
    }

    /** id -> note node; `separator` / `continuationSeparator` are skipped. */
    private fun parseNotes(root: XNode, element: String): Map<String, XNode> =
        root.children(element).mapNotNull { note ->
            val type = note.attr("w:type")
            if (type == "separator" || type == "continuationSeparator") return@mapNotNull null
            note.attr("w:id")?.let { it to note }
        }.toMap()

    // endregion

    private class Converter(
        private val styles: Map<String, Style>,
        private val numbering: Numbering?,
        private val notesMode: Boolean = false,
    ) {
        /** Field stack: true = instruction state. Shared across the whole part, kept across paragraphs and tables. */
        private val fieldStack = ArrayDeque<Boolean>()
        private val counters = HashMap<String, MutableMap<Int, Int>>()

        /** Notes referenced in the body, in order of first reference; endnotes carry an `e` prefix. */
        val noteRefs = LinkedHashSet<String>()

        fun block(node: XNode, out: BlockText) {
            when (node.name) {
                "w:p" -> paragraph(node, out)
                "w:tbl" -> table(node, out)
                "w:sdt" -> node.child("w:sdtContent")?.elements()?.forEach { block(it, out) }
            }
        }

        fun noteText(note: XNode): String {
            val parts = ArrayList<String>()
            collectParagraphs(note) { p -> parts += paragraphText(p, BlockText()).trim(' ', '\t') }
            return parts.filter { it.isNotEmpty() }.joinToString(" ")
        }

        private fun collectParagraphs(node: XNode, onParagraph: (XNode) -> Unit) {
            for (child in node.elements()) {
                when (child.name) {
                    "w:p" -> onParagraph(child)
                    "w:sdt" -> child.child("w:sdtContent")?.let { collectParagraphs(it, onParagraph) }
                    "w:tbl" -> collectParagraphs(child, onParagraph)
                    "w:tr", "w:tc" -> collectParagraphs(child, onParagraph)
                }
            }
        }

        private fun paragraph(p: XNode, out: BlockText) {
            val after = BlockText()
            val text = paragraphText(p, after)
            val pPr = p.child("w:pPr")
            val heading = headingLevel(pPr)
            when {
                heading != null -> out.heading(heading, text)
                else -> {
                    val marker = listMarker(pPr)
                    if (marker != null) out.listItem(marker.first, marker.second, text) else out.paragraph(text)
                }
            }
            out.addAll(after)
        }

        private fun paragraphText(p: XNode, after: BlockText): String {
            val sb = StringBuilder()
            inline(p, sb, after)
            return sb.toString()
        }

        private fun inline(node: XNode, sb: StringBuilder, after: BlockText) {
            for (child in node.children) {
                if (child !is XNode) continue
                if (child.name in fieldOutputs && fieldStack.any { it }) continue
                when (child.name) {
                    in skipped -> Unit
                    "w:r" -> if (!isHiddenRun(child)) inline(child, sb, after)
                    "mc:AlternateContent" -> child.child("mc:Choice")?.let { inline(it, sb, after) }
                    "w:t" -> sb.append(child.text())
                    "w:tab" -> sb.append('\t')
                    "w:br", "w:cr" -> sb.append('\n')
                    "w:noBreakHyphen" -> sb.append('-')
                    "w:softHyphen", "w:sym", "w:footnoteRef", "w:endnoteRef" -> Unit
                    "w:footnoteReference" -> child.attr("w:id")?.let { id ->
                        sb.append("[^").append(id).append(']')
                        if (!notesMode) noteRefs += id
                    }
                    "w:endnoteReference" -> child.attr("w:id")?.let { id ->
                        sb.append("[^e").append(id).append(']')
                        if (!notesMode) noteRefs += "e$id"
                    }
                    "w:fldChar" -> when (child.attr("w:fldCharType")) {
                        "begin" -> fieldStack.addLast(true)
                        "separate" -> if (fieldStack.isNotEmpty()) fieldStack[fieldStack.lastIndex] = false
                        "end" -> fieldStack.removeLastOrNull()
                    }
                    "w:txbxContent" -> child.elements().forEach { block(it, after) }
                    else -> inline(child, sb, after)
                }
            }
        }

        private fun isHiddenRun(run: XNode): Boolean {
            val vanish = run.child("w:rPr")?.child("w:vanish") ?: return false
            val value = vanish.attr("w:val") ?: return true
            return value != "0" && value != "false"
        }

        private fun styleChain(styleId: String?): List<Style> {
            val chain = ArrayList<Style>()
            var id = styleId
            while (id != null && chain.size <= MAX_BASED_ON) {
                val style = styles[id] ?: break
                chain += style
                id = style.basedOn
            }
            return chain
        }

        private fun headingLevel(pPr: XNode?): Int? {
            pPr?.child("w:outlineLvl")?.attr("w:val")?.toIntOrNull()?.let { if (it in 0..8) return it + 1 }
            val chain = styleChain(pPr?.child("w:pStyle")?.attr("w:val"))
            for (style in chain) {
                val name = style.name?.lowercase() ?: continue
                headingName.matchEntire(name)?.let { return it.groupValues[1].toInt() }
                if (name == "title") return 1
            }
            val outline = chain.firstNotNullOfOrNull { it.outlineLevel }
            return if (outline != null && outline in 0..8) outline + 1 else null
        }

        /** A list item returns (depth, marker); a non-list item returns null. */
        private fun listMarker(pPr: XNode?): Pair<Int, String>? {
            val numPr = pPr?.child("w:numPr") ?: return null
            val numId = numPr.child("w:numId")?.attr("w:val") ?: return null
            if (numId == "0") return null
            val ilvl = numPr.child("w:ilvl")?.attr("w:val")?.toIntOrNull() ?: 0
            val level = numbering?.nums?.get(numId)?.let { numbering.abstracts[it] }?.get(ilvl)
                ?: return ilvl to "- "
            return when (level.format) {
                "bullet" -> ilvl to "- "
                "none" -> null
                else -> {
                    val levels = counters.getOrPut(numId) { HashMap() }
                    val value = levels[ilvl]?.plus(1) ?: level.start
                    levels[ilvl] = value
                    levels.keys.removeAll { it > ilvl }
                    ilvl to "$value. "
                }
            }
        }

        private fun table(tbl: XNode, out: BlockText) {
            out.table(rows(tbl).map { row -> row.map { StructuredText.cellText(it) } })
        }

        /** Each cell is a list of the paragraph texts inside it; nested tables are flattened into one paragraph. */
        private fun rows(tbl: XNode): List<List<List<String>>> {
            val rows = ArrayList<List<List<String>>>()
            forEachIn(tbl, "w:tr") { tr ->
                val cells = ArrayList<List<String>>()
                forEachIn(tr, "w:tc") { tc ->
                    val tcPr = tc.child("w:tcPr")
                    val vMerge = tcPr?.child("w:vMerge")
                    val continued = vMerge != null && vMerge.attr("w:val") != "restart"
                    cells += if (continued) emptyList() else cellParagraphs(tc)
                    val span = tcPr?.child("w:gridSpan")?.attr("w:val")?.toIntOrNull() ?: 1
                    repeat((span - 1).coerceAtLeast(0)) { cells += emptyList<String>() }
                }
                rows += cells
            }
            return rows
        }

        /** Direct child elements named [name]; `w:sdt` recurses into `w:sdtContent`. */
        private fun forEachIn(node: XNode, name: String, action: (XNode) -> Unit) {
            for (child in node.elements()) {
                when (child.name) {
                    name -> action(child)
                    "w:sdt" -> child.child("w:sdtContent")?.let { forEachIn(it, name, action) }
                }
            }
        }

        private fun cellParagraphs(container: XNode): List<String> {
            val parts = ArrayList<String>()
            for (child in container.elements()) {
                when (child.name) {
                    "w:p" -> {
                        val after = BlockText()
                        parts += paragraphText(child, after)
                        if (!after.isEmpty) parts += after.render()
                    }
                    "w:tbl" -> parts += rows(child).joinToString(" / ") { row ->
                        row.joinToString("; ") { cell -> cell.map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" ") }
                    }
                    "w:sdt" -> child.child("w:sdtContent")?.let { parts += cellParagraphs(it) }
                }
            }
            return parts
        }
    }
}
