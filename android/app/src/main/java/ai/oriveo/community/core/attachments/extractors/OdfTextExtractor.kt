package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionDeadline
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException

/**
 * Text extraction for ODF formats (ODT / ODS / ODP), spec section 9: read only `content.xml`, walk `office:body` in document order.
 */
object OdfTextExtractor {
    private const val ROWS_PER_DEADLINE_CHECK = 1000
    private const val MAX_REPEATED_ROWS = 100
    private val whitespace = Regex("[ \\t\\n\\r]+")
    private val skipped = setOf(
        "office:annotation", "office:annotation-end", "text:tracked-changes", "text:sequence-decls",
        "text:variable-decls", "office:forms", "svg:title", "svg:desc",
    )
    private val skippedFrameClasses = setOf("page-number", "date-time", "footer", "header")

    @Throws(ExtractionException::class)
    fun extract(
        data: ByteArray,
        @Suppress("UNUSED_PARAMETER") fileExtension: String,
        deadline: ExtractionDeadline = ExtractionDeadline(),
    ): String {
        val zip = ZipPackage.open(data, deadline, "ODF")
        val content = zip.read("content.xml") ?: throw ExtractionException(ExtractionErrorCode.CorruptedFile)
        val out = BlockText()
        val text = TextConverter()
        val sheets = SheetReader(out, text, deadline)
        var slide = 0

        XmlParts.stream(
            content,
            capture = { name, ancestors ->
                val parent = ancestors.lastOrNull()
                when {
                    parent == "office:text" -> true
                    parent == "office:presentation" && name == "draw:page" -> true
                    name == "table:table-row" -> sheets.active
                    // Things in a table outside rows (such as table:table-column) are not needed
                    else -> false
                }
            },
            onStart = { name, attrs, ancestors ->
                if (name == "table:table" && ancestors.lastOrNull() == "office:spreadsheet") sheets.begin(attrs)
            },
            onEnd = { name, ancestors ->
                if (name == "table:table" && ancestors.lastOrNull() == "office:spreadsheet") sheets.end()
            },
            onCaptured = { node, _ ->
                when (node.name) {
                    "table:table-row" -> sheets.row(node)
                    "draw:page" -> {
                        deadline.check()
                        slide++
                        page(node, slide, text, out)
                    }
                    else -> text.block(node, out, listDepth = -1)
                }
            },
        )
        text.appendNotes(out)
        return out.render()
    }

    private fun isSkipped(node: XNode): Boolean = node.name in skipped || node.local.endsWith("-source")

    // region text (shared by ODT and ODP text boxes)

    private class TextConverter {
        private val notes = ArrayList<Pair<String, String>>()

        /** Block-level element. [listDepth] is the depth of the enclosing `text:list` (-1 if not in a list). */
        fun block(node: XNode, out: BlockText, listDepth: Int) {
            if (isSkipped(node)) return
            when (node.name) {
                "text:h" -> paragraphLike(node, out) { text ->
                    if (listDepth >= 0) {
                        out.listItem(listDepth, "- ", text)
                    } else {
                        out.heading(node.attr("text:outline-level")?.toIntOrNull() ?: 1, text)
                    }
                }
                "text:p" -> paragraphLike(node, out) { text ->
                    if (listDepth >= 0) out.listItem(listDepth, "- ", text) else out.paragraph(text)
                }
                "text:list" -> node.elements().forEach { child ->
                    when (child.name) {
                        "text:list-item" -> child.elements().forEach { block(it, out, listDepth + 1) }
                        "text:list-header" -> child.elements().forEach { block(it, out, -1) }
                        else -> block(child, out, listDepth)
                    }
                }
                "table:table" -> table(node, out)
                else -> node.elements().forEach { block(it, out, listDepth) }
            }
        }

        private fun paragraphLike(node: XNode, out: BlockText, emit: (String) -> Unit) {
            val after = BlockText()
            val text = inline(node, after)
            emit(text)
            out.addAll(after)
        }

        /** Text inside a paragraph; paragraphs in text boxes are written into [after], placed after the enclosing paragraph. */
        fun inline(node: XNode, after: BlockText): String {
            val sb = StringBuilder()
            fun visit(element: XNode) {
                for (child in element.children) {
                    if (child is String) {
                        sb.append(whitespace.replace(child, " "))
                        continue
                    }
                    child as XNode
                    if (isSkipped(child)) continue
                    when (child.name) {
                        "text:s" -> sb.append(" ".repeat((child.attr("text:c")?.toIntOrNull() ?: 1).coerceAtLeast(0)))
                        "text:tab" -> sb.append('\t')
                        "text:line-break" -> sb.append('\n')
                        "text:soft-page-break" -> Unit
                        "text:note" -> {
                            val citation = child.child("text:note-citation")?.let { inline(it, BlockText()) }?.trim().orEmpty()
                            sb.append("[^").append(citation).append(']')
                            val body = child.child("text:note-body")?.let(::noteParagraphs).orEmpty()
                            notes += citation to body.map { it.trim(' ', '\t') }.filter { it.isNotEmpty() }.joinToString(" ")
                        }
                        "draw:text-box" -> child.elements().forEach { block(it, after, -1) }
                        else -> visit(child)
                    }
                }
            }
            visit(node)
            return sb.toString()
        }

