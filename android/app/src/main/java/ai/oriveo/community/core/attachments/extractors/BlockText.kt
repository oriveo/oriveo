package ai.oriveo.community.core.attachments.extractors

/**
 * Block output for OOXML / ODF (spec section 3.2): paragraph, heading, list item, table, section heading, notes heading.
 * A blank line separates two adjacent blocks if either is a heading / table / section heading / notes heading; otherwise just a line break.
 */
internal class BlockText {
    private class Block(val text: String, val loose: Boolean, val blankBefore: Boolean)

    private val blocks = ArrayList<Block>()

    val isEmpty: Boolean get() = blocks.isEmpty()

    /** Paragraph: trim spaces and `\t`, drop if empty; inner `\n` is kept. [blankBefore] is for the first footnote-area entry. */
    fun paragraph(text: String, blankBefore: Boolean = false) {
        val trimmed = text.trim(' ', '\t')
        if (trimmed.isNotEmpty()) blocks += Block(trimmed, loose = false, blankBefore = blankBefore)
    }

    /** Heading: `#` x min(level, 6); `\n` `\t` in the text become spaces, then trim; drop if empty. */
    fun heading(level: Int, text: String) {
        val clean = text.replace('\n', ' ').replace('\t', ' ').trim()
        if (clean.isEmpty()) return
        blocks += Block("#".repeat(level.coerceIn(1, 6)) + " " + clean, loose = true, blankBefore = false)
    }

    /** List item: two spaces x depth + marker + text (`\n` becomes a space). */
    fun listItem(depth: Int, marker: String, text: String) {
        val trimmed = text.trim(' ', '\t')
        if (trimmed.isEmpty()) return
        blocks += Block("  ".repeat(depth.coerceAtLeast(0)) + marker + trimmed.replace('\n', ' '), loose = false, blankBefore = false)
    }

    /** Section heading (`## Sheet:` / `## Slide`) and notes heading (`### Notes`), emitted verbatim. */
    fun section(text: String) {
        blocks += Block(text, loose = true, blankBefore = false)
    }

    /** Section 3.3: [rows] are cell texts that already went through [StructuredText.cellText]. */
    fun table(rows: List<List<String>>) {
        if (rows.isEmpty()) return
        when (val output = StructuredText.table(rows)) {
            null -> Unit
            is StructuredText.TableOutput.Paragraph -> paragraph(output.text)
            is StructuredText.TableOutput.Table -> {
                blocks += Block(output.markdown, loose = true, blankBefore = false)
                output.moreColumnsNote?.let { paragraph(it) }
            }
        }
    }

    /** Table rows are already cut to 50 columns; the caller computes the overflow from the full width (the used range of XLSX / ODS). */
    fun table(rows: List<List<String>>, fullWidth: Int) {
        if (rows.isEmpty()) return
        when (val output = StructuredText.table(rows.map { it.take(StructuredText.MAX_TABLE_COLUMNS) })) {
            null -> Unit
            is StructuredText.TableOutput.Paragraph -> paragraph(output.text)
            is StructuredText.TableOutput.Table -> {
                blocks += Block(output.markdown, loose = true, blankBefore = false)
                if (fullWidth > StructuredText.MAX_TABLE_COLUMNS) {
                    paragraph("(${fullWidth - StructuredText.MAX_TABLE_COLUMNS} more columns not shown)")
                }
            }
        }
    }

    fun addAll(other: BlockText) {
        blocks += other.blocks
    }

    /** Concatenate and apply section 3.1 normalization. */
    fun render(): String {
        val out = StringBuilder()
        blocks.forEachIndexed { index, block ->
            if (index > 0) {
                val previous = blocks[index - 1]
                out.append(if (previous.loose || block.loose || block.blankBefore) "\n\n" else "\n")
            }
            out.append(block.text)
        }
        return StructuredText.normalize(out.toString())
    }
}
