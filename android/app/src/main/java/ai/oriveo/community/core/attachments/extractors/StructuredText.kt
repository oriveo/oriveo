package ai.oriveo.community.core.attachments.extractors

/**
 * Common output rules for structured formats (attachment extraction spec section 3.1 normalization, section 3.3 tables).
 */
internal object StructuredText {
    const val MAX_TABLE_COLUMNS = 50

    private val trailingBlanks = Regex("[ \\t]+(?=\\n|$)")
    private val blankLineRuns = Regex("\\n{3,}")

    /** Section 3.1: unify line breaks -> NBSP becomes a normal space -> strip trailing whitespace on lines -> at most one blank line -> trim the whole text. */
    fun normalize(text: String): String =
        text.replace("\r\n", "\n").replace('\r', '\n')
            .replace(' ', ' ')
            .replace(trailingBlanks, "")
            .replace(blankLineRuns, "\n\n")
            .trim()

    /**
     * Section 3.3 cell text: trim each paragraph (including `\r` `\n`), drop empty ones, join the rest with `<br>`;
     * leftover line breaks -> `<br>`, `\t` -> space, `|` -> `\|`, finally trim.
     */
    fun cellText(paragraphs: List<String>): String =
        paragraphs.map { it.trim(' ', '\t', '\r', '\n') }.filter { it.isNotEmpty() }.joinToString("<br>")
            .replace("\r\n", "<br>").replace("\r", "<br>").replace("\n", "<br>")
            .replace('\t', ' ')
            .replace("|", "\\|")
            .trim()

    sealed interface TableOutput {
        /** Pipe table; beyond [MAX_TABLE_COLUMNS] columns, [moreColumnsNote] is a paragraph right after the table. */
        data class Table(val markdown: String, val moreColumnsNote: String?) : TableOutput

        /** Only 1 row and 1 column: the cell text becomes a paragraph (`<br>` restored to `\n`). */
        data class Paragraph(val text: String) : TableOutput
    }

    /**
     * Section 3.3: [rows] are cell texts that already went through [cellText]. Returns null if all cells are empty (the whole block is dropped).
     */
    fun table(rows: List<List<String>>): TableOutput? {
        if (rows.all { row -> row.all { it.isEmpty() } }) return null
        val columns = rows.maxOf { it.size }
        if (rows.size == 1 && columns == 1) return TableOutput.Paragraph(rows[0][0].replace("<br>", "\n"))

        val kept = minOf(columns, MAX_TABLE_COLUMNS)
        val lines = ArrayList<String>(rows.size + 1)
        rows.forEachIndexed { index, row ->
            val cells = List(kept) { column -> row.getOrElse(column) { "" } }
            lines += "| " + cells.joinToString(" | ") + " |"
            if (index == 0) lines += "| " + List(kept) { "---" }.joinToString(" | ") + " |"
        }
        val note = if (columns > kept) "(${columns - kept} more columns not shown)" else null
        return TableOutput.Table(lines.joinToString("\n"), note)
    }
}