        private fun noteParagraphs(body: XNode): List<String> {
            val result = ArrayList<String>()
            fun visit(node: XNode) {
                for (child in node.elements()) {
                    if (isSkipped(child)) continue
                    if (child.name == "text:p" || child.name == "text:h") result += inline(child, BlockText()) else visit(child)
                }
            }
            visit(body)
            return result
        }

        /**
         * ODT / ODP table (section 9): a cell is its paragraphs joined with `<br>`; nested tables are flattened into one paragraph.
         * Repeated columns / rows work as in ODS: an empty repeat only lands if content follows, a non-empty row repeats at most [MAX_REPEATED_ROWS] times;
         * no trimming to the used range. Beyond 50 columns, the number of cut columns is given from the width fully computed with repeat counts.
         */
        fun table(table: XNode, out: BlockText) {
            val rows = ArrayList<List<String>>()
            var width = 0L
            var pendingEmptyRows = 0L
            for (row in rowsOf(table)) {
                val cells = cellsOf(row) { StructuredText.cellText(cellParagraphs(it)) }
                val repeat = (row.attr("table:number-rows-repeated")?.toLongOrNull() ?: 1L).coerceAtLeast(1L)
                if (cells.values.isEmpty()) {
                    pendingEmptyRows += repeat
                    continue
                }
                // Landed empty rows are capped by the same limit as non-empty rows, so one huge empty repeat cannot blow up the output.
                repeat(minOf(pendingEmptyRows, MAX_REPEATED_ROWS.toLong()).toInt()) { rows += emptyList<String>() }
                pendingEmptyRows = 0
                repeat(minOf(repeat, MAX_REPEATED_ROWS.toLong()).toInt()) { rows += cells.values }
                width = maxOf(width, cells.width)
            }
            out.table(rows, width.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
        }

        /** ODS cell value: the `text:p` elements joined with `<br>`; without `text:p`, value attributes are tried in turn. */
        fun sheetCellText(cell: XNode): String {
            val paragraphs = cellParagraphs(cell)
            if (paragraphs.isNotEmpty()) return StructuredText.cellText(paragraphs)
            val value = listOf(
                "office:string-value", "office:value", "office:date-value", "office:time-value", "office:boolean-value",
            ).firstNotNullOfOrNull { cell.attr(it) }
            return StructuredText.cellText(listOfNotNull(value))
        }

        private fun cellParagraphs(cell: XNode): List<String> {
            val result = ArrayList<String>()
            for (child in cell.elements()) {
                if (isSkipped(child)) continue
                when (child.name) {
                    "text:p", "text:h" -> result += inline(child, BlockText())
                    "table:table" -> result += rowsOf(child).joinToString(" / ") { row ->
                        cellsOf(row) { cell ->
                            cellParagraphs(cell).map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" ")
                        }.values.joinToString("; ")
                    }
                    else -> result += cellParagraphs(child)
                }
            }
            return result
        }

        fun appendNotes(out: BlockText) {
            notes.forEachIndexed { index, (citation, text) ->
                out.paragraph("[^$citation]: $text", blankBefore = index == 0)
            }
        }
    }

    /** A row can be at any depth (header rows, row groups). */
    private fun rowsOf(table: XNode): List<XNode> {
        val rows = ArrayList<XNode>()
        fun visit(node: XNode) {
            for (child in node.elements()) {
                when (child.name) {
                    "table:table-row" -> rows += child
                    "table:table-header-rows", "table:table-rows", "table:table-row-group" -> visit(child)
                }
            }
        }
        visit(table)
        return rows
    }

    /** The cells landed for a row (at most 50 columns) and the width fully computed with repeat counts (up to the last non-empty cell). */
    private class RowCells(val values: List<String>, val width: Long)

    /** Cell texts of a row; `covered-table-cell` is empty. An empty cell's repeat only lands if content follows; a non-empty cell goes up to column 50 at most. */
    private fun cellsOf(row: XNode, textOf: (XNode) -> String): RowCells {
        val cells = ArrayList<String>()
        var width = 0L
        var pendingEmpty = 0L
        for (cell in row.elements()) {
            if (cell.name != "table:table-cell" && cell.name != "table:covered-table-cell") continue
            val repeat = (cell.attr("table:number-columns-repeated")?.toLongOrNull() ?: 1L).coerceAtLeast(1L)
            val text = if (cell.name == "table:covered-table-cell") "" else textOf(cell)
            if (text.isEmpty()) {
                pendingEmpty += repeat
                continue
            }
            val room = (StructuredText.MAX_TABLE_COLUMNS - cells.size).toLong()
            repeat(minOf(pendingEmpty, room).toInt()) { cells += "" }
            val copies = minOf(repeat, (StructuredText.MAX_TABLE_COLUMNS - cells.size).toLong()).toInt()
            repeat(copies) { cells += text }
            width += pendingEmpty + repeat
            pendingEmpty = 0
        }
        return RowCells(cells, width)
    }

