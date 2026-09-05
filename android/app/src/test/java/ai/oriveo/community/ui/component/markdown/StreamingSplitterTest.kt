package ai.oriveo.community.ui.component.markdown

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamingSplitterTest {

    @Test
    fun `short text stays in tail`() {
        val result = StreamingSplitter.split("hello world")
        assertEquals("", result.committed)
        assertEquals("hello world", result.tail)
        assertEquals(StreamingSplitter.TailKind.Paragraph, result.tailKind)
    }

    @Test
    fun `splits at double newline`() {
        val text = "a".repeat(100) + "\n\n" + "tail text"
        val result = StreamingSplitter.split(text)
        assertTrue(result.committed.isNotEmpty())
        assertTrue(result.tail.isNotEmpty())
        assertTrue(result.committed.endsWith("\n\n"))
        assertEquals("tail text", result.tail)
    }

    @Test
    fun `does not split inside code block`() {
        val text = "a".repeat(50) + "\n```\n" + "a".repeat(50) + "\n\n" + "a".repeat(50) + "\n```\n" + "tail"
        val result = StreamingSplitter.split(text)
        assertFalse(StreamingSplitter.hasOpenCodeFence(result.committed))
    }

    @Test
    fun `unclosed code fence marks tail as UnclosedCodeFence`() {
        val text = "intro paragraph here filling some space so we cross 80 char threshold quickly.\n\n```python\nprint('hi')"
        val result = StreamingSplitter.split(text)
        assertEquals(StreamingSplitter.TailKind.UnclosedCodeFence, result.tailKind)
    }

    @Test
    fun `unclosed math block marks tail as UnclosedMathBlock`() {
        val dd = "\$\$"
        val text = "intro paragraph here filling space so we cross 80 char threshold quickly.\n\n" + dd + "\\int_0^1 x"
        val result = StreamingSplitter.split(text)
        assertEquals(StreamingSplitter.TailKind.UnclosedMathBlock, result.tailKind)
    }

    @Test
    fun `partial table without separator marks tail as UnclosedTable`() {
        
        val text = "Here is data filling enough chars to cross the threshold for splitter.\n\n| Col1 | Col2 |\n| a | b"
        val result = StreamingSplitter.split(text)
        assertEquals(StreamingSplitter.TailKind.UnclosedTable, result.tailKind)
    }

    @Test
    fun `completed table is not in tail as table`() {
        
        val text = "intro paragraph to push past the threshold here.\n\n" +
            "| H1 | H2 |\n| --- | --- |\n| a | b |\n\nafter table"
        val result = StreamingSplitter.split(text)
        
        assertEquals(StreamingSplitter.TailKind.Paragraph, result.tailKind)
    }

    @Test
    fun `hasOpenCodeFence detects unclosed fence`() {
        assertTrue(StreamingSplitter.hasOpenCodeFence("```python\nprint('hello')"))
        assertFalse(StreamingSplitter.hasOpenCodeFence("```python\nprint('hello')\n```"))
    }

    @Test
    fun `hasOpenCodeFence with no fence`() {
        assertFalse(StreamingSplitter.hasOpenCodeFence("normal text"))
    }

    @Test
    fun `hasOpenMathBlock detects unclosed dollar dollar`() {
        val dd = "\$\$"
        assertTrue(StreamingSplitter.hasOpenMathBlock(dd + "x + y"))
        assertFalse(StreamingSplitter.hasOpenMathBlock(dd + "x + y" + dd))
    }

    @Test
    fun `extractLanguage gets language from fence`() {
        assertEquals("python", StreamingSplitter.extractLanguage("```python\ncode"))
        assertEquals("kotlin", StreamingSplitter.extractLanguage("```kotlin\ncode"))
        assertEquals("", StreamingSplitter.extractLanguage("```\ncode"))
    }

    @Test
    fun `extractLanguage with no fence returns empty`() {
        assertEquals("", StreamingSplitter.extractLanguage("no fence here"))
    }

    @Test
    fun `extractCodeAfterFence gets code content`() {
        assertEquals("print('hello')", StreamingSplitter.extractCodeAfterFence("```python\nprint('hello')"))
    }

    @Test
    fun `extractCodeAfterFence empty after fence`() {
        assertEquals("", StreamingSplitter.extractCodeAfterFence("```python"))
    }

    

    @Test
    fun `splitTrailingTable matches header plus separator without data rows`() {
        
        val tail = "| H1 | H2 |\n| --- | --- |"
        val r = StreamingSplitter.splitTrailingTable(tail)
        assertNotNull(r)
        assertEquals("", r!!.beforeTable)
        assertEquals(tail, r.tableText)
    }

    @Test
    fun `splitTrailingTable includes in-progress last row`() {
        
        val tail = "| H1 | H2 |\n| --- | --- |\n| a | b |\n| c"
        val r = StreamingSplitter.splitTrailingTable(tail)
        assertNotNull(r)
        assertEquals("", r!!.beforeTable)
        assertTrue(r.tableText.endsWith("| c"))
    }

    @Test
    fun `splitTrailingTable returns null without separator`() {
        
        assertNull(StreamingSplitter.splitTrailingTable("| H1 | H2 |\n| a | b"))
    }

    @Test
    fun `splitTrailingTable returns null for plain text`() {
        assertNull(StreamingSplitter.splitTrailingTable("just some paragraph text here"))
    }

    @Test
    fun `splitTrailingTable separates content before table`() {
        val tail = "Some intro line\n\n| H1 | H2 |\n| --- | --- |\n| a | b |"
        val r = StreamingSplitter.splitTrailingTable(tail)
        assertNotNull(r)
        assertEquals("Some intro line\n", r!!.beforeTable)
        assertTrue(r.tableText.startsWith("| H1 | H2 |"))
    }

    @Test
    fun `splitTrailingTable returns null when table closed by following prose`() {
        
        val tail = "| H1 | H2 |\n| --- | --- |\n| a | b |\nafter table prose"
        assertNull(StreamingSplitter.splitTrailingTable(tail))
    }

    @Test
    fun `splitTrailingTable returns null when blank line closes table`() {
        
        val tail = "| a |\n| --- |\n| 1 |\n\n| b |\n| --- |\n| 2 |"
        assertNull(StreamingSplitter.splitTrailingTable(tail))
    }

    @Test
    fun `splitTrailingTable tolerates trailing newline of completed row`() {
        
        val tail = "| H1 | H2 |\n| --- | --- |\n| a | b |\n"
        val r = StreamingSplitter.splitTrailingTable(tail)
        assertNotNull(r)
    }

    

    @Test
    fun `mid-line inline math does not create split point inside paragraph`() {
        
        
        val text = "A really long opening line that easily exceeds the eighty character minimum " +
            "threshold with \$\$E=mc^2\$\$ inline\nsecond line"
        val result = StreamingSplitter.split(text)
        assertEquals("", result.committed)
        assertEquals(text, result.tail)
    }

    

    @Test
    fun `maxEnd gates committed boundary to earlier safe split`() {
        val first = "first paragraph long enough to cross the eighty char threshold for split.\n\n"
        val second = "second paragraph also here\n\n"
        val text = first + second + "tail words"
        
        assertEquals(first + second, StreamingSplitter.split(text).committed)
        
        val gated = StreamingSplitter.split(text, maxEnd = first.length + 10)
        assertEquals(first, gated.committed)
        assertEquals(second + "tail words", gated.tail)
    }

    @Test
    fun `maxEnd zero keeps everything in tail`() {
        val text = "first paragraph long enough to cross the eighty char threshold for split.\n\nmore"
        val gated = StreamingSplitter.split(text, maxEnd = 0)
        assertEquals("", gated.committed)
        assertEquals(text, gated.tail)
    }

    @Test
    fun `line-start block math still creates split point after closing`() {
        val text = "intro paragraph filling enough characters to cross the eighty threshold ok.\n" +
            "\$\$\nx^2 + y^2\n\$\$\nafter math"
        val result = StreamingSplitter.split(text)
        assertTrue(result.committed.endsWith("\$\$\n"))
        assertEquals("after math", result.tail)
    }
}
