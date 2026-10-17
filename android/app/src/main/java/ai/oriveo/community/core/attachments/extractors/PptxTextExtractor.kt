package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionDeadline
import ai.oriveo.community.core.attachments.extractors.OoxmlRelationships.targetOf

/** PPTX extraction, attachment extraction spec section 7. */
internal object PptxTextExtractor {
    private val titleTypes = setOf("title", "ctrTitle")
    private val skippedPlaceholders = setOf("sldNum", "dt", "ftr", "hdr", "sldImg")
    private val slidePart = Regex("""^ppt/slides/slide(\d+)\.xml$""", RegexOption.IGNORE_CASE)

    fun extract(zip: ZipPackage, deadline: ExtractionDeadline): String {
        val out = BlockText()
        // Section 7: skip a slide whose referenced part does not exist, without consuming a number.
        var number = 0
        for (part in slideParts(zip)) {
            deadline.check()
            val bytes = zip.read(part) ?: continue
            number++
            val slide = XmlParts.tree(bytes)
            val hidden = slide.attr("show").let { it == "0" || it == "false" }
            val tree = slide.child("p:cSld")?.child("p:spTree")
            val titleShape = tree?.let(::findTitle)
            val title = titleShape?.let { shapeParagraphs(it).joinToString(" ").replace('\n', ' ').trim() }.orEmpty()

            val header = StringBuilder("## Slide $number")
            if (title.isNotEmpty()) header.append(": ").append(title)
            if (hidden) header.append(" (hidden)")
            out.section(header.toString())
            tree?.let { body(it, titleShape, out) }

            val notesPart = OoxmlRelationships.read(zip, part).targetOf("/notesSlide")
            val notes = notesPart?.let { zip.read(it) }?.let { notesParagraphs(XmlParts.tree(it)) }.orEmpty()
            if (notes.any { it.trim(' ', '\t').isNotEmpty() }) {
                out.section("### Notes")
                notes.forEach { out.paragraph(it) }
            }
        }
        return out.render()
    }

    /** Order of sldIdLst in presentation.xml; when missing, ascending by N of `ppt/slides/slideN.xml`. */
    private fun slideParts(zip: ZipPackage): List<String> {
        val presentationPath = OoxmlRelationships.mainPart(zip, "ppt/presentation.xml")
        val presentation = zip.read(presentationPath)
        if (presentation != null) {
            val rels = OoxmlRelationships.read(zip, presentationPath)
            val ids = XmlParts.tree(presentation).child("p:sldIdLst")?.children("p:sldId").orEmpty()
            return ids.mapNotNull { sld -> rels.firstOrNull { it.id == sld.attr("r:id") }?.target }
        }
        return zip.names.mapNotNull { name -> slidePart.matchEntire(name)?.let { it.groupValues[1].toBigInteger() to name } }
            .sortedBy { it.first }
            .map { it.second }
    }

    private fun placeholderType(shape: XNode): String? =
        shape.child("p:nvSpPr")?.child("p:nvPr")?.child("p:ph")?.attr("type")

    /** The first title placeholder shape in document order over the whole shape tree. */
    private fun findTitle(node: XNode): XNode? {
        for (child in shapeChildren(node)) {
            when (child.name) {
                "p:sp" -> if (placeholderType(child) in titleTypes) return child
                "p:grpSp" -> findTitle(child)?.let { return it }
            }
        }
        return null
    }

    /** Child elements; `mc:AlternateContent` only walks the first `mc:Choice`. */
    private fun shapeChildren(node: XNode): List<XNode> =
        node.elements().flatMap { child ->
            if (child.name == "mc:AlternateContent") {
                child.child("mc:Choice")?.let(::shapeChildren).orEmpty()
            } else {
                listOf(child)
            }
        }

    private fun body(node: XNode, titleShape: XNode?, out: BlockText) {
        for (child in shapeChildren(node)) {
            when (child.name) {
                "p:sp" -> {
                    if (child === titleShape || placeholderType(child) in skippedPlaceholders) continue
                    shapeParagraphs(child).forEach { out.paragraph(it) }
                }
                "p:grpSp" -> body(child, titleShape, out)
                "p:graphicFrame" -> child.elements("a:tbl").firstOrNull()?.let { table(it, out) }
            }
        }
    }

    private fun shapeParagraphs(shape: XNode): List<String> =
        shape.child("p:txBody")?.let(::paragraphs).orEmpty()

    private fun paragraphs(txBody: XNode): List<String> =
        txBody.children("a:p").map(::paragraphText)

    private fun paragraphText(p: XNode): String {
        val sb = StringBuilder()
        fun visit(node: XNode) {
            for (child in node.elements()) {
                when (child.name) {
                    "a:r", "a:fld" -> child.children("a:t").forEach { sb.append(it.text()) }
                    "a:br" -> sb.append('\n')
                    "mc:AlternateContent" -> child.child("mc:Choice")?.let(::visit)
                }
            }
        }
        visit(p)
        return sb.toString()
    }

    private fun table(tbl: XNode, out: BlockText) {
        val rows = tbl.children("a:tr").map { tr ->
            tr.children("a:tc").map { tc ->
                val merged = listOf("hMerge", "vMerge").any { tc.attr(it) == "1" || tc.attr(it) == "true" }
                if (merged) "" else StructuredText.cellText(tc.child("a:txBody")?.let(::paragraphs).orEmpty())
            }
        }
        out.table(rows)
    }

    /** Paragraphs of shapes in a notes page whose placeholder type is `body`. */
    private fun notesParagraphs(notes: XNode): List<String> {
        val result = ArrayList<String>()
        fun visit(node: XNode) {
            for (child in shapeChildren(node)) {
                when (child.name) {
                    "p:sp" -> if (placeholderType(child) == "body") result += shapeParagraphs(child)
                    "p:grpSp" -> visit(child)
                }
            }
        }
        notes.child("p:cSld")?.child("p:spTree")?.let(::visit)
        return result
    }
}