    // endregion

    // region ODS

    private class SheetReader(
        private val out: BlockText,
        private val text: TextConverter,
        private val deadline: ExtractionDeadline,
    ) {
        var active = false
            private set
        private val rows = java.util.TreeMap<Int, java.util.TreeMap<Int, String>>()
        private var rowIndex = 0
        private var rowsSeen = 0
        private var minColumn = Int.MAX_VALUE
        private var maxColumn = 0

        fun begin(attrs: Map<String, String>) {
            deadline.check()
            active = true
            rows.clear()
            rowIndex = 0
            minColumn = Int.MAX_VALUE
            maxColumn = 0
            out.section("## Sheet: ${attrs["table:name"].orEmpty()}")
        }

        fun row(row: XNode) {
            if (rowsSeen++ % ROWS_PER_DEADLINE_CHECK == 0) deadline.check()
            val repeat = (row.attr("table:number-rows-repeated")?.toIntOrNull() ?: 1).coerceAtLeast(1)
            val cells = TreeMapRow()
            var column = 0
            for (cell in row.elements()) {
                if (cell.name != "table:table-cell" && cell.name != "table:covered-table-cell") continue
                val span = (cell.attr("table:number-columns-repeated")?.toLong() ?: 1L).coerceAtLeast(1L)
                val value = if (cell.name == "table:covered-table-cell") "" else text.sheetCellText(cell)
                if (value.isNotEmpty()) {
                    val first = column + 1
                    val last = (column + span).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                    minColumn = minOf(minColumn, first)
                    maxColumn = maxOf(maxColumn, last)
                    for (c in first..minOf(last, StructuredText.MAX_TABLE_COLUMNS)) cells[c] = value
                    if (first > StructuredText.MAX_TABLE_COLUMNS) cells.overflow = true
                }
                column = (column + span).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            }
            if (cells.isEmpty() && !cells.overflow) {
                rowIndex += repeat
                return
            }
            val copies = minOf(repeat, MAX_REPEATED_ROWS)
            repeat(copies) { offset -> rows[rowIndex + 1 + offset] = cells.values }
            rowIndex += repeat
        }

        fun end() {
            active = false
            if (rows.isEmpty()) return
            val width = maxColumn - minColumn + 1
            val kept = minOf(width, StructuredText.MAX_TABLE_COLUMNS)
            val table = ArrayList<List<String>>()
            var previous: Int? = null
            for ((rowNumber, cells) in rows) {
                if (previous != null && rowNumber > previous + 1) table += List(kept) { "" }
                table += List(kept) { offset -> cells[minColumn + offset].orEmpty() }
                previous = rowNumber
            }
            out.table(table, width)
        }
    }

    private class TreeMapRow {
        val values = java.util.TreeMap<Int, String>()
        var overflow = false
        fun isEmpty() = values.isEmpty()
        operator fun set(column: Int, value: String) {
            values[column] = value
        }
    }

    // endregion

    // region ODP

    private fun page(page: XNode, number: Int, text: TextConverter, out: BlockText) {
        val frames = ArrayList<XNode>()
        fun collect(node: XNode) {
            for (child in node.elements()) {
                if (isSkipped(child) || child.name == "presentation:notes") continue
                if (child.name == "draw:frame") frames += child else if (child.name == "draw:g") collect(child)
            }
        }
        collect(page)
        val titleFrame = frames.firstOrNull { it.attr("presentation:class") == "title" }
        val title = titleFrame?.let { frameParagraphs(it, text).joinToString(" ").replace('\n', ' ').trim() }.orEmpty()
        out.section(if (title.isEmpty()) "## Slide $number" else "## Slide $number: $title")

        for (frame in frames) {
            if (frame === titleFrame || frame.attr("presentation:class") in skippedFrameClasses) continue
            frameBody(frame, text, out)
        }

        val notes = BlockText()
        page.child("presentation:notes")?.let { notesNode ->
            notesNode.elements("draw:frame").filter { it.attr("presentation:class") == "notes" }
                .forEach { frameBody(it, text, notes) }
        }
        if (!notes.isEmpty) {
            out.section("### Notes")
            out.addAll(notes)
        }
    }

    private fun frameBody(frame: XNode, text: TextConverter, out: BlockText) {
        for (child in frame.elements()) {
            when (child.name) {
                "draw:text-box" -> child.elements().forEach { text.block(it, out, -1) }
                "table:table" -> text.table(child, out)
            }
        }
    }

    private fun frameParagraphs(frame: XNode, text: TextConverter): List<String> =
        frame.child("draw:text-box")?.elements("text:p").orEmpty().map { text.inline(it, BlockText()) }

    // endregion
}
