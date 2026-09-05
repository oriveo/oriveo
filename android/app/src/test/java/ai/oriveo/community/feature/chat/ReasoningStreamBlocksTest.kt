package ai.oriveo.community.feature.chat

import ai.oriveo.community.feature.chat.components.ReasoningBlockSplitter
import ai.oriveo.community.feature.chat.components.reasoningSafePrefix
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behavior lock for the expanded reasoning stream's stable block splitting plus safe prefix.
 *
 * Two invariants:
 * - **Raw markers never reach the screen**: an unclosed `**` / `##` / table skeleton is held
 *   back until its shape is settled.
 * - **Cost is O(total input)**: once a block is sealed it never changes again (so `remember`
 *   can rely on it), and the tail does not grow with the total reasoning length (it is the
 *   only part re-parsed every frame; growing with the total would regress to O(n^2)).
 */
class ReasoningStreamBlocksTest {

    /** Feed input in chunks of a given size, simulating real chunk arrival */
    private fun feed(text: String, chunkSize: Int): Pair<List<String>, String> {
        val splitter = ReasoningBlockSplitter()
        var blocks: List<String> = emptyList()
        var tail = ""
        var i = 0
        while (i < text.length) {
            val end = minOf(i + chunkSize, text.length)
            val split = splitter.advance(text.substring(0, end))
            blocks = split.blocks
            tail = split.tail
            i = end
        }
        return blocks to tail
    }

    // MARK: - Block splitting

    @Test
    fun `blank line closes a block, last segment stays in tail`() {
        val (blocks, tail) = feed("first block\n\nsecond block\n\nunfinished", 3)
        assertEquals(listOf("first block\n\n", "second block\n\n"), blocks)
        assertEquals("unfinished", tail)
    }

    @Test
    fun `sealed block never changes afterwards`() {
        val splitter = ReasoningBlockSplitter()
        splitter.advance("first block\n\n")
        val first = splitter.advance("first block\n\nsecond").blocks[0]
        splitter.advance("first block\n\nsecond block\n\nthird block")
        val stillSame = splitter.advance("first block\n\nsecond block\n\nthird block more").blocks[0]
        assertEquals(first, stillSame)
    }

    @Test
    fun `blank line inside code fence does not split`() {
        val text = "intro\n\n```js\nconst a = 1;\n\nconst b = 2;\n```\n\noutro\n\n"
        val (blocks, _) = feed(text, 5)
        val fenceBlock = blocks.firstOrNull { it.contains("```") }
        assertTrue("fence block missing", fenceBlock != null)
        assertEquals(2, Regex("```").findAll(fenceBlock!!).count())
        assertTrue(fenceBlock.contains("const a = 1;"))
        assertTrue(fenceBlock.contains("const b = 2;"))
    }

    @Test
    fun `unclosed fence never seals, waits in tail`() {
        val (blocks, tail) = feed("preface\n\n```js\nlet x = 1;\n\nlet y = 2;\n", 4)
        assertEquals(listOf("preface\n\n"), blocks)
        assertTrue(tail.contains("```js"))
        assertTrue(tail.contains("let y = 2;"))
    }

    @Test
    fun `split result is independent of chunk size`() {
        val text = "one\n\ntwo\n\n```py\nx=1\n\ny=2\n```\n\nthree\n\ntail"
        val baseline = feed(text, 1)
        for (size in listOf(2, 3, 7, 16, 64)) {
            assertEquals("chunk=$size blocks differ", baseline.first, feed(text, size).first)
            assertEquals("chunk=$size tail differs", baseline.second, feed(text, size).second)
        }
    }

    @Test
    fun `non-extending input rebuilds from scratch`() {
        val splitter = ReasoningBlockSplitter()
        splitter.advance("old content\n\nold second block\n\n")
        val split = splitter.advance("brand new content\n\nnew tail")
        assertEquals(listOf("brand new content\n\n"), split.blocks)
        assertEquals("new tail", split.tail)
    }

    @Test
    fun `repeated advance is idempotent`() {
        val splitter = ReasoningBlockSplitter()
        val text = "one\n\ntwo\n\nthree"
        val first = splitter.advance(text)
        val second = splitter.advance(text)
        assertEquals(first.blocks, second.blocks)
        assertEquals(first.tail, second.tail)
        assertEquals(2, second.blocks.size)
    }

    /** The tail is the only part re-parsed every frame, so it must stay bounded. */
    @Test
    fun `tail does not grow with total reasoning length`() {
        val splitter = ReasoningBlockSplitter()
        val sb = StringBuilder()
        var peak = 0
        repeat(2_000) { i ->
            sb.append("Reasoning segment $i, with **emphasis** and `code`.\n\n")
            peak = maxOf(peak, splitter.advance(sb.toString()).tail.length)
        }
        assertTrue("tail peak $peak means content is accumulating, degraded to O(n^2)", peak < 200)
    }

    // MARK: - Safe prefix (no raw markers on screen)

    @Test
    fun `unclosed bold is held until closed`() {
        assertEquals("analysis", reasoningSafePrefix("analysis**key"))
        assertEquals("analysis**key constraint**, continue", reasoningSafePrefix("analysis**key constraint**, continue"))
    }

    @Test
    fun `no raw marker leaks at any prefix length`() {
        val source = "I need to **carefully** check: call `flush()` and then continue."
        for (len in 1..source.length) {
            val shown = reasoningSafePrefix(source.substring(0, len))
            // Paired, closed markers are allowed to remain in the source text (markdown rendering
            // handles them), but an unclosed opening marker must never leak -- the check: `**`
            // must appear an even number of times
            assertEquals(
                "len=$len leaked unclosed **: $shown",
                0,
                Regex("\\*\\*").findAll(shown).count() % 2,
            )
            assertEquals(
                "len=$len leaked unclosed backtick: $shown",
                0,
                shown.count { it == '`' } % 2,
            )
        }
    }

    @Test
    fun `heading ambiguity window holds`() {
        // Just `##` with no space yet -- shape undetermined, so hold it back; otherwise it would
        // render as body text before flipping to a heading
        assertEquals("", reasoningSafePrefix("##"))
        assertEquals("## Step two", reasoningSafePrefix("## Step two"))
    }

    @Test
    fun `hr candidate holds until line completes`() {
        assertEquals("", reasoningSafePrefix("---"))
        assertEquals("preceding text\n", reasoningSafePrefix("preceding text\n--"))
    }

    @Test
    fun `table skeleton is held until region completes`() {
        // The header row can't be confirmed as a table yet (depends on whether the next line is
        // a separator) -- hold it back
        assertFalse(reasoningSafePrefix("text\n| ColA | ColB |").contains("|"))
        assertFalse(reasoningSafePrefix("text\n| ColA | ColB |\n|---|---|\n").contains("|---|"))
    }

    @Test
    fun `unclosed block math is held`() {
        assertFalse(reasoningSafePrefix("text\n$$\nx = 1\n").contains("$$"))
    }

    @Test
    fun `plain text passes through untouched`() {
        assertEquals("Plain reasoning content, no markers at all.", reasoningSafePrefix("Plain reasoning content, no markers at all."))
        assertEquals("first line\nsecond line", reasoningSafePrefix("first line\nsecond line"))
    }

    @Test
    fun `empty input yields empty`() {
        assertEquals("", reasoningSafePrefix(""))
    }
}
