package ai.oriveo.community.ui.component.markdown

import ai.oriveo.community.core.model.QuoteContentKind
import ai.oriveo.community.core.model.QuoteSelectionContent

/**
 * Maps a selection copied out of Compose back to the smallest semantic context that can
 * be trusted.
 *
 * Compose hands back the *rendered* text, with markdown syntax already resolved, so the
 * selection cannot simply be indexed into the source. Instead the source is parsed into
 * blocks, each block is flattened to the same plain form the user saw, and the selection
 * is located in that. A selection is only enriched with surrounding context when it
 * matches exactly once across the whole message; any ambiguity falls back to quoting the
 * selection on its own, because guessing the wrong occurrence would quote text the user
 * never highlighted.
 */
internal object QuoteSelectionMapper {
    private data class Segment(val text: String, val kind: QuoteContentKind)

    /**
     * Locates a selection inside a markdown message.
     *
     * Code and table segments keep their own block as context, since prose either side of
     * them is unrelated. Prose segments additionally pull in the adjacent prose segments,
     * which is usually what makes a quote readable.
     *
     * @param markdown the message source the selection was rendered from.
     * @param renderedSelection the text Compose reported as selected.
     * @return the selection together with whatever surrounding context could be resolved
     *   unambiguously; leading and trailing text are empty when it could not.
     */
    fun capture(markdown: String, renderedSelection: String): QuoteSelectionContent {
        val selected = renderedSelection.replace("\r\n", "\n").replace('\r', '\n').trim()
        val segments = parseBlocks(markdown).flatMap(::segmentsFor).filter { it.text.isNotBlank() }
        val hits = segments.mapIndexedNotNull { index, segment ->
            val offset = segment.text.indexOf(selected)
            if (offset >= 0 && segment.text.indexOf(selected, offset + selected.length) < 0) index to offset else null
        }
        if (selected.isEmpty() || hits.size != 1) return selectedOnly(selected)

        val (index, offset) = hits.single()
        val segment = segments[index]
        if (segment.kind == QuoteContentKind.Code || segment.kind == QuoteContentKind.Table) {
            return QuoteSelectionContent(
                contentKind = segment.kind,
                leadingText = segment.text.substring(0, offset),
                selectedText = selected,
                trailingText = segment.text.substring(offset + selected.length),
            )
        }
        val previous = segments.getOrNull(index - 1)?.takeIf { it.kind == QuoteContentKind.Prose }?.text
        val next = segments.getOrNull(index + 1)?.takeIf { it.kind == QuoteContentKind.Prose }?.text
        return QuoteSelectionContent(
            contentKind = QuoteContentKind.Prose,
            leadingText = listOfNotNull(previous, segment.text.substring(0, offset).takeIf { it.isNotEmpty() })
                .joinToString("\n\n"),
            selectedText = selected,
            trailingText = listOfNotNull(segment.text.substring(offset + selected.length).takeIf { it.isNotEmpty() }, next)
                .joinToString("\n\n"),
        )
    }

    /**
     * The plain-text counterpart of [capture], for messages that are not rendered as
     * markdown. Non-blank lines act as the blocks, and the neighbouring lines supply the
     * context.
     *
     * @param text the message source the selection was rendered from.
     * @param renderedSelection the text Compose reported as selected.
     * @return the selection with its neighbouring lines as context, or the selection
     *   alone when it appears more than once.
     */
    fun capturePlain(text: String, renderedSelection: String): QuoteSelectionContent {
        val selected = renderedSelection.replace("\r\n", "\n").replace('\r', '\n').trim()
        val blocks = text.lines().filter { it.isNotBlank() }
        val hits = blocks.mapIndexedNotNull { index, block ->
            val offset = block.indexOf(selected)
            if (offset >= 0 && block.indexOf(selected, offset + selected.length) < 0) index to offset else null
        }
        if (selected.isEmpty() || hits.size != 1) return selectedOnly(selected)
        val (index, offset) = hits.single()
        val block = blocks[index]
        return QuoteSelectionContent(
            contentKind = QuoteContentKind.Prose,
            leadingText = listOfNotNull(
                blocks.getOrNull(index - 1),
                block.substring(0, offset).takeIf { it.isNotEmpty() },
            ).joinToString("\n\n"),
            selectedText = selected,
            trailingText = listOfNotNull(
                block.substring(offset + selected.length).takeIf { it.isNotEmpty() },
                blocks.getOrNull(index + 1),
            ).joinToString("\n\n"),
        )
    }

    private fun segmentsFor(block: MarkdownBlock): List<Segment> = when (block) {
        is MarkdownBlock.CodeBlock -> listOf(Segment(block.code, QuoteContentKind.Code))
        is MarkdownBlock.Table -> (listOf(block.headers) + block.rows).map { row ->
            Segment(row.joinToString(" | ") { it.trim() }, QuoteContentKind.Table)
        }
        is MarkdownBlock.MathBlock -> listOf(Segment("$$${block.latex}$$", QuoteContentKind.Prose))
        is MarkdownBlock.Heading -> listOf(Segment(MarkdownRenderer.plainText(block.text), QuoteContentKind.Prose))
        is MarkdownBlock.BlockQuote -> listOf(Segment(MarkdownRenderer.plainText(block.text), QuoteContentKind.Prose))
        is MarkdownBlock.ListItem -> listOf(Segment(MarkdownRenderer.plainText(block.text), QuoteContentKind.Prose))
        is MarkdownBlock.Paragraph -> listOf(Segment(MarkdownRenderer.plainText(block.text), QuoteContentKind.Prose))
        MarkdownBlock.HorizontalRule -> emptyList()
    }

    private fun selectedOnly(selected: String) = QuoteSelectionContent(
        contentKind = QuoteContentKind.Prose,
        leadingText = "",
        selectedText = selected,
        trailingText = "",
    )
}
